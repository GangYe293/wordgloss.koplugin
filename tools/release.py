#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布脚本：打包 → 算 SHA-256 → 打 tag → 建 GitHub Release → 传安装包。

默认只做**本地部分**并打印将要执行的远程命令（dry-run），确认没问题之后
再加 `--execute` 才会真的动 GitHub。整个流程：

    python tools/release.py                 # 1) 检查  2) 打包  3) 打印待执行命令
    python tools/release.py --execute       # 上面三步 + 打 tag、push、建 Release、传包

产出 4 个文件（默认放在仓库的上一级目录）：

    wordgloss-1.6.0.zip          完整包（含离线词典，几 MB）
    wordgloss-1.6.0.zip.sha256
    wordgloss-1.6.0-code.zip     仅代码（几十 KB，本地已有词典时用这个）
    wordgloss-1.6.0-code.zip.sha256

zip 里的顶层目录固定是 `wordgloss.koplugin/`，解压后直接放进 KOReader 的
`plugins/` 就是正确结构（插件的自动更新也认这个结构）。

远程部分需要 GitHub 个人访问令牌（PAT）：
  1. https://github.com/settings/tokens → Generate new token (classic)
  2. 勾选 `public_repo`（私有仓库用 `repo`）
  3. set GITHUB_TOKEN=ghp_xxx        （PowerShell: $env:GITHUB_TOKEN="ghp_xxx"）
     或 python tools/release.py --token ghp_xxx --execute
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

PLUGIN_DIR_NAME = "wordgloss.koplugin"
PACKAGE_BASE = "wordgloss"

# 任何包里都不要的东西
# .gitignore 只是开发用的，不该出现在用户装到的插件目录里
EXCLUDE_ALWAYS = {".git", "__pycache__", ".backup", ".idea", ".vscode", ".gitignore"}
EXCLUDE_SUFFIX = {".pyc", ".pyo", ".bak", ".tmp"}
# 仅代码包额外排除：离线词典（最大的东西）+ 生成脚本
EXCLUDE_CODE_EXTRA = {"data", "tools"}

GITHUB_API = "https://api.github.com"

# 上传安装包（完整包 3 MB 起）比发一个 JSON 慢得多，国内网络下 60 秒经常不够，
# 超时会让 Release 建好、附件却是空的（v1.8.4 就卡在这）。上传单独给一个宽裕的超时。
UPLOAD_TIMEOUT = 300
UPLOAD_RETRIES = 3


def log(message=""):
    print(message, flush=True)


def run(cmd, cwd=None, check=True, capture=True):
    """跑一条命令，返回 (returncode, stdout)。"""
    proc = subprocess.run(cmd, cwd=cwd, shell=False,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None,
                          text=True, errors="replace")
    if check and proc.returncode != 0:
        raise SystemExit("命令失败：%s\n%s" % (" ".join(cmd), (proc.stdout or "").strip()))
    return proc.returncode, (proc.stdout or "").strip()


def read_meta_version(plugin_dir):
    text = (plugin_dir / "_meta.lua").read_text(encoding="utf-8")
    match = re.search(r'version\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit("在 _meta.lua 里找不到 version")
    return match.group(1)


def collect_files(plugin_dir, exclude):
    """列出要打包的文件（相对插件目录的路径）。"""
    skip = set(EXCLUDE_ALWAYS) | set(exclude)
    files = []
    for path in sorted(plugin_dir.rglob("*")):
        if path.is_dir():
            continue
        rel = path.relative_to(plugin_dir)
        if any(part in skip for part in rel.parts):
            continue
        if path.suffix.lower() in EXCLUDE_SUFFIX:
            continue
        files.append(rel)
    return files


def build_zip(plugin_dir, files, zip_path):
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in files:
            zf.write(plugin_dir / rel, str(Path(PLUGIN_DIR_NAME) / rel))
    return zip_path.stat().st_size


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_checksum(zip_path):
    """写成 sha256sum 的格式：`<hash>  <文件名>`（插件只读第一段十六进制）。"""
    checksum_path = zip_path.with_suffix(zip_path.suffix + ".sha256")
    checksum_path.write_text("%s  %s\n" % (sha256_of(zip_path), zip_path.name),
                             encoding="utf-8")
    return checksum_path


def check_lua51_syntax(plugin_dir):
    """Lua 5.1 语法体检：KOReader 跑的是 LuaJIT（5.1 语法）。

    5.3 才有的运算符（& | ~ << >> //）只要有一个裸写在源码里，LuaJIT 在**解析期**
    就会报错，整个插件加载失败、菜单里直接消失——而且运行时根本轮不到那行代码也一样。
    （真出过这事：sha2 里写了 `a & b`，插件在 Kindle 上整个不见了。）
    所以这些运算符只允许出现在长字符串里、靠 load 运行时编译。
    """
    long_bracket = re.compile(r"\[(=*)\[")
    # 注释与字符串已经抹掉了，剩下的 & | ~ << >> // 就一定是运算符。
    # 注意别写成要求"& 后面紧跟字符"——`1 & 2` 这种带空格的写法最常用。
    patterns = [(r"//", "floor division"),
                (r"<<", "left shift"), (r">>", "right shift"),
                (r"&", "bitwise and"), (r"\|", "bitwise or"),
                (r"~[^=]", "bitwise not/xor")]
    problems = []
    for path in sorted(plugin_dir.rglob("*.lua")):
        src = path.read_text(encoding="utf-8")
        # 先抹掉注释与字符串：长注释/长字符串要按整份文件处理，不能逐行。
        cleaned = []
        i, n = 0, len(src)
        while i < n:
            if src.startswith("--", i):
                m = long_bracket.match(src, i + 2)
                if m:                                    # --[[ ... ]]
                    close = "]" + m.group(1) + "]"
                    j = src.find(close, i + m.end())
                    i = n if j < 0 else j + len(close)
                else:                                    # -- 到行尾
                    j = src.find("\n", i)
                    i = n if j < 0 else j
                cleaned.append("\n")
                continue
            m = long_bracket.match(src, i)
            if m:                                        # [[ ... ]] 字符串
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + m.end())
                cleaned.append("''")
                i = n if j < 0 else j + len(close)
                continue
            if src[i] in "\"'":
                quote = src[i]
                j = i + 1
                while j < n and src[j] != quote:
                    j += 2 if src[j] == "\\" else 1
                cleaned.append("''")
                i = min(j + 1, n)
                continue
            cleaned.append(src[i])
            i += 1
        text = "".join(cleaned)
        for line_no, line in enumerate(text.splitlines(), 1):
            for pattern, label in patterns:
                if re.search(pattern, line):
                    problems.append("%s:%d 用了 Lua 5.1 不认识的 %s -> %s"
                                    % (path.name, line_no, label, line.strip()[:70]))
                    break
    return problems


def git_checks(repo_dir, version, branch="main"):
    """发布前该确认的事。返回 (问题列表)。"""
    problems = []
    _, status = run(["git", "status", "--porcelain"], cwd=repo_dir)
    if status:
        problems.append("工作区还有未提交的改动：\n" + status)
    _, head = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo_dir)
    if head != branch:
        problems.append("当前分支是 %s，不是 %s" % (head or "?", branch))
    _, remote_tags = run(["git", "ls-remote", "--tags", "origin", "v" + version],
                         cwd=repo_dir, check=False)
    if remote_tags.strip():
        problems.append("远端已经有 tag v%s 了" % version)
    code, unpushed = run(["git", "log", "--oneline", "origin/%s..%s" % (branch, branch)],
                         cwd=repo_dir, check=False)
    if code == 0 and unpushed.strip():
        problems.append("有 %d 个提交还没推到 GitHub：\n%s"
                        % (len(unpushed.splitlines()), unpushed))
    return problems


def github_request(method, url, token, payload=None, headers=None, data=None, timeout=60):
    request_headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "User-Agent": "wordgloss-release-script",
    }
    if headers:
        request_headers.update(headers)
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    if data is not None:
        body = data
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", "replace")
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        raw = err.read().decode("utf-8", "replace")
        detail = raw
        try:
            detail = json.loads(raw).get("message", raw)
        except ValueError:
            pass
        return err.code, {"message": detail}


def create_release(repo, version, token, notes, assets):
    """建 Release 并上传资产。返回 release 的 html_url。"""
    payload = {
        "tag_name": "v" + version,
        "name": "WordGloss v" + version,
        "body": notes,
        "draft": False,
        "prerelease": False,
    }
    status, release = github_request("POST", "%s/repos/%s/releases" % (GITHUB_API, repo),
                                     token, payload)
    if status not in (200, 201):
        if status == 422:  # 已经存在：接着往里补资产
            status, release = github_request(
                "GET", "%s/repos/%s/releases/tags/v%s" % (GITHUB_API, repo, version), token)
            # 说明只在首次创建时生效，补跑时顺手同步成最新的（--notes-file 才有内容）
            if status in (200, 201) and notes and release.get("body") != notes:
                patch_status, _ = github_request(
                    "PATCH", "%s/repos/%s/releases/%s" % (GITHUB_API, repo, release["id"]),
                    token, {"body": notes})
                log("  Release 已存在，%s" % ("已更新说明"
                    if patch_status in (200, 201) else "说明更新失败（不影响上传）"))
        if status not in (200, 201):
            raise SystemExit("创建 Release 失败（HTTP %s）：%s"
                             % (status, release.get("message")))
    else:
        log("  已创建 Release %s" % tag_name(version))

    upload_url = release["upload_url"].split("{")[0]
    existing = {asset["name"]: asset["id"] for asset in release.get("assets", [])}
    for path in assets:
        with open(path, "rb") as handle:
            data = handle.read()
        status, uploaded = None, {}
        for attempt in range(1, UPLOAD_RETRIES + 1):
            status, uploaded = github_request_with_name(upload_url, token, path.name, data)
            if status in (200, 201):
                break
            message = str(uploaded.get("message", ""))
            # 同名资产已存在（上一次跑到一半的结果）：删掉再重传
            if status == 422 and path.name in existing:
                log("  删除已存在的同名资产 %s" % path.name)
                github_request("DELETE", "%s/repos/%s/releases/assets/%s"
                               % (GITHUB_API, repo, existing[path.name]), token)
                continue
            log("  上传 %s 第 %d/%d 次失败（HTTP %s）：%s"
                % (path.name, attempt, UPLOAD_RETRIES, status, message or "超时/网络错误"))
        if status not in (200, 201):
            raise SystemExit("上传 %s 失败（HTTP %s）：%s\n可以重跑本命令补传，"
                             "已建好的 Release 不会被重复创建。"
                             % (path.name, status, uploaded.get("message")))
        log("  已上传 %s（%s）" % (path.name, uploaded.get("name", "")))
    return release.get("html_url", "")


def tag_name(version):
    return "v" + version


def github_request_with_name(upload_url, token, name, data):
    """upload_url 需要 ?name=... 查询参数。上传用单独的超时（见 UPLOAD_TIMEOUT）。"""
    url = "%s?name=%s" % (upload_url, urllib.parse.quote(name))
    return github_request("POST", url, token, data=data,
                          headers={"Content-Type": "application/zip"},
                          timeout=UPLOAD_TIMEOUT)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    here = Path(__file__).resolve().parent
    plugin_dir = here.parent
    repo_dir = plugin_dir
    default_out = plugin_dir.parent

    parser = argparse.ArgumentParser(description="打包并发布 WordGloss")
    parser.add_argument("--version", default=None, help="默认读 _meta.lua")
    parser.add_argument("--repo", default="GangYe293/wordgloss.koplugin")
    parser.add_argument("--out-dir", default=str(default_out), help="zip 输出到哪")
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""),
                        help="GitHub PAT，或用环境变量 GITHUB_TOKEN")
    parser.add_argument("--notes-file", default=None, help="Release 说明的文本文件")
    parser.add_argument("--notes", default=None, help="Release 说明（一行字符串）")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--execute", action="store_true",
                        help="真的打 tag / 建 Release / 传包（默认只打印）")
    parser.add_argument("--skip-checks", action="store_true", help="跳过 git 检查")
    args = parser.parse_args()

    version = args.version or read_meta_version(plugin_dir)
    out_dir = Path(args.out_dir).resolve()
    tag = "v" + version

    log("== WordGloss 发布 %s ==" % tag)
    log("仓库   : %s" % args.repo)
    log("插件目录: %s" % plugin_dir)
    log("输出目录: %s" % out_dir)

    # 1) 检查
    if not (repo_dir / ".git").exists():
        raise SystemExit("插件目录里没有 .git，发布脚本要在 git 仓库里跑")
    meta_version = read_meta_version(plugin_dir)
    if meta_version != version:
        raise SystemExit("_meta.lua 里的版本是 %s，和要发布的 %s 不一致" % (meta_version, version))
    main_version = None
    main_text = (plugin_dir / "main.lua").read_text(encoding="utf-8")
    match = re.search(r'VERSION\s*=\s*"([^"]+)"', main_text)
    if match:
        main_version = match.group(1)
    if main_version and main_version != version:
        raise SystemExit("main.lua 里的 VERSION 是 %s，和 %s 不一致" % (main_version, version))

    problems = [] if args.skip_checks else git_checks(repo_dir, version, args.branch)

    # Lua 5.1 语法体检：这类问题在离线测试里发现不了（测试环境是 5.3），
    # 到真机上却是"插件整个消失"，所以每次打包都必须扫一遍。
    lua_problems = check_lua51_syntax(plugin_dir)
    if lua_problems:
        log("\n[!] 源码里有 Lua 5.1（LuaJIT）解析不了的写法，到 Kindle 上插件会加载失败：")
        for problem in lua_problems:
            log("  - " + problem)
        raise SystemExit("\n先把 5.3 专有运算符挪进长字符串、改用 load 运行时编译。")
    log("Lua 5.1 语法体检：通过")

    # 这两类问题脚本自己会解决，不算拦路虎：
    #   - 远端已有 tag：上次跑到一半（上传超时等），这次是补传资产；
    #   - 有提交没推：下面马上就会 git push。
    def resumable(problem):
        return problem.startswith("远端已经有 tag") or "还没推到 GitHub" in problem

    if problems:
        fatal = [p for p in problems if not resumable(p)]
        if args.execute and not fatal:
            for problem in problems:
                log("[i] %s（脚本会自己处理，继续）" % problem.splitlines()[0])
            log("[i] 补传模式：只补资产与说明，不重复创建 Release")
        else:
            log("\n[!] 发布前的检查没过：")
            for problem in problems:
                log("  - " + problem)
            if not args.execute:
                log("\n（打包照常进行；要跳过检查加 --skip-checks）")
            else:
                raise SystemExit("\n先把上面的事情处理完再 --execute。")

    # 2) 打包
    log("\n== 打包 ==")
    full_files = collect_files(plugin_dir, set())
    code_files = collect_files(plugin_dir, EXCLUDE_CODE_EXTRA)
    packages = []

    for kind, files, suffix in (("完整包", full_files, ""), ("仅代码", code_files, "-code")):
        zip_path = out_dir / ("%s-%s%s.zip" % (PACKAGE_BASE, version, suffix))
        size = build_zip(plugin_dir, files, zip_path)
        checksum_path = write_checksum(zip_path)
        packages.append((zip_path, checksum_path))
        log("  %s: %s（%d 个文件，%.2f MB）"
            % (kind, zip_path.name, len(files), size / 1024 / 1024))
        log("    sha256: %s" % sha256_of(zip_path))

    # 3) Release 说明
    notes = args.notes or ""
    if args.notes_file:
        notes = Path(args.notes_file).read_text(encoding="utf-8")
    if not notes:
        notes = "生词注释（WordGloss）%s\n\n详见仓库 README 的「版本变化」。" % tag

    assets = []
    for zip_path, checksum_path in packages:
        assets.extend([zip_path, checksum_path])

    # 4) 执行 / 打印
    log("\n== 远程操作 ==")
    if not args.execute:
        log("（dry-run：下面这些命令**没有**执行）")
        log("  git tag -a %s -m \"WordGloss %s\"" % (tag, tag))
        log("  git push origin %s" % args.branch)
        log("  git push origin %s" % tag)
        log("  创建 Release %s 并上传：" % tag)
        for path in assets:
            log("    - %s" % path.name)
        log("\n确认无误后执行：")
        log("  python tools/release.py --execute%s"
            % ("" if args.token else " --token <你的GitHub令牌>"))
        if not args.token:
            log("\n还没有 GitHub 令牌：https://github.com/settings/tokens")
            log("  → Generate new token (classic)，勾选 public_repo")
            log("  → 然后 set GITHUB_TOKEN=ghp_xxx（Windows cmd）")
        return

    if not args.token:
        raise SystemExit("--execute 需要 GitHub 令牌：--token ghp_xxx 或设置 GITHUB_TOKEN")

    _, local_tag = run(["git", "tag", "-l", tag], cwd=repo_dir)
    if local_tag.strip():      # 补跑时 tag 已经在本地了，git tag -a 会报错
        log("  本地已有 tag %s，跳过创建" % tag)
    else:
        run(["git", "tag", "-a", tag, "-m", "WordGloss %s" % tag], cwd=repo_dir)
        log("  已打 tag %s" % tag)
    run(["git", "push", "origin", args.branch], cwd=repo_dir)
    log("  已推送 %s" % args.branch)
    run(["git", "push", "origin", tag], cwd=repo_dir)
    log("  已推送 %s" % tag)

    url = create_release(args.repo, version, args.token, notes, assets)
    log("\n发布完成：%s" % url)
    log("\n验证：到 https://github.com/%s/releases/latest 看一眼，"
        % args.repo)
    log("然后在 KOReader 里：工具 → 生词注释 → 关于 → 检查更新。")


if __name__ == "__main__":
    main()
