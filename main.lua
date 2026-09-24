-- WordGloss：把生词的中文释义直接注在词的上方或下方（类似 Kindle Word Wise）。
-- 原书（EPUB 存档、.sdr、书签）一概不动。
--
-- 组成：
--   wordgloss_lexicon.lua    内置词频包 + 生词判定（初级/中级/高级）
--   wordgloss_providers.lua  Edge 免费翻译接口
--   wordgloss_prefetch.lua   后台预取（当前章优先 + 整书），子进程执行
--   wordgloss_overlay.lua    词上方小字绘制层
--   wordgloss_page.lua       当前页单词遍历 + 注释装配
--   wordgloss_epub.lua       EPUB 章节/段落解析（预取需要）
--   wordgloss_cache.lua      释义缓存与每本书状态（SQLite/WAL）
--   wordgloss_ui.lua         菜单与对话框

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Cache = require("wordgloss_cache")
local Book = require("wordgloss_book")
local Lexicon = require("wordgloss_lexicon")
local Page = require("wordgloss_page")
local Overlay = require("wordgloss_overlay")
local Prefetch = require("wordgloss_prefetch")
local UI = require("wordgloss_ui")

local wordgloss = WidgetContainer:extend{
    name = "wordgloss",
    is_doc_only = false,
}

local SETTING_PREFIX = "wordgloss_"
local AUTO_PREFETCH_COOLDOWN = 30   -- 自动预取的两次尝试之间至少间隔多少秒

------------------------------------------------------------------------
-- 生命周期
------------------------------------------------------------------------

function wordgloss:init()
    -- 先把菜单挂上。顺序很重要：init 里任何一步出错都会被 pluginloader 的
    -- pcall 兜住，结果是插件在菜单里凭空消失、只在日志留一行。所以菜单注册
    -- 必须放在最前面，后面的初始化失败也不会影响入口可见。
    if self.ui and self.ui.menu then
        local menu_ok, menu_err = pcall(function()
            self.ui.menu:registerToMainMenu(self)
        end)
        if not menu_ok then
            logger.err("wordgloss: 注册主菜单失败:", tostring(menu_err))
        end
    else
        logger.warn("wordgloss: ui.menu 不可用，跳过菜单注册")
    end

    local ok, err = pcall(function()
        self.cache = Cache:new()
        self.lexicon = Lexicon:new(self.path)
        self.book = Book:new(self.cache)
        self.prefetch = Prefetch:new(self)
        self._page_refresh_scheduled = false
        self._lower_dirty = false
        self._auto_prefetch_at = 0

        -- 请求翻译需要 Wi-Fi，但不要把"忽略"的用户选择覆盖掉。
        if G_reader_settings and not G_reader_settings:readSetting(SETTING_PREFIX .. "silent_network") then
            G_reader_settings:saveSetting(SETTING_PREFIX .. "silent_network", true)
        end
    end)
    if not ok then
        self._init_error = tostring(err)
        logger.err("wordgloss: 初始化失败（菜单仍可用，状态项会显示原因）:", tostring(err))
    end
end

function wordgloss:addToMainMenu(menu_items)
    -- 菜单构建出错时退回极简菜单：宁可少几个选项，也不能整个入口不见。
    local ok, items = pcall(UI.build_menu, self)
    if not ok or type(items) ~= "table" or #items == 0 then
        logger.err("wordgloss: 构建菜单失败，使用兜底菜单:", tostring(items))
        items = UI.fallback_menu(self)
    end
    menu_items.wordgloss = {
        text = _("生词注释"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

function wordgloss:onReaderReady()
    -- 绘制层：ReaderView 会把注册过的模块在页面之后画到同一个 blitbuffer 上。
    if not self.overlay and self.ui and self.ui.view then
        self.overlay = Overlay:new{
            glosses = {},
            font_size = self:getSetting("font_size", 12),
            font_face = self:getSetting("font_face"),
            underline = self:getSetting("underline", true),
            gloss_offset = self:getGlossOffset(),
            underline_offset = self:getUnderlineOffset(),
            underline_style = self:getUnderlineStyle(),
            underline_thickness = self:getUnderlineThickness(),
        }
        local ok, err = pcall(function()
            self.ui.view:registerViewModule("wordgloss", self.overlay)
        end)
        if not ok then
            logger.warn("wordgloss: registerViewModule failed:", tostring(err))
        end
    end
    self:hookStyleSheet()
    -- 只有用户上次选了「开始转换」才恢复；否则打开书什么都不做。
    if not self:isEnabled() then return end
    UIManager:nextTick(function()
        self:refreshDocumentStyles()
        self:refreshGlosses(true)
    end)
end

-- 读取设置时就把样式挂上：此时还在初始排版里，不会触发"需要重新加载"的提示。
function wordgloss:onReadSettings()
    if self:isEnabled() then
        self:hookStyleSheet()
        self:refreshDocumentStyles()
    end
end

function wordgloss:onPageUpdate()
    self:scheduleGlossRefresh()
end

function wordgloss:onPosUpdate()
    self:scheduleGlossRefresh()
end

function wordgloss:onDocumentRerendered()
    if self.overlay then self.overlay.placed = nil end
    self:scheduleGlossRefresh()
end

wordgloss.onDocumentPartiallyRerendered = wordgloss.onDocumentRerendered

function wordgloss:onCloseDocument()
    if self.overlay then self.overlay:clear() end
    self:flush_lower_seen()
    if self.cache then self.cache:close() end
end

function wordgloss:onSaveSettings()
    self:flush_lower_seen()
end

function wordgloss:on_prefetch_finished(summary)
    -- 翻译结束后立刻把新到手的释义画出来 / 写进 CSS。
    self:refreshGlosses(true)
    self:refreshDocumentStyles()
    if summary and summary.state == "done" and not self._silent_prefetch then
        UI.showInfo(T(_("生词翻译完成：新增 %1 个词"), summary.translated or 0), 2)
    end
end

------------------------------------------------------------------------
-- 设置
------------------------------------------------------------------------

function wordgloss:getSetting(key, default)
    local value = G_reader_settings and G_reader_settings:readSetting(SETTING_PREFIX .. key)
    if value == nil then return default end
    return value
end

--[[--
KOReader 的 LuaSettings:saveSetting 只改内存，只有 flush()/close() 才真正写
settings.reader.lua；而 KOReader 只在正常退出时才统一 flush。Kindle 上一旦是
挂起/掉电/崩溃退出，这一次写的设置就整批没了——这正是「昨天明明开始过转换，
今天却提示还没开始」的原因（释义缓存是 SQLite，写完就在盘上，所以数据是活的）。

本插件的所有设置都由用户点菜单产生，不存在高频写入，立刻落盘是安全的。
]]
function wordgloss:saveSetting(key, value)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting(SETTING_PREFIX .. key, value)
    if G_reader_settings.flush then
        pcall(function() G_reader_settings:flush() end)
    end
end

-- 默认关闭：插件安装后不会在打开书时自己开始翻译。
-- 必须由用户在菜单里点「开始转换」才会生效（之后记住这个选择）。
function wordgloss:isEnabled()
    return self:getSetting("enabled", false) == true
end

--[[--
菜单里的「显示注释生词」：勾上才把注释画到书页上，取消则只隐藏（数据仍在）。

「开始转换」与「显示」是两件事：前者做转换，后者管看不看得到。取消显示时
注释和为它预留的行距都要撤掉，所以所有绘制/注入的入口统一走 isVisible()。
]]
function wordgloss:showGlosses()
    return self:getSetting("show_glosses", true) == true
end

function wordgloss:isVisible()
    return self:isEnabled() and self:showGlosses()
end

--[[--
有没有可以拿来显示的东西：看释义缓存里有没有记录。

释义缓存是跨书共享的（同一语言的词一次翻译永久复用），所以昨天在别的书里
翻译过、今天换本书也能用。它跟「开始转换」那个开关是两件事——开关丢了对用户
没有意义，缓存才是"我昨天已经转过"的证据。判断显示与否应该看这个，而不是看
enabled 标志位。
]]
function wordgloss:hasGlossData()
    if not self:is_usable() then return false end
    local ok, count = pcall(function()
        return self.cache and self.cache:countGlosses(self:getGlossLangKey()) or 0
    end)
    return ok and tonumber(count) ~= nil and tonumber(count) > 0
end

--[[--
「显示注释生词」的勾选/取消。

一次都没翻译过时确实无东西可显示，提示用户去点「开始转换」；但只要缓存里
已经有释义（昨天转过即可，哪怕是别的书留下的），就直接显示，并顺手把丢失的
"已开始"状态补上——不必为了看注释再点一次开始转换。
]]
function wordgloss:toggle_gloss_visibility(menu)
    if not self:is_usable() then
        UI.showInfo(_("插件未正常初始化，请重启 KOReader"), 3)
        return false
    end
    if not self:hasGlossData() then
        UI.showInfo(_("还没有注释生词，请先点上面的「开始转换」"), 3)
        if menu and menu.updateItems then menu:updateItems() end
        return false
    end
    -- 以"界面上看着是勾还是没勾"为准决定翻到哪边，不能用 show_glosses 本身：
    -- 开关状态丢失时 UI 上显示为没勾（isVisible 为假），而 show_glosses 仍是
    -- true，照它取反会把用户刚点的"显示"变成隐藏。
    local want_visible = not self:isVisible()
    -- 状态可能没跟着落盘（见 saveSetting 的说明）：有数据就当已开始，别让用户重来。
    if not self:isEnabled() then self:saveSetting("enabled", true) end
    self:saveSetting("show_glosses", want_visible)
    self:applyEnabledState(menu)
    UI.showInfo(self:showGlosses()
        and _("已显示注释生词")
        or _("已隐藏注释生词（注释数据仍在，重新勾选即可恢复）"), 2)
    return true
end

-- 菜单上显示当前字体：手选的是完整路径，只显示文件名。
function wordgloss:fontLabel()
    local face = self:getSetting("font_face")
    if not face or face == "" then return nil end
    return face:match("([^/\\]+)$") or face
end

-- 初始化失败时（self.cache/lexicon/book 缺失）所有功能静默降级，
-- 不要在每个事件回调里抛异常刷日志。
function wordgloss:is_usable()
    return self.cache ~= nil and self.lexicon ~= nil and self.book ~= nil
end

-- "inline" = 注释在词上方；"below" = 注释在下划线下方。
-- 旧版本存过的 "paragraph"（段落下方生词表）已废弃，一律退回 inline。
function wordgloss:getMode()
    local mode = self:getSetting("mode", "inline")
    if mode ~= "inline" and mode ~= "below" then return "inline" end
    return mode
end

function wordgloss:getRankLimit()
    local custom = tonumber(self:getSetting("custom_rank"))
    if custom and custom > 0 then return custom end
    local level = self:getSetting("level", Lexicon.DEFAULT_LEVEL)
    return Lexicon.level_rank(level) or Lexicon.level_rank(Lexicon.DEFAULT_LEVEL)
end

function wordgloss:getLevelLabel()
    local custom = tonumber(self:getSetting("custom_rank"))
    if custom and custom > 0 then return T(_("自定义（阈值 %1）"), custom) end
    local level = self:getSetting("level", Lexicon.DEFAULT_LEVEL)
    return Lexicon.level_name(level) or Lexicon.level_name(Lexicon.DEFAULT_LEVEL)
end

function wordgloss:getTargetLang()
    return self:getSetting("target_lang", "zh-Hans")
end

-- 注释离单词的额外距离（像素，正 = 往上、离词更远；负 = 压近词身）。
function wordgloss:getGlossOffset()
    local value = tonumber(self:getSetting("gloss_offset", 0)) or 0
    if value < -40 then value = -40 end
    if value > 40 then value = 40 end
    return math.floor(value)
end

-- 下划线离单词的额外距离（像素，正 = 往下、离词更远）。
function wordgloss:getUnderlineOffset()
    local value = tonumber(self:getSetting("underline_offset", 0)) or 0
    if value < -40 then value = -40 end
    if value > 40 then value = 40 end
    return math.floor(value)
end

function wordgloss:getUnderlineStyle()
    local style = self:getSetting("underline_style", "solid")
    if style ~= "dashed" and style ~= "wavy" then return "solid" end
    return style
end

-- 线的密度：small 疏 / medium 中 / large 密 / custom 自定义。虚线与波浪线共用一份。
function wordgloss:getUnderlineDensity()
    local value = self:getSetting("underline_density", "medium")
    if value ~= "small" and value ~= "large" and value ~= "custom" then return "medium" end
    return value
end

-- 自定义密度时的数值（像素），2~24，越小越密。
function wordgloss:getUnderlineDensityValue()
    local value = math.floor(tonumber(self:getSetting("underline_density_value", 6)) or 6)
    if value < 2 then value = 2 end
    if value > 24 then value = 24 end
    return value
end

function wordgloss:getUnderlineThickness()
    local value = math.floor(tonumber(self:getSetting("underline_thickness", 2)) or 2)
    if value < 1 then value = 1 end
    if value > 6 then value = 6 end
    return value
end

-- 一条下划线占的高度（不含偏移）：波浪线要把波峰波谷算进来。
function wordgloss:underlineHeight()
    local thickness = self:getUnderlineThickness()
    if self:getUnderlineStyle() == "wavy" then
        local _, amplitude = Overlay.wave_metrics(
            self:getUnderlineDensity(), self:getUnderlineDensityValue())
        return 2 * amplitude + thickness
    end
    return thickness
end

-- 把当前的绘制参数一次性喂给绘制层（创建时与每次刷新注释时都要调）。
function wordgloss:apply_overlay_style()
    if not self.overlay then return end
    self.overlay.mode = self:getMode()
    self.overlay.gloss_offset = self:getGlossOffset()
    self.overlay.underline_offset = self:getUnderlineOffset()
    self.overlay.underline_style = self:getUnderlineStyle()
    self.overlay.underline_thickness = self:getUnderlineThickness()
    self.overlay.underline_density = self:getUnderlineDensity()
    self.overlay.underline_density_value = self:getUnderlineDensityValue()
end

-- 缓存键用目标语言的短名，换语言不会串释义。
function wordgloss:getGlossLangKey()
    local lang = self:getTargetLang()
    if lang:match("^zh") then return "zh" end
    return lang
end

function wordgloss:getBookId()
    local path = self.ui and self.ui.document and self.ui.document.file
    if not path then return nil end
    return Cache.book_id(path)
end

-- 把当前"开/关"状态真正落到界面：样式表 + 绘制层 + 菜单勾选。
function wordgloss:applyEnabledState(menu)
    if self.overlay then
        -- 转换没开始、或用户把「显示注释生词」取消了：都只是不画，数据不动。
        if self:isVisible() then
            self.overlay.font_size = self:getGlossFontSize()
            self.overlay.font_face = self:getSetting("font_face")
            self.overlay.underline = self:getSetting("underline", true) == true
            self:apply_overlay_style()
        else
            self.overlay:clear()
        end
    end
    self:refreshDocumentStyles()
    self:refreshGlosses(true)
    if menu and menu.updateItems then menu:updateItems() end
end

function wordgloss:toggleEnabled(menu)
    self:saveSetting("enabled", not self:isEnabled())
    self:applyEnabledState(menu)
end

--[[--
菜单里的「开始转换」：打开注释，然后问用户要不要现在联网翻译生词。

插件不在打开书时自作主张跑起来——开始、翻译范围、词汇量都是用户在这里选的。
]]
function wordgloss:start_translation(menu)
    if not self:is_usable() then
        UI.showInfo(_("插件未正常初始化，请重启 KOReader"), 3)
        return
    end
    self:saveSetting("enabled", true)
    -- 用户主动点上来的意思就是要看注释，顺手把上一次的"隐藏"恢复。
    self:saveSetting("show_glosses", true)
    self:applyEnabledState(menu)
    UI.ask_translate_scope(self)
end

--「停止转换」：立刻撤掉注释与行距，不再请求网络。
function wordgloss:stop_translation(menu)
    self:saveSetting("enabled", false)
    self:applyEnabledState(menu)
    UI.showInfo(_("已停止注释。原书未被修改。"), 2)
end

------------------------------------------------------------------------
-- 样式：为行间注释腾出空间，或写入段落生词表
------------------------------------------------------------------------

function wordgloss:getGlossFontSize()
    local size = tonumber(self:getSetting("font_size", 12)) or 12
    return math.max(6, math.min(24, size))
end

-- 注释画在行盒的上（或下）半部分，所以需要 line-height 留出空间。
-- 偏移也算进去：注释往外推、下划线往外推都会吃掉行间空白，行距不够就会压到
-- 相邻的行。「词上方」时注释与下划线各占一边，取大的那个；「词下方」时两者
-- 叠在同一边（词 -> 下划线 -> 注释），要相加。
function wordgloss:gap_css(document)
    local font_size = 16
    local ok, size = pcall(function() return document:getFontSize() end)
    if ok and tonumber(size) then font_size = tonumber(size) end
    local gloss = self:getGlossFontSize()
    local gloss_need = gloss * 0.9 + math.max(0, self:getGlossOffset())
    local underline_need = math.max(0, self:getUnderlineOffset()) + self:underlineHeight()
    local need
    if self:getMode() == "below" then
        need = gloss_need + underline_need + 2
    else
        need = math.max(gloss_need, underline_need)
    end
    -- 行距 = 1 + 2 * 需要的高度 / 正文字号（上下各留一半）
    local lh = 1 + (2 * need / math.max(1, font_size))
    if lh < 1.5 then lh = 1.5 end
    if lh > 4.0 then lh = 4.0 end
    return string.format(
        "p,li,dd,dt,blockquote,div,td,pre{line-height:%.2f !important;}", lh)
end

-- 注入的样式只受这些设置影响：它们一变就重新应用样式表。
function wordgloss:style_signature()
    return table.concat({
        tostring(self:isVisible()), self:getMode(),
        tostring(self:getGlossFontSize()),
        tostring(self:getSetting("font_face")),
        tostring(self:getSetting("underline", true)),
        tostring(self:getSetting("reject_names", true)),
        tostring(self:getSetting("max_gloss_chars", 12)),
        tostring(self:getRankLimit()),
        tostring(self:lastKnownChapterIndex()),
        tostring(self:getGlossOffset()),
        tostring(self:getUnderlineOffset()),
        tostring(self:getUnderlineStyle()),
        tostring(self:getUnderlineThickness()),
        tostring(self:getUnderlineDensity()),
        tostring(self:getUnderlineDensityValue()),
    }, "|")
end

-- 把额外的 CSS 交给引擎。真正的 CSS 由 hookStyleSheet 里的包装函数追加
-- （这样 KOReader 自己重设样式表时我们的行距/生词表也会跟着生效），
-- 这里只负责在设置变化时触发一次重新应用。
function wordgloss:refreshDocumentStyles()
    local document = self.ui and self.ui.document
    local typeset = self.ui and self.ui.typeset
    if not document or not typeset or not document.setStyleSheet then return false end

    local signature = self:style_signature()
    if document._wordgloss_style_signature == signature then return true end
    document._wordgloss_style_signature = signature

    local css = typeset.css or document.default_css or ""
    local tweaks = self.ui.styletweak and self.ui.styletweak:getCssText() or ""
    local ok = pcall(function() document:setStyleSheet(css, tweaks) end)
    if not ok then
        document._wordgloss_style_signature = nil
        return false
    end
    UIManager:nextTick(function()
        local ui = self.ui
        if not ui or not ui.view then return end
        pcall(function()
            local new_page = document:getCurrentPage()
            if new_page then ui:handleEvent(require("ui/event"):new("PageUpdate", new_page)) end
            ui.view:recalculate()
            ui:handleEvent(require("ui/event"):new("InitScrollPageStates"))
        end)
    end)
    return true
end

-- 包装 document:setStyleSheet，在引擎每次应用样式表时追加我们的 CSS。
-- 这样字体/排版变化导致的重排也会带上行距，不会出现"注释压在正文上"。
function wordgloss:hookStyleSheet()
    local document = self.ui and self.ui.document
    if not document or document._wordgloss_hooked then return end
    local original = document.setStyleSheet
    if not original then return end
    document._wordgloss_hooked = true
    local plugin = self
    document.setStyleSheet = function(doc, css, tweaks_css)
        local extra = tweaks_css or ""
        -- 隐藏注释时连行距也撤掉：留着只会让页面白白变稀疏。
        if plugin:isVisible() then
            -- 注意：这里运行在 CREngine 应用样式表的执行中间，绝对不能做任何
            -- 重入引擎的调用（如分页探测 getPageFromXPointer）——那会段错误、
            -- 直接杀死 KOReader 进程。只允许纯 Lua/SQLite 的 CSS 生成，
            -- 且整体包 pcall：任何出错宁可少注入一段 CSS 也不能炸排版。
            local ok, more = pcall(function() return plugin:gap_css(doc) end)
            if ok and more and more ~= "" then
                extra = extra .. "\n" .. more
            end
        end
        return original(doc, css, extra)
    end
end

------------------------------------------------------------------------
-- 当前页注释
------------------------------------------------------------------------

-- 当前页所在章节索引（spine 顺序，从 1 开始）。
--
-- CREngine 序列化出的 xpointer 形如 "/body/DocFragment/body/..."，
-- 不带片段序号，所以单靠字符串匹配无法拿到章节号。因此分两段：
--   1) 先尝试从 xpointer 里直接解析 "DocFragment[7]"（部分引擎会带序号，
--      也是单元测试桩的用法）；
--   2) 解析失败时回退到探针式探测：逐章探测其首頁，取"首頁 <= 当前页"
--      的最后一章（逻辑移植自 dualtranslate 的 currentChapterIndex）。
-- 探测结果按 (document, page) 缓存，翻页时增量探测，避免每页扫描整本 spine。
-- 便宜章节号：纯内存值，不做任何 CREngine 调用。
-- 供 setStyleSheet 钩子与 style_signature 使用——那些上下文里引擎处于
-- 排版中间态，重入（如分页探测）会导致段错误、杀死整个 KOReader 进程。
-- 备忘值只在排版外的安全时机更新（见 refreshGlosses / 探针成功时）。
function wordgloss:lastKnownChapterIndex()
    local cache = self._chapter_index_cache
    if cache and cache.index then return cache.index end
    return self._last_chapter_index or 1
end

function wordgloss:getCurrentChapterIndex()
    local document = self.ui and self.ui.document
    if not document then return 1 end
    -- 快路：直接从 xpointer 解析片段序号。
    local ok, xpointer = pcall(function() return document:getXPointer() end)
    if ok and xpointer then
        local index = tostring(xpointer):match("DocFragment%[(%d+)%]")
        if index then
            local idx = tonumber(index)
            self._last_chapter_index = idx
            return idx
        end
    end
    -- 真机回退：探针式探测（CREngine xpointer 不带序号）。
    -- 只能从排版外的安全上下文调用（翻页事件、菜单动作、ReaderReady 后的
    -- nextTick）；绝不能在 setStyleSheet 钩子里走到这里。
    local idx = self:_probeChapterIndex(document)
    if idx then return idx end
    return self._last_chapter_index or 1
end

function wordgloss:_probeChapterIndex(document)
    if not document
        or not document.isXPointerInDocument
        or not document.getPageFromXPointer
        or not document.getCurrentPage then
        return nil
    end
    -- 重入守卫：探测过程如果又被自己（或样式钩子等路径）调进来，
    -- 直接返回已知值，绝不并发重入 CREngine。
    if self._chapter_probing then
        local cache = self._chapter_index_cache
        return (cache and cache.index) or self._last_chapter_index
    end
    local current_page = document:getCurrentPage()
    if not current_page then return nil end
    local cache = self._chapter_index_cache
    if cache and cache.page == current_page and cache.document == document then
        return cache.index
    end
    local function probe(index)
        local xp = "/body/DocFragment[" .. tostring(index) .. "]/body"
        local ok_in, in_doc = pcall(function()
            return document:isXPointerInDocument(xp)
        end)
        -- 返回 (page, exists)：空 spine 项（在文档内但无排版，page<=0）
        -- 算"存在但无页"，扫描时跳过而非当作 spine 末尾；只有片段缺失
        -- 才终止扫描。
        if not ok_in or not in_doc then return nil, false end
        local ok_page, page = pcall(function()
            return document:getPageFromXPointer(xp)
        end)
        if not ok_page or not page then return nil, false end
        if page <= 0 then return nil, true end
        return page, true
    end
    self._chapter_probing = true
    local ok, best = pcall(function()
        local found
        local start = (cache and cache.index) or 1
        -- 向前扫描（翻到下一页）。
        local index = start
        while index <= 4096 do
            local page, exists = probe(index)
            if not exists then break end
            if page then
                if page <= current_page then
                    found = index
                else
                    break
                end
            end
            index = index + 1
        end
        -- 向后扫描（翻到上一页）：缓存章节的首頁在当前页之后，
        -- 从缓存位置往前找最近一个仍早于当前页的章节。
        if not found and start > 1 then
            index = start - 1
            while index >= 1 do
                local page, exists = probe(index)
                if not exists then break end
                if page and page <= current_page then
                    found = index
                    break
                end
                index = index - 1
            end
        end
        return found
    end)
    self._chapter_probing = nil
    if ok and best then
        self._chapter_index_cache = { page = current_page, index = best, document = document }
        self._last_chapter_index = best
        return best
    end
    return nil
end

function wordgloss:scheduleGlossRefresh()
    if self._page_refresh_scheduled then return end
    self._page_refresh_scheduled = true
    UIManager:nextTick(function()
        self._page_refresh_scheduled = false
        self:refreshGlosses(false)
    end)
end

--[[--
刷新当前页的注释。

注释只在"已启用"时出现：停用后任何调用（包括设置变更触发的 force 调用）
都只会清空绘制层，不会又把注释画回来。
]]
function wordgloss:refreshGlosses(force)
    local document = self.ui and self.ui.document
    if not document then return end
    if not self.overlay then return end
    if not self:is_usable() then
        self.overlay:clear()
        return
    end
    if not self:isVisible() then
        self.overlay:clear()
        UIManager:setDirty(self.ui.view, "ui")
        return
    end
    -- 安全时机更新章节备忘：本函数只从 nextTick / UI 回调 / 翻译完成触发，
    -- 都在排版外，这里探测分页是安全的（setStyleSheet 钩子绝不探测，
    -- 只读 lastKnownChapterIndex 的内存值）。
    self._last_chapter_index = self:getCurrentChapterIndex()

    local book_id = self:getBookId()
    local lower = book_id and self.book:lower_seen(book_id) or {}
    local names = book_id and self.book:names(book_id) or {}

    self.overlay.font_size = self:getGlossFontSize()
    self.overlay.font_face = self:getSetting("font_face")
    self.overlay.underline = self:getSetting("underline", true) == true
    self:apply_overlay_style()

    local glosses, pending, stats = Page.build_glosses(document,
        document:getCurrentPage(), {
            lexicon = self.lexicon,
            cache = self.cache,
            rank_limit = self:getRankLimit(),
            reject_names = self:getSetting("reject_names", true) == true,
            lower_seen = lower,
            names = names,
            lang = self:getGlossLangKey(),
            max_per_page = tonumber(self:getSetting("max_per_page", 6)) or 6,
        })
    self._lower_dirty = true
    local ok, font_size = pcall(function() return document:getFontSize() end)
    self.overlay:setGlosses(glosses, ok and font_size or nil)
    UIManager:setDirty(self.ui.view, "ui")

    self._last_stats = stats
    if #pending > 0 then
        self:maybe_auto_prefetch()
    end
end

-- 页面上有生词但还没释义时，静默地把当前章交给后台预取（受冷却时间限制）。
-- 默认关闭：默认只在用户点「开始转换」时联网，不会自己跑网络请求。
function wordgloss:maybe_auto_prefetch()
    if not self.prefetch then return end
    if self:getSetting("auto_prefetch", false) ~= true then return end
    if not self:isEnabled() then return end
    if self.prefetch:is_running() then return end
    local now = os.time()
    if now - (self._auto_prefetch_at or 0) < AUTO_PREFETCH_COOLDOWN then return end
    self._auto_prefetch_at = now
    self._silent_prefetch = true
    self:start_prefetch_chapter(true)
end

function wordgloss:flush_lower_seen()
    if not self._lower_dirty or not self:is_usable() then return end
    local book_id = self:getBookId()
    if not book_id then return end
    self._lower_dirty = false
    pcall(function() self.book:save_lower_seen(book_id, self.book:lower_seen(book_id)) end)
end

------------------------------------------------------------------------
-- 预取入口
------------------------------------------------------------------------

function wordgloss:prefetch_options(silent)
    local book_path = self.ui and self.ui.document and self.ui.document.file
    local book_id = self:getBookId()
    return {
        book_path = book_path,
        book_id = book_id,
        source_lang = "auto",
        target_lang = self:getTargetLang(),
        -- 缓存读写用的短语言键（zh-Hans -> zh），必须与主进程 getGlossLangKey() 一致，
        -- 否则 worker 写下"zh-Hans"而主进程读"zh"，翻译成功也永远显示不出来。
        cache_lang = self:getGlossLangKey(),
        rank_limit = self:getRankLimit(),
        max_gloss_chars = tonumber(self:getSetting("max_gloss_chars", 12)) or 12,
        max_items = tonumber(self:getSetting("gloss_max_items", 2)) or 2,
        silent = silent,
    }
end

function wordgloss:start_prefetch_chapter(silent)
    if not self.prefetch then UI.showInfo(_("插件未正常初始化，请重启 KOReader")); return end
    local options = self:prefetch_options(silent)
    if not options.book_id then UI.showInfo(_("没有打开的书")); return end
    local index = self:getCurrentChapterIndex()
    options.first_index = index
    options.last_index = index
    options.silent = silent and true or nil
    -- silent（自动补翻译）时绝不能弹窗：本章可能瞬间扫完，
    -- 用户只会看到一个开了就关的进度窗。
    if not silent then
        options.dialog_factory = function(hooks) return UI.progress_dialog(_("正在翻译本章生词…"), hooks) end
    end
    options.on_done = function(summary, message)
        self._silent_prefetch = nil
        if message and not silent then UI.showInfo(message, 3) end
        if summary and summary.state == "done" then
            if self:isEnabled() then
                self:refreshGlosses(true)
                self:refreshDocumentStyles()
            elseif not silent then
                UI.showInfo(_("翻译完成。点「开始转换」即可看到注释"), 3)
            end
        end
    end
    local ok, err = self.prefetch:start(options)
    if not ok and err and not silent then UI.showInfo(err) end
    return ok
end

function wordgloss:start_prefetch_book(force)
    if not self.prefetch then UI.showInfo(_("插件未正常初始化，请重启 KOReader")); return end
    local options = self:prefetch_options(false)
    if not options.book_id then UI.showInfo(_("没有打开的书")); return end
    options.first_index = 1
    options.last_index = 9999
    options.force = force and true or nil
    if force then
        options.dialog_title = _("正在重新翻译全书生词…")
    end
    options.dialog_factory = function(hooks)
        return UI.progress_dialog(options.dialog_title or _("正在翻译全书生词…"), hooks)
    end
    options.on_done = function(summary, message)
        if message then UI.showInfo(message, 3) end
        if summary then
            if self:isEnabled() then
                self:refreshGlosses(true)
                self:refreshDocumentStyles()
            else
                UI.showInfo(_("翻译完成。点「开始转换」即可看到注释"), 3)
            end
        end
    end
    local ok, err = self.prefetch:start(options)
    if not ok and err then UI.showInfo(err) end
end

function wordgloss:show_prefetch_progress()
    local book_id = self:getBookId()
    if not book_id or not self.prefetch then return end
    local progress = self.prefetch:progress(book_id)
    if not progress then
        UI.showInfo(_("还没有翻译记录"))
        return
    end
    UI.showInfo(T(_("章节 %1/%2，已翻译 %3，无译文 %4"),
        progress.chapters_done, progress.chapters_total,
        progress.translated, progress.failed), 4)
end

------------------------------------------------------------------------
-- 维护
------------------------------------------------------------------------

function wordgloss:clear_book_data()
    local book_id = self:getBookId()
    if not book_id or not self:is_usable() then return end
    self.book:reset(book_id)
    self.cache:clearBookState(book_id)
    self:refreshGlosses(true)
    self:refreshDocumentStyles()
    UI.showInfo(_("已清除本书注释数据（释义缓存保留）"))
end

function wordgloss:clear_gloss_cache()
    if not self:is_usable() then return end
    local count = self.cache:countGlosses(self:getGlossLangKey())
    self.cache:clearGlosses()
    self:refreshGlosses(true)
    UI.showInfo(T(_("已清空 %1 条释义缓存"), count))
end

-- 状态行：一眼看出"有没有开始、用哪一档词汇量、攒了多少释义"。
-- 还没开始时直接把入口写出来，省得用户找菜单。
function wordgloss:status_text()
    if self._init_error then
        return T(_("初始化异常：%1"), self._init_error)
    end
    if not self:is_usable() then
        return _("内部组件不可用，请重启 KOReader")
    end
    local count = self.cache:countGlosses(self:getGlossLangKey())
    local state
    if self:isVisible() then
        state = _("已显示")
    elseif self:isEnabled() then
        state = _("已转换，注释未显示（勾上面的「显示注释生词」）")
    elseif count > 0 then
        -- 开关状态可能没落盘，或这本是转过的另一本书：缓存还在就能直接显示。
        state = _("有释义但未显示（勾上面的「显示注释生词」）")
    else
        state = _("未开始（点上面的「开始转换」）")
    end
    if not self.lexicon:available() then
        return T(_("%1；词频包不可用；释义缓存 %2 条"), state, count)
    end
    return T(_("%1；词汇量 %2；释义缓存 %3 条"),
        state, self:getLevelLabel(), count)
end

return wordgloss
