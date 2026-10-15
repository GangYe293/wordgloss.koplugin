--[[--
内置更新说明。

「关于 → 版本」点开要看这个版本改了什么。说明随代码一起发布，所以放在插件里：
离线也能看，不必联网问 GitHub。

发布新版本时把对应条目加到 ENTRIES 最前面（最新的在上面）。
tools/release.py 会检查当前版本有没有条目，漏了会提醒。
]]

local _ = require("gettext")

local Changelog = {}

-- 最新在上。每条是若干行文字，行内不要换行，显示时按顺序拼起来。
Changelog.ENTRIES = {
    {
        version = "1.8.14",
        lines = {
            "菜单结构调整 + 划词翻译崩溃修复：",
            "· 一级菜单「开始转换」改名为「注释生词」，进去后的开关也从「开始转换」改为「开始注释生词」，名字与功能对上。",
            "· 「联网翻译设置」从「翻译生词设置」子菜单提到一级菜单——选引擎和填密钥是高频操作，藏太深不好找；",
            "  「启用划词翻译」也从「划词翻译」子菜单提到一级并去掉外层容器，直接当开关用。",
            "· 「翻译生词设置」里不再有联网翻译设置（已提到一级），只留释义来源 / 翻译范围 / 自动补翻等项。",
            "· 修复关闭翻译弹窗后选区不清导致 KOReader 崩溃退出（button.lua dimen nil）：",
            "  close_callback 改为无条件清选区（先关 highlight_dialog 再 clear），旧逻辑只在 highlight_dialog 不在时才 clear。",
            "· 对齐 ai_translator 的网络层：HTTP 超时恢复到 30s、重试 3 次（wordgloss 划词翻译也跑在 Trapper 子进程，不阻塞 UI）；",
            "  Translator.translate 失败不再回退原生 Google（墙内必超时 30s+），直接返回 nil，与 ai_translator 行为一致。",
        },
    },
    {
        version = "1.8.13",
        lines = {
            "新增「划词翻译」（接管 KOReader 原生翻译，无需再单独装 AI 翻译插件）：",
            "· 选中文字弹出的翻译现在走本插件自己的联网引擎（Edge / Google / 智谱 / 硅基流动 / DeepL / DeepSeek / 通用OpenAI），",
            "  菜单「划词翻译」可一键开关，关闭则退回原生 Google 翻译。",
            "· 劫持的是 KOReader 翻译入口 Translator.showTranslation（在父进程里被划词直接调用，patch 一定生效），",
            "  并复刻原生弹窗（保存笔记 / 复制）；全程异常兜底，翻译失败安全退回原生，不会把选区卡在选中状态。",
            "· 检测到 AI 翻译插件已启用时自动让出，避免两个插件互相踩踏；",
            "  生词注释与划词翻译共用同一套引擎配置（ai_engine）与密钥，只维护一份。",
        },
    },
    {
        version = "1.8.12",
        lines = {
            "修一个开 PDF 直接崩出 KOReader 的 bug：",
            "· 插件原本只在「是否启用」上判断，没判断文档类型，打开 PDF/DjVu/CBZ 等",
            "  固定版式文档时照样跑注释刷新，调到一个这些文档没有的接口，",
            "  LuaJIT 抛错中止整个程序。",
            "· 现在插件只在 CRE 可回流文档（EPUB/MOBI/AZW3/FB2/TXT/HTML）上激活，",
            "  其它格式自动休眠，打开不会崩、不影响阅读。",
            "· 顺手给注释刷新加了 pcall 兜底，避免任何非预期调用再引发退出。",
        },
    },
    {
        version = "1.8.11",
        lines = {
            "「关于」里的版本 / 作者 / 小红书ID 三行点了各有各的反应，",
            "样子还是普通菜单行（没有勾选框），点完菜单不关：",
            "· 版本：弹出这个版本改了什么（内置说明，不联网）",
            "· 作者：弹出项目地址 github.com/GangYe293/wordgloss.koplugin",
            "· 小红书ID：有问题可以去小红书给作者留言",
            "这三行以前没有点击反应、还会被当成勾选项，三个能一起勾上。",
        },
    },
    {
        version = "1.8.9",
        lines = {
            "修了两个「点了看着没反应」的问题：",
            "· 「清除本书注释数据」清完注释还在 —— 释义缓存是跨书共享的，清本书数据",
            "  动不了它，刷新注释又只看缓存，所以注释原样长回来。现在清完给本书留一个",
            "  「待重扫」标记，注释立刻消失，重新翻译后才回来。",
            "· 「注释字体」改完要退出书再进来才生效 —— 字体缓存没把字体名和字号算进",
            "  缓存键。现在改完立刻生效。",
            "菜单改名：翻译整本书的生词（后台）→（增量）、重新翻译整本 →（覆盖已有）、",
            "清空全部释义缓存 → 清空全部注释数据。",
        },
    },
    {
        version = "1.8.8",
        lines = {
            "离线词典丢了能自己装回来：",
            "· 「关于 → 重装离线词典」：不管当前版本号，直接拉最新完整包装上（约 3 MB），",
            "  已翻译的释义缓存不丢。",
            "· 本地词典不全时，「只更新代码」会自动改成下载完整包。",
            "词频包打不开时不再每个词都重试一次并刷一条日志（以前一页能刷几百条）。",
            "翻译失败的提示改成指路，不再只报一个文件名。",
        },
    },
    {
        version = "1.8.7",
        lines = {
            "修「只更新代码」在线更新之后翻译整本书报错：",
            "· code 包不含 data/，换名更新时它会随旧目录一起被搬走，导致词频包和释义包",
            "  一起消失。现在装完会把上个版本的 data/ 搬回来。",
            "· 数据包缺失时本该提示「词频包未能加载」，却因为函数定义顺序直接崩了。",
        },
    },
    {
        version = "1.8.6",
        lines = {
            "「查看翻译进度」「停止翻译」不再常驻菜单发灰，只有后台有任务时才出现。",
            "「查看翻译进度」改成弹出真正的进度条窗口（每前进 2% 刷新一次），",
            "不再是 4 秒就消失的一行文本。",
            "修掉定时器泄漏：进度窗关掉后不再一直读进度文件。",
        },
    },
    {
        version = "1.8.5",
        lines = {
            "修「在线更新提示占满屏幕」：Release 说明之前整份塞进弹窗标题，小屏上会把",
            "安装按钮顶出可视区。现在只预览前 4 行，完整内容用「查看完整更新说明」打开。",
        },
    },
    {
        version = "1.8.4",
        lines = {
            "注释设置里「注释字体」提到「注释字号」之前。",
            "菜单后缀瘦身：不注释人名/地名、每页注释上限、重新翻译整本。",
            "「阅读时自动补翻译生词」的后缀改成（需要联网）。",
        },
    },
}

-- 取某个版本的说明（没有就 nil）。
function Changelog.for_version(version)
    if type(version) ~= "string" or version == "" then return nil end
    for _, entry in ipairs(Changelog.ENTRIES) do
        if entry.version == version then return entry end
    end
    return nil
end

-- 拼成可以直接塞进 TextViewer 的文本。
function Changelog.text(version)
    local entry = Changelog.for_version(version)
    if not entry then return nil end
    return table.concat(entry.lines, "\n")
end

-- 最近若干版的说明，一条接一条（老版本折叠用的备选）。
function Changelog.recent_text(max_versions)
    max_versions = tonumber(max_versions) or 3
    local out = {}
    for index, entry in ipairs(Changelog.ENTRIES) do
        if index > max_versions then break end
        out[#out + 1] = entry.version .. "\n" .. table.concat(entry.lines, "\n")
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n\n")
end

function Changelog.latest_version()
    local entry = Changelog.ENTRIES[1]
    return entry and entry.version or nil
end

-- 没有内置说明时用的兜底文案（指向 GitHub 上的完整记录）。
Changelog.FALLBACK = _(
    "这个版本没有内置更新说明。\n完整更新记录见 GitHub 的 Releases 页面。")

return Changelog
