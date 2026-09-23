-- 生词预取：把"这本书里值得注释的词"批量翻译好放进缓存。
--
-- 为什么需要预取：Edge 免费接口是逐词/小批量的网络请求，翻页时现查会卡顿。
-- 所以这里的流程是——先解析 EPUB 找出每章的生词（不依赖渲染），再按"当前章
-- 优先"的顺序翻译，结果全部落到 SQLite 释义缓存里（跨书共享）。之后翻页时
-- 每一页的注释都是查表，秒出、不需要联网。
--
-- 翻译工作在子进程里跑（KOReader 的 Trapper:dismissableRunInSubprocess），
-- 所以整书翻译时阅读界面依然能翻页：进度通过一个进度文件回传给主进程，
-- 取消通过一个哨兵文件通知子进程。这套做法与 dualtranslate.koplugin 一致。

local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local logger = require("logger")
local _ = require("gettext")

local Cache = require("wordgloss_cache")
local Book = require("wordgloss_book")
local Tools = require("wordgloss_tools")
local Epub = require("wordgloss_epub")
local GlossMod = require("wordgloss_gloss")
local Lexicon = require("wordgloss_lexicon")
local Providers = require("wordgloss_providers")

local Prefetch = {}

Prefetch.PROGRESS_INTERVAL = 20   -- 每翻译这么多词写一次进度

-- KOReader 在极少数代码路径下（插件 init 早于 path 赋值）plugin.path 可能为空。
-- 词频包 data/wordgloss_en.sqlite3 依赖这个路径，缺失会导致整本书被过度翻译。
-- 这里用本文件位置反推插件根目录作为兜底。
local function resolve_plugin_path(plugin)
    if plugin and type(plugin.path) == "string" and plugin.path ~= "" then
        return plugin.path
    end
    local ok, info = pcall(debug.getinfo, 2, "S")
    if ok and info and info.source then
        local src = info.source:gsub("^@", "")
        local dir = src:match("^(.+)/[^/]+$")
        if dir and dir ~= "" then return dir end
    end
    return "."
end

-- ---------------------------------------------------------------------------
-- 子进程侧的 worker
-- ---------------------------------------------------------------------------

local function default_deps(plugin_path)
    local cache = Cache:new()
    return {
        cache = cache,
        lexicon = Lexicon:new(plugin_path),
        book = Book:new(cache),
        tools = Tools,
        epub = Epub,
        gloss = GlossMod,
        providers = Providers,
    }
end

-- 取消哨兵文件存在即代表用户要求停止。io.open 在个别平台上不可用，
-- 所以这里用 pcall 兜住，失败一律当作"没有取消"。
local function file_exists(path)
    if not path or path == "" then return false end
    local ok, file = pcall(io.open, path, "rb")
    if not ok or not file then return false end
    pcall(function() file:close() end)
    return true
end

--[[--
预取 worker（在子进程里执行）。

args 必须能被子进程直接读到（都是普通字符串/数字）：
  plugin_path, book_path, book_id, source_lang, target_lang,
  rank_limit, max_gloss_chars, max_items,
  first_index, last_index, progress_path, cancel_path

deps 可注入（测试用）：cache / lexicon / book / tools / epub / gloss / providers，
以及 cancelled 回调（返回 true 表示应当中止）。

返回一个可序列化的 summary 表。
]]
function Prefetch.run_worker(args, deps)
    deps = deps or default_deps(args.plugin_path)
    local cache, book, tools = deps.cache, deps.book, deps.tools
    local lexicon, gloss_mod, providers = deps.lexicon, deps.gloss, deps.providers
    local cache_lang = args.cache_lang or "zh"
    local lang = args.target_lang or "zh-Hans"
    local book_id = args.book_id

    local summary = {
        state = "running", translated = 0, failed = 0,
        chapters_done = 0, chapters_total = 0, current_index = tonumber(args.first_index) or 1,
    }

    -- 词频包是生词判定的数据源：读不到时 classify 会把所有词当成生词，
    -- 导致整本书被过度翻译。这里提前失败并给出清晰信息，而不是默默翻错。
    if deps.lexicon and not deps.lexicon:available() then
        summary.state, summary.error =
            "error", _("词频包未能加载（data/wordgloss_en.sqlite3 缺失或不可读）")
        write_progress()
        return summary
    else
        logger.dbg("wordgloss: lexicon available, plugin_path=", tostring(args.plugin_path))
    end

    local function cancelled()
        if deps.cancelled then return deps.cancelled() and true or false end
        return file_exists(args.cancel_path)
    end

    local function write_progress()
        if not args.progress_path then return end
        local payload = string.format("%s|%d|%d|%d|%d|%d",
            summary.state, summary.chapters_done, summary.chapters_total,
            summary.translated, summary.failed, summary.current_index)
        local ok = tools.write_file(args.progress_path, payload)
        if not ok then
            logger.warn("wordgloss: failed to write progress file:", args.progress_path)
        end
    end

    -- 1. 解包 + 结构解析
    local work_dir = cache:getBookCacheRoot() .. "/unpack_" .. tostring(os.time())
        .. "_" .. tostring(math.random(1000, 999999))
    if not tools.unzip_to(args.book_path, work_dir) then
        summary.state, summary.error = "error", _("无法解包 EPUB（可能受 DRM 保护）")
        write_progress()
        return summary
    end
    local info, spine_err = deps.epub.spine(work_dir)
    if not info then
        tools.rmtree(work_dir)
        summary.state, summary.error = "error", spine_err or _("无法解析 EPUB 结构")
        write_progress()
        return summary
    end
    local first = math.max(1, tonumber(args.first_index) or 1)
    local last = math.min(tonumber(args.last_index) or #info.spine, #info.spine)
    summary.chapters_total = math.max(0, last - first + 1)
    write_progress()

    local lower = book:lower_seen(book_id) or {}
    local names = book:names(book_id) or {}
    local lower_dirty, names_dirty = false, false

    -- 2. 逐章：扫描 -> 找生词 -> 查缓存 -> 批量翻译
    for index = first, last do
        if cancelled() then summary.state = "cancelled" break end
        summary.current_index = index
        local analysis = book:chapter(book_id, index)
        if not analysis then
            local relative = info.spine[index]
            local document = relative and tools.read_file(work_dir .. "/" .. relative) or nil
            analysis = deps.epub.scan_chapter(document, relative, index)
            book:save_chapter(book_id, index, analysis)
        end

        -- 大小写证据：本书里小写出现过的词 -> 不是专名；只大写出现过的 -> 专名
        for key in pairs(analysis.words or {}) do
            if analysis.lowercase and analysis.lowercase[key] then
                if not lower[key] then lower[key] = true; lower_dirty = true end
            elseif analysis.capitalized and analysis.capitalized[key] then
                if not names[key] and not lower[key] then
                    names[key] = true
                    names_dirty = true
                end
            end
        end

        -- 这一章的候选生词
        local rare = {}
        for key in pairs(analysis.words or {}) do
            local classified = lexicon:classify(key, {
                rank_limit = args.rank_limit,
                reject_names = false,   -- 预取按小写词判断；专名由上面的 names 表负责
                names = names,
                lower_seen = lower,
            })
            if classified then rare[#rare + 1] = classified end
        end
        table.sort(rare, function(a, b) return a.rank > b.rank end)

        -- 缓存里还没有释义的（nil = 没查过；false = 上次翻译失败占位，也要重试）。
        -- force（"重新翻译整本"）时连已有释义的词也重翻一遍。
        local force = args.force == true or args.force == 1 or args.force == "1"
        local missing = {}
        for _, item in ipairs(rare) do
            local key = (item.base and item.base ~= "") and item.base:lower() or item.word
            local cached = cache:getGloss(key, cache_lang)
            if cached == nil then
                cached = cache:getGloss(item.word, cache_lang)
            end
            if cached == nil or cached == false then
                missing[#missing + 1] = { text = key, key = key }
            elseif force then
                missing[#missing + 1] = { text = key, key = key }
            end
        end

        logger.dbg("wordgloss: chapter", index, "candidates=", #rare, "missing=", #missing)
        if #missing > 0 and not cancelled() then
            local texts = {}
            for position, item in ipairs(missing) do texts[position] = item.text end
            local since_write = 0
            providers.translate_all(texts, args.source_lang or "auto", lang,
                function(position, text, translation)
                    local item = missing[position]
                    if not item then return end
                    local clean = gloss_mod.clean(translation, args.max_gloss_chars, args.max_items, text)
                    -- 失败也存一条空记录：下次不会再问同一个词
                    cache:putGloss(item.key, cache_lang, clean or "")
                    if clean then summary.translated = summary.translated + 1
                    else summary.failed = summary.failed + 1 end
                    since_write = since_write + 1
                    if since_write >= Prefetch.PROGRESS_INTERVAL then
                        since_write = 0
                        write_progress()
                    end
                end,
                cancelled)
        end

        book:mark_covered(book_id, index)
        summary.chapters_done = summary.chapters_done + 1
        write_progress()
    end

    if lower_dirty then book:save_lower_seen(book_id, lower) end
    if names_dirty then book:save_names(book_id, names) end

    tools.rmtree(work_dir)
    if summary.state == "running" then summary.state = "done" end
    logger.warn("wordgloss: prefetch finished:", summary.state,
        "chapters=", summary.chapters_done, "/", summary.chapters_total,
        "translated=", summary.translated, "failed=", summary.failed)
    write_progress()
    return summary
end

-- ---------------------------------------------------------------------------
-- 主进程侧的调度
-- ---------------------------------------------------------------------------

function Prefetch:new(plugin)
    local o = { plugin = plugin, running = nil }
    setmetatable(o, self)
    self.__index = self
    return o
end

function Prefetch:get_book_path()
    local document = self.plugin.ui and self.plugin.ui.document
    return document and document.file or nil
end

function Prefetch:dir()
    return self.plugin.cache:getBookCacheRoot()
end

function Prefetch:progress_path(book_id)
    return self:dir() .. "/progress_" .. tostring(book_id) .. ".txt"
end

function Prefetch:cancel_path(book_id)
    return self:dir() .. "/cancel_" .. tostring(book_id) .. ".txt"
end

function Prefetch:is_running()
    return self.running ~= nil
end

-- 读取进度文件：{ state=, chapters_done=, chapters_total=, translated=, failed=, index= }
function Prefetch:progress(book_id)
    if not book_id then return nil end
    local raw = Tools.read_file(self:progress_path(book_id))
    if not raw then return nil end
    local state, done, total, translated, failed, index = raw:match(
        "^([%a]+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)")
    if not state then
        state = raw:match("^(%a+)")
        if not state then return nil end
    end
    return {
        state = state,
        chapters_done = tonumber(done) or 0,
        chapters_total = tonumber(total) or 0,
        translated = tonumber(translated) or 0,
        failed = tonumber(failed) or 0,
        index = tonumber(index) or 0,
    }
end

function Prefetch:request_cancel()
    local running = self.running
    if not running then return false end
    running.cancel_requested = true
    Tools.write_file(running.cancel_path, "cancel")
    return true
end

--[[--
启动预取。

opts = {
    book_path, book_id, first_index, last_index,
    rank_limit, source_lang, target_lang, max_gloss_chars, max_items,
    silent      = true 时不显示进度窗（自动触发的当前章翻译用）
    on_update   = 进度回调
    on_done     = 完成回调 (summary_or_nil, error_message)
}
]]
function Prefetch:start(opts)
    opts = opts or {}
    local plugin = self.plugin
    if self:is_running() then
        return false, _("已有生词翻译任务在运行")
    end
    local book_path = opts.book_path or self:get_book_path()
    if not book_path then return false, _("没有打开的书") end
    local book_id = opts.book_id or Cache.book_id(book_path)
    if not book_id then return false, _("无法识别这本书") end

    Tools.mkdir_p(self:dir())
    local progress_path = self:progress_path(book_id)
    local cancel_path = self:cancel_path(book_id)
    os.remove(cancel_path)
    Tools.write_file(progress_path, "running|0|0|0|0|0")

    local args = {
        plugin_path = resolve_plugin_path(plugin),
        book_path = book_path,
        book_id = book_id,
        source_lang = opts.source_lang or "auto",
        target_lang = opts.target_lang or "zh-Hans",
        rank_limit = opts.rank_limit,
        max_gloss_chars = opts.max_gloss_chars,
        max_items = opts.max_items,
        first_index = opts.first_index or 1,
        last_index = opts.last_index or 9999,
        -- force：连已缓存的词也重翻一遍（用户要整本重译时用）
        force = opts.force and true or nil,
        progress_path = progress_path,
        cancel_path = cancel_path,
    }
    self.running = {
        book_id = book_id, args = args,
        progress_path = progress_path, cancel_path = cancel_path,
        started_at = os.time(), dialog = nil, hidden = false,
    }

    local running = self.running
    local poll_active = true
    local function poll()
        if not poll_active then return end
        local progress = self:progress(book_id)
        if opts.on_update then pcall(opts.on_update, progress) end
        UIManager:scheduleIn(0.5, poll)
    end

    UIManager:scheduleIn(0.1, function()
        -- silent 任务（阅读时自动补翻译）一律不弹进度窗：自动跑的任务没有
        -- 用户操作在前，弹出"开了就关"的窗口只会让人以为出错了。
        if opts.dialog_factory and not opts.silent then
            local ok, dialog = pcall(opts.dialog_factory, {
                progress = function() return self:progress(book_id) end,
                cancel = function()
                    self:request_cancel()
                    return true
                end,
                running = running,
            })
            if ok then running.dialog = dialog end
        end
        UIManager:scheduleIn(0.5, poll)

        local Trapper = require("ui/trapper")
        local resume_ok, wrapped_ok = Trapper:wrap(function()
            local trap_widget = {}
            -- fork 之前不要留着已打开的 SQLite 连接：子进程自己开一条。
            pcall(function() plugin.cache:close() end)
            local completed, result
            -- dismissableRunInSubprocess 在某些平台/版本下可能直接抛错（而非返回
            -- false）。把它包进 pcall，任何异常都转成可诊断的 error 状态，避免
            -- 只给用户一个莫名的"生词翻译启动失败"而拿不到真实原因。
            local sub_ok, sub_err = pcall(function()
                completed, result = Trapper:dismissableRunInSubprocess(function()
                    local ok, info = pcall(Prefetch.run_worker, args)
                    if not ok then
                        logger.warn("wordgloss: prefetch worker error:", info)
                        return { state = "error", error = tostring(info) }
                    end
                    return info
                end, trap_widget)
            end)
            if not sub_ok then
                logger.warn("wordgloss: subprocess call threw:", tostring(sub_err))
                completed, result = false, { state = "error", error = "subprocess: " .. tostring(sub_err) }
            end

            poll_active = false
            pcall(function() plugin.cache:open() end)
            self.running = nil
            os.remove(cancel_path)
            pcall(function()
                if running.dialog and running.dialog.close then running.dialog:close() end
            end)

            local summary = completed and type(result) == "table" and result or nil
            local message
            if not summary then
                message = _("生词翻译已中断")
            elseif summary.state == "error" then
                message = summary.error or _("生词翻译失败")
            elseif summary.state == "cancelled" then
                message = _("已停止生词翻译（已翻译的部分保留）")
            end
            if opts.on_done then
                pcall(opts.on_done, summary, message)
            end
            if message and not opts.silent then
                UIManager:show(Notification:new{ text = message, timeout = 3 })
            end
            if plugin.on_prefetch_finished then
                pcall(function() plugin:on_prefetch_finished(summary) end)
            end
        end)
        -- KOReader 的 Trapper:wrap 返回 (resume_ok, wrapped_ok)：
        --   (true, true)  协程顺利跑完
        --   (true, nil)   协程正常挂起（等子进程/等用户）—— 不是失败！
        --   (false, ...)  协程抛错
        -- 只有显式的 false 才是失败。之前用 `not wrapped_ok` 把 (true, nil)
        -- 也当失败，导致子进程明明在跑却弹"启动失败"、并误清 running 状态
        --> 用户再次点击会并发起第二个 worker → SQLite "database is locked"。
        if resume_ok == false or wrapped_ok == false then
            poll_active = false
            self.running = nil
            logger.warn("wordgloss: prefetch could not start:",
                "resume_ok=", tostring(resume_ok),
                "wrapped_ok=", tostring(wrapped_ok),
                "plugin_path=", tostring(plugin and plugin.path),
                "cache=", tostring(plugin and plugin.cache ~= nil))
            pcall(function()
                if running.dialog and running.dialog.close then running.dialog:close() end
            end)
            if opts.on_done then
                pcall(opts.on_done, nil, _("生词翻译启动失败，请查看日志"))
            end
        end
    end)
    return true
end

return Prefetch
