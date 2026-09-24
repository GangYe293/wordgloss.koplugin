--[[--
自动更新：从 GitHub Release 拉新版本，校验后替换插件目录。

设计取舍（都跟"Kindle 上不能把插件搞坏"有关）：
  * 只读检查：查更新只是问一次 GitHub，点不点安装由用户决定。
  * 先校验再动手：下载后比对 SHA-256，对不上就当没下载过。
  * 先备份再替换：旧目录整个改名成 wordgloss.koplugin.backup，
    新版本没被激活成功就立刻改回去；备份要留到"下一次启动成功"才删
    （见 cleanup_backup），否则新版本一加载就崩就没得回滚了。
  * 落地目录换名而不是覆盖：os.rename 是原子的，不会出现半新半旧的插件。
  * 镜像回退：GitHub 直连不通时依次试 gh-proxy 等镜像（URL 必须落在
    本仓库的 API / Release 下载前缀内才允许加镜像，避免被拿去代理别的地址）。

只用到 KOReader 自带的 socket.http / json / ffi-archiver，不额外装东西。
]]

local logger = require("logger")
local _ = require("gettext")

local Updater = {}
Updater.__index = Updater

Updater.REPO = "GangYe293/wordgloss.koplugin"
Updater.API_URL = "https://api.github.com/repos/GangYe293/wordgloss.koplugin/releases/latest"
Updater.DOWNLOAD_PREFIX = "https://github.com/GangYe293/wordgloss.koplugin/releases/download/"
Updater.MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}
Updater.PLUGIN_DIR_NAME = "wordgloss.koplugin"
Updater.PACKAGE_BASE = "wordgloss"          -- wordgloss-1.6.0.zip / wordgloss-1.6.0-code.zip
Updater.STATE_KEY = "wordgloss_update"
Updater.CHECK_INTERVAL = 24 * 60 * 60       -- 自动检查的间隔（一天一次）
Updater.MAX_PACKAGE_BYTES = 12 * 1024 * 1024
Updater.MAX_NOTES = 1200

local Sha2 = require("wordgloss_sha2")

------------------------------------------------------------------------
-- 纯逻辑（不碰网络、不碰文件，方便单测）
------------------------------------------------------------------------

-- "1.6.0" / "v1.6.0" 比大小：新于返回 1，等于 0，旧于 -1，格式不对返回 nil。
function Updater.compare_versions(left, right)
    local function parts(version)
        local major, minor, patch = tostring(version or ""):match("^v?(%d+)%.(%d+)%.?(%d*)$")
        if not major then return nil end
        return { tonumber(major), tonumber(minor), tonumber(patch ~= "" and patch or 0) }
    end
    local a, b = parts(left), parts(right)
    if not a or not b then return nil end
    for index = 1, 3 do
        if a[index] < b[index] then return -1 end
        if a[index] > b[index] then return 1 end
    end
    return 0
end

-- 只给"自己仓库"的 URL 配镜像，别的地址一律直连。
function Updater.is_official_url(url)
    if type(url) ~= "string" then return false end
    return url == Updater.API_URL or url:sub(1, #Updater.DOWNLOAD_PREFIX) == Updater.DOWNLOAD_PREFIX
end

-- 候选地址：先直连后镜像（prefer_proxy 时反过来）。
function Updater.candidate_urls(url, prefer_proxy)
    if not Updater.is_official_url(url) then return {} end
    local direct, proxies = { url }, {}
    for _, prefix in ipairs(Updater.MIRRORS) do
        proxies[#proxies + 1] = prefix .. url
    end
    local out = {}
    local first, second = prefer_proxy and proxies or direct,
        prefer_proxy and direct or proxies
    for _, candidate in ipairs(first) do out[#out + 1] = candidate end
    for _, candidate in ipairs(second) do out[#out + 1] = candidate end
    return out
end

local function clean_notes(notes)
    notes = tostring(notes or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    notes = notes:gsub("%*%*(.-)%*%*", "%1"):gsub("`(.-)`", "%1")
    if #notes > Updater.MAX_NOTES then notes = notes:sub(1, Updater.MAX_NOTES - 3) .. "..." end
    return notes
end

--[[--
解析 GitHub Release API 的返回。

只认 tag 形如 v1.2.3 的正式版（draft / prerelease 一律忽略），并且必须同时
找得到安装包与它的 .sha256。两个包：
  full —— 含离线词典（几 MB）
  code —— 只有代码（几十 KB），本地已经有词典时用这个就够了
]]
function Updater.parse_release(data)
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, _("不是可用的正式版发布")
    end
    local tag = type(data.tag_name) == "string" and data.tag_name or ""
    local version = tag:match("^v(%d+%.%d+%.%d+)$")
    if not version then return nil, _("发布版本号无法识别") end

    local wanted = {
        full = {
            package = Updater.PACKAGE_BASE .. "-" .. version .. ".zip",
            checksum = Updater.PACKAGE_BASE .. "-" .. version .. ".zip.sha256",
        },
        code = {
            package = Updater.PACKAGE_BASE .. "-" .. version .. "-code.zip",
            checksum = Updater.PACKAGE_BASE .. "-" .. version .. "-code.zip.sha256",
        },
    }
    local found = { full = {}, code = {} }
    for _, asset in ipairs(data.assets or {}) do
        local name = type(asset.name) == "string" and asset.name or ""
        local url = type(asset.browser_download_url) == "string" and asset.browser_download_url or nil
        if url and Updater.is_official_url(url) then
            for kind, names in pairs(wanted) do
                if name == names.package then
                    found[kind].url = url
                    found[kind].size = tonumber(asset.size)
                elseif name == names.checksum then
                    found[kind].sha_url = url
                end
            end
        end
    end

    local assets = {}
    for kind, entry in pairs(found) do
        if entry.url and entry.sha_url then
            if entry.size and entry.size > Updater.MAX_PACKAGE_BYTES then
                return nil, _("安装包太大，已跳过")
            end
            assets[kind] = { url = entry.url, sha_url = entry.sha_url, size = entry.size }
        end
    end
    if not assets.full and not assets.code then
        return nil, _("发布里没有可下载的安装包")
    end
    return {
        version = version,
        assets = assets,
        notes = clean_notes(data.body),
        url = type(data.html_url) == "string" and data.html_url or nil,
    }
end

-- 挑要下的那个包：想要的没有就退到另一个（全量包永远能用）。
function Updater.pick_asset(release, kind)
    if type(release) ~= "table" or type(release.assets) ~= "table" then return nil end
    return release.assets[kind] or release.assets.code or release.assets.full
end

------------------------------------------------------------------------
-- 文件小工具（都要能失败得体面）
------------------------------------------------------------------------

local function read_file(path, max_bytes)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    if max_bytes then
        local size = file:seek("end")
        if size and size > max_bytes then
            file:close()
            return nil, _("文件比预期的大")
        end
        file:seek("set", 0)
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

-- 删目录树：优先用 KOReader 的 purgeDir，没有就自己按 lfs 递归，
-- 都没有就当作删不掉（留下垃圾，下次更新时再试，不影响功能）。
local function remove_tree(path)
    if not path or path == "" then return nil, _("路径为空") end
    local ok_util, util = pcall(require, "ffi/util")
    if ok_util and util and util.purgeDir then
        local ok = pcall(util.purgeDir, path)
        if ok then return true end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs and lfs.dir) then return nil, _("无法清理目录") end
    if not lfs.attributes(path, "mode") then return true end
    local function purge(dir)
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local child = dir .. "/" .. entry
                if lfs.attributes(child, "mode") == "directory" then
                    purge(child)
                else
                    os.remove(child)
                end
            end
        end
        lfs.rmdir(dir)
    end
    local ok = pcall(purge, path)
    return ok or nil, ok and nil or _("无法清理目录")
end

local function make_path(path)
    local ok_util, util = pcall(require, "util")
    if ok_util and util and util.makePath then
        return util.makePath(path)
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        if lfs.attributes(path, "mode") == "directory" then return true end
        local ok = lfs.mkdir(path)
        if ok then return true end
        -- 父目录不存在时逐级建（测试环境与部分设备没有 makePath）
        local parent = path:match("^(.+)/[^/]+$")
        if parent and parent ~= path then
            make_path(parent)
            return lfs.mkdir(path)
        end
    end
    return nil, _("无法创建目录")
end

-- 默认工作目录：放在插件目录之外，免得替换插件时把自己删了。
local function default_work_dir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getDataDir then
        local ok_dir, dir = pcall(function() return DataStorage:getDataDir() end)
        if ok_dir and type(dir) == "string" and dir ~= "" then
            return dir .. "/wordgloss-update"
        end
    end
    return "/tmp/wordgloss-update"
end

------------------------------------------------------------------------
-- 实例
------------------------------------------------------------------------

function Updater:new(options)
    options = options or {}
    local obj = {
        settings = options.settings,
        current_version = options.current_version or "0.0.0",
        plugin_dir = options.plugin_dir or "",
        work_dir = options.work_dir or default_work_dir(),
        -- 下面几个可以注入假实现，离线测试就不用真联网、真解压、真读盘。
        http_get = options.http_get,
        extract = options.extract,
        read_file = options.read_file,
        verify = options.verify,
        size_of = options.size_of,
        make_path = options.make_path,
        prefer_proxy = options.prefer_proxy == true,
        now = options.now,
    }
    return setmetatable(obj, self)
end

function Updater:_time()
    return type(self.now) == "function" and self.now() or os.time()
end

function Updater:_read_file(path, max_bytes)
    if self.read_file then return self.read_file(path, max_bytes) end
    return read_file(path, max_bytes)
end

function Updater:_make_path(path)
    if self.make_path then return self.make_path(path) end
    return make_path(path)
end

-- 量一下下载到的文件有多大；量不出来就返回 nil，交给后面的步骤兜底。
function Updater:_size_of(path)
    if self.size_of then return self.size_of(path) end
    if type(io) ~= "table" or not io.open then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

-- 比对下载到的包与发布方给的 SHA-256。
function Updater:_verify(archive, checksum_path)
    if self.verify then return self.verify(archive, checksum_path) end
    local expected = self:_read_file(checksum_path, 4096)
    if not expected then return false end
    return Sha2.verify_file(archive, tostring(expected))
end

function Updater:state()
    if not self.settings or not self.settings.readSetting then return {} end
    local ok, value = pcall(function() return self.settings:readSetting(Updater.STATE_KEY) end)
    if ok and type(value) == "table" then return value end
    return {}
end

-- 注意：value 为 nil 的项不会被写进去（Lua 表里 nil 就是不存在的键），
-- 所以"清掉缓存的更新信息"必须走 clear_available()，不能靠 save_state 赋 nil。
function Updater:save_state(values)
    local state = self:state()
    for key, value in pairs(values or {}) do state[key] = value end
    if not self.settings or not self.settings.saveSetting then return state end
    pcall(function() self.settings:saveSetting(Updater.STATE_KEY, state) end)
    if self.settings.flush then pcall(function() self.settings:flush() end) end
    return state
end

-- 抹掉"有新版本"这条记录（装上了、或服务器上又撤回了时用）。
function Updater:clear_available()
    local state = self:state()
    state.available_version = nil
    state.assets = nil
    state.notes = nil
    state.release_url = nil
    if self.settings and self.settings.saveSetting then
        pcall(function() self.settings:saveSetting(Updater.STATE_KEY, state) end)
        if self.settings.flush then pcall(function() self.settings:flush() end) end
    end
    return state
end

-- 缓存里的新版本（上次检查到的）。没有就 nil。
function Updater:cached_release()
    local state = self:state()
    if not state.available_version then return nil end
    if Updater.compare_versions(state.available_version, self.current_version) ~= 1 then
        return nil
    end
    return {
        version = state.available_version,
        assets = state.assets,
        notes = state.notes,
        url = state.release_url,
    }
end

function Updater:available_version()
    local release = self:cached_release()
    return release and release.version or nil
end

function Updater:has_update()
    return self:cached_release() ~= nil
end

-- 距上次检查过了多久（用于"一天自动查一次"）。
function Updater:last_checked_at()
    return tonumber(self:state().checked_at) or 0
end

function Updater:should_auto_check()
    if self:get_auto_check() ~= true then return false end
    if self:has_update() then return false end           -- 已经在提醒了就别重复问
    return (self:_time() - self:last_checked_at()) >= Updater.CHECK_INTERVAL
end

-- 菜单里的开关：每天自动检查一次（默认关，插件不自己联网）。
function Updater:get_auto_check()
    return self:state().auto_check == true
end

function Updater:set_auto_check(enabled)
    self:save_state{ auto_check = enabled == true }
end

------------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------------

-- 下载/GET。destination 为空时把内容当字符串返回。
-- on_progress(received, total_hint) 可选；max_bytes 超出就中断。
function Updater.default_http_get(url, destination, on_progress, max_bytes)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local ok_socket, socket = pcall(require, "socket")
    local skip = (ok_socket and socket and socket.skip)
        or function(count, ...) return select(count + 1, ...) end

    local file, chunks, sink, received, limit_error
    if destination then
        file = io.open(destination, "wb")
        if not file then return nil, _("无法创建下载文件") end
        local write = (ltn12.sink and ltn12.sink.file and ltn12.sink.file(file))
            or function(chunk) if chunk then file:write(chunk) end return 1 end
        received = 0
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = _("下载内容超过预期大小")
                    return nil, limit_error
                end
                received = received + #chunk
                if on_progress then on_progress(received, max_bytes) end
            end
            return write(chunk, err)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 30, socketutil.FILE_TOTAL_TIMEOUT or 60)
    else
        chunks = {}
        sink = (ltn12.sink and ltn12.sink.table and ltn12.sink.table(chunks))
            or function(chunk) if chunk then chunks[#chunks + 1] = chunk end return 1 end
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT or 30, socketutil.LARGE_TOTAL_TIMEOUT or 60)
    end

    local code, headers, status = skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader-WordGloss-Updater/1.0",
            ["Accept"] = "application/vnd.github+json",
        },
        sink = sink,
        redirect = true,
    })
    socketutil:reset_timeout()
    if file then file:close() end
    if limit_error then
        remove_file(destination)
        return nil, limit_error
    end
    if headers == nil or code ~= 200 then
        remove_file(destination)
        local reason = tostring(code or status or _("未知错误"))
        return nil, _("下载失败（HTTP %1）"):gsub("%%1", function() return reason end)
    end
    return destination and received or table.concat(chunks)
end

-- 多源：直连失败就换镜像，全挂了返回最后一个错误。
function Updater:_get(url, destination, on_progress, max_bytes)
    local getter = self.http_get or Updater.default_http_get
    local candidates = Updater.candidate_urls(url, self.prefer_proxy)
    if #candidates == 0 then
        candidates = { url }
    end
    local last_error
    for _, candidate in ipairs(candidates) do
        local ok, err = getter(candidate, destination, on_progress, max_bytes)
        if ok then
            logger.dbg("wordgloss: update fetch ok:", candidate)
            return ok
        end
        last_error = err
        logger.warn("wordgloss: update source failed:", candidate, tostring(err))
    end
    return nil, last_error or _("所有更新源都不可用")
end

------------------------------------------------------------------------
-- 检查
------------------------------------------------------------------------

--[[--
联网查一次最新版。

成功把结果写进设置（available_version / assets / notes），返回 release；
失败返回 nil, err，并把错误记进 state.last_error，方便菜单里显示原因。
]]
function Updater:fetch()
    local body, err = self:_get(Updater.API_URL)
    if not body then
        self:save_state{ last_error = tostring(err), checked_at = self:_time() }
        return nil, err
    end
    local json = require("json")
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        self:save_state{ last_error = _("更新信息解析失败"), checked_at = self:_time() }
        return nil, _("更新信息解析失败")
    end
    local release, parse_err = Updater.parse_release(data)
    if not release then
        self:save_state{ last_error = tostring(parse_err), checked_at = self:_time() }
        return nil, parse_err
    end
    -- 不是新版就把缓存清掉，免得菜单一直提示一个已经装上的版本。
    if Updater.compare_versions(release.version, self.current_version) ~= 1 then
        self:clear_available()
        self:save_state{ last_error = nil, checked_at = self:_time() }
        return release
    end
    self:save_state{
        available_version = release.version,
        assets = release.assets,
        notes = release.notes,
        release_url = release.url,
        last_error = nil,
        checked_at = self:_time(),
    }
    return release
end

------------------------------------------------------------------------
-- 安装
------------------------------------------------------------------------

local function report(on_progress, stage, percent)
    if on_progress then on_progress(stage, percent) end
end

-- 解压：只接受 wordgloss.koplugin/ 开头的相对路径，挡掉 ../ 与绝对路径。
function Updater.default_extract(archive, stage)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        pcall(function() reader:close() end)
        return nil, reader.err or _("无法打开更新包")
    end
    local ok, err = true, nil
    for entry in reader:iterate() do
        local path = entry.path
        local safe = type(path) == "string"
            and path:sub(1, #Updater.PLUGIN_DIR_NAME + 1) == Updater.PLUGIN_DIR_NAME .. "/"
            and path:find("\\", 1, true) == nil
            and path:match("%.%.") == nil
        if not safe then
            ok, err = nil, _("更新包里的路径不安全")
            break
        end
        if not reader:extractToPath(path, stage .. "/" .. path) then
            ok, err = nil, reader.err or _("更新包解压失败")
            break
        end
    end
    if reader.err then ok, err = nil, reader.err end
    pcall(function() reader:close() end)
    return ok, err
end

--[[--
下载并安装一个 release。

  release     —— fetch() 或 cached_release() 的返回值
  opts.kind        —— "code"（只有代码）或 "full"（含离线词典）
  opts.on_progress —— function(stage, percent)

返回 true / nil, err。中途任何一步失败都不会动插件目录。
]]
function Updater:install(release, opts)
    opts = opts or {}
    if not self.plugin_dir or self.plugin_dir == "" then
        return nil, _("拿不到插件目录，无法更新")
    end
    local asset = Updater.pick_asset(release, opts.kind)
    if not asset then return nil, _("这个版本没有可下载的安装包") end
    local on_progress = opts.on_progress

    report(on_progress, "preparing", 0)
    remove_tree(self.work_dir)
    if not self:_make_path(self.work_dir) then
        return nil, _("无法创建更新临时目录")
    end
    local archive = self.work_dir .. "/package.zip"
    local checksum = archive .. ".sha256"
    local stage = self.work_dir .. "/stage"

    -- 1) 下安装包
    local ok, err = self:_get(asset.url, archive, function(received, total)
        local ratio = (tonumber(asset.size) or 0) > 0
            and math.min(1, received / asset.size) or 0
        report(on_progress, "downloading", math.floor(ratio * 70))
    end, Updater.MAX_PACKAGE_BYTES)
    if not ok then
        remove_tree(self.work_dir)
        return nil, err or _("下载更新包失败")
    end

    -- 2) 体积校验：Release API 给的字节数跟安装包同源、最可信，
    --    先拿它挡住"下载被截断 / 代理返回错误页"这两类最常见的问题。
    report(on_progress, "checking", 73)
    local expected_size = tonumber(asset.size)
    if expected_size and expected_size > 0 then
        local got_size = self:_size_of(archive)
        if got_size and got_size ~= expected_size then
            remove_tree(self.work_dir)
            return nil, _("下载的安装包不完整，已放弃安装")
        end
    end

    -- 3) SHA-256：拿得到摘要就比对，拿不到就跳过。
    --    镜像没同步 .sha256 不该把用户卡住，体积已经核过了。
    report(on_progress, "checksum", 74)
    local ok_sha = self:_get(asset.sha_url, checksum, nil, 4096)
    if ok_sha then
        report(on_progress, "verifying", 78)
        if not self:_verify(archive, checksum) then
            logger.warn("wordgloss: update checksum mismatch:", tostring(archive))
            remove_tree(self.work_dir)
            return nil, _("更新包校验失败，已放弃安装")
        end
    else
        logger.info("wordgloss: 没有可用的 .sha256，跳过哈希校验（体积已核对）")
    end

    -- 4) 解压到临时目录（目录在插件之外，替换时不会把自己删掉）
    report(on_progress, "extracting", 84)
    local extract = self.extract or Updater.default_extract
    local ok_unpack, err_unpack = extract(archive, stage)
    if not ok_unpack then
        remove_tree(self.work_dir)
        return nil, err_unpack or _("更新包解压失败")
    end
    local staged = stage .. "/" .. Updater.PLUGIN_DIR_NAME
    local meta = self:_read_file(staged .. "/_meta.lua", 65536)
    local main = self:_read_file(staged .. "/main.lua", 1024 * 1024)
    local staged_version = meta and meta:match('version%s*=%s*"([^"]+)"') or nil
    if not main or staged_version ~= release.version then
        remove_tree(self.work_dir)
        return nil, _("更新包内容不对，已放弃安装")
    end

    -- 5) 备份 + 换名激活；激活失败立刻换回来
    report(on_progress, "installing", 92)
    local backup = self.plugin_dir .. ".backup"
    remove_tree(backup)
    if not os.rename(self.plugin_dir, backup) then
        remove_tree(self.work_dir)
        return nil, _("无法备份当前版本")
    end
    if not os.rename(staged, self.plugin_dir) then
        os.rename(backup, self.plugin_dir)
        remove_tree(self.work_dir)
        return nil, _("无法启用新版本")
    end
    remove_tree(self.work_dir)
    report(on_progress, "done", 100)
    return true
end

--[[--
删掉上一次更新留下的备份。

只在"插件已经完整加载起来"之后调用（main.lua 的 init 末尾）：新版本如果能跑到
这里，说明它至少是能加载的，旧副本就没必要留着了；反过来，新版本一加载就崩，
插件目录旁边那份 backup 就是唯一的后悔药，所以绝不能在装完的那一刻删。
]]
function Updater:cleanup_backup()
    if not self.plugin_dir or self.plugin_dir == "" then return false end
    local backup = self.plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes and not lfs.attributes(backup, "mode") then
        return false
    end
    local removed = remove_tree(backup)
    if removed then logger.info("wordgloss: 已清理上一次更新的备份") end
    return removed == true
end

function Updater:has_backup()
    local backup = self.plugin_dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes then
        return lfs.attributes(backup, "mode") == "directory"
    end
    return false
end

return Updater
