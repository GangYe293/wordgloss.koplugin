-- 划词翻译接管：劫持 KOReader 原生翻译，复用 wordgloss 的联网引擎。
--
-- 调用链（已核对 KOReader 真机 v2026.07.2 的 frontend/ui/translator.lua 与
-- apps/reader/modules/readerhighlight.lua，并对照 ai_translator.koplugin 的实现）：
--   ReaderHighlight:onTranslateText
--     → Translator:showTranslation(text, true, nil, nil, self, index)   ← 模块级函数
--       → _showTranslation → Trapper:dismissableRunInSubprocess → loadPage（原生网络，子进程里）
--
-- 关键结论（前两版都错在这）：
--   · 选中文字后「Translate」走的是 Translator:showTranslation 这个【模块级】函数，
--     ReaderHighlight 自己没有 showTranslation 方法，它直接 require("ui/translator") 后调用。
--   · 真正的联网在 loadPage，跑在 Trapper 子进程里；插件在父进程里对 Translator.loadPage
--     的 monkey-patch 在子进程重新加载模块后会丢失——这就是「patch 了却从没生效、
--     永远回退到原生 Google（在墙内网络下超时）」的根因。
--   · ai_translator 之所以稳，是因为它替换的是【更靠前的】Translator.showTranslation，
--     这个函数在父进程里就被 onTranslateText 直接调用，patch 一定生效；它自己包办
--     网络 + Trapper:wrap + 弹窗，根本不依赖原生 _showTranslation / 子进程。
--
-- 因此本插件改采 ai_translator 同款、且经真机验证的策略：替换 Translator.showTranslation
-- （以及 Translator.translate 以覆盖词典等其它入口），内部走 wordgloss 的 AI 引擎，并
-- 复刻原生弹窗（复制 / 保存翻译到笔记）。任何失败都安全回退到原生 Google 翻译。
-- 检测到 ai_translator 已加载时主动让出，避免双重 patch。

local logger = require("logger")
local _ = require("gettext")

local Live = {
    _enabled = false,
    _ai_translator_present = false,
    _original_showTranslation = nil,
    _original_translate = nil,
    _Translator = nil,
}

-- ai_translator 已加载时返回 true。只查 package.loaded，不主动 require，以免意外激活它。
function Live.ai_translator_present()
    local loaded = package and package.loaded and package.loaded["ai_translator"]
    if loaded == nil then return false end
    -- 入口对象的 name 字段是 "ai_translator"（见其 main.lua）。
    return type(loaded) == "table" and loaded.name == "ai_translator"
end

-- 读取 KOReader 的目标语言（2 字母大写：ZH/EN/...），与 ai_translator 同逻辑。
function Live:getTargetLanguage()
    local store = rawget(_G, "G_reader_settings")
    local lang = store and store:readSetting("edge_to_language")
    if not lang then
        lang = store and store:readSetting("language")
        if lang and lang ~= "" then
            lang = (lang:match("(.*)-") or lang)
            if lang == "C" then
                lang = "ZH"
            else
                lang = lang:upper()
            end
        end
    end
    return lang or "ZH"
end

local LANG_NAMES = {
    ZH = _("中文（简体）"), EN = _("英语"), JA = _("日语"), KO = _("韩语"),
    FR = _("法语"), DE = _("德语"), ES = _("西班牙语"), RU = _("俄语"),
    IT = _("意大利语"), PT = _("葡萄牙语"), AR = _("阿拉伯语"), HI = _("印地语"),
}

function Live:langName(code)
    return LANG_NAMES[code] or code or "?"
end

-- 真正干活：调用 wordgloss 的 AI 引擎把整段文本翻成 target 语言。
-- 返回 (translation, err)：成功时 translation 为非空字符串、err 为 nil；
-- 失败时 translation 为 nil、err 为 { message=..., code=..., detail=..., raw=... }。
function Live:translateText(text, target, source)
    local AI = require("wordgloss_ai")
    local Providers = require("wordgloss_providers")
    local ai = AI:new{ providers = Providers }
    local ok, res = pcall(function()
        return ai:translate_sentence(text, {
            target_lang = target or self:getTargetLanguage(),
            source_lang = source,
        })
    end)
    if ok and type(res) == "string" and res ~= "" then
        return res
    end
    if not ok then
        logger.warn("wordgloss: 划词翻译引擎异常:", tostring(res))
        return nil, { message = tostring(res) }
    end
    logger.warn("wordgloss: 划词翻译无结果")
    return nil, res
end

-- 复刻 KOReader 原生弹窗（TextViewer）：译文 + 复制 / 保存翻译到笔记。
-- 弹窗在父进程里渲染（不走原生子进程），所以我们的 patch 一定生效。
function Live:showResult(text, translation, detailed_view, source, target, from_highlight, index)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local Device = require("device")
    local Screen = Device.screen
    local T = require("ffi/util").template

    local output = {}
    if detailed_view then
        output[#output + 1] = "▣ " .. text
        output[#output + 1] = ""
        output[#output + 1] = "● " .. translation
    else
        output[#output + 1] = translation
    end
    local text_all = table.concat(output, "\n")

    local buttons_table = {}
    local height
    local close_callback
    if detailed_view then
        height = math.floor(Screen:getHeight() * 0.8)
        if from_highlight then
            local ui = require("apps/reader/readerui").instance
            table.insert(buttons_table, {
                {
                    text = _("保存翻译到笔记"),
                    callback = function()
                        UIManager:close(textviewer)
                        UIManager:close(ui.highlight.highlight_dialog)
                        ui.highlight.highlight_dialog = nil
                        if index then
                            ui.highlight:editNote(index, false, translation)
                        else
                            ui.highlight:addNote(translation)
                        end
                    end,
                },
            })
            close_callback = function()
                if not ui.highlight.highlight_dialog then
                    ui.highlight:clear()
                end
            end
        end
        if Device:hasClipboard() then
            table.insert(buttons_table, {
                {
                    text = _("复制翻译"),
                    callback = function()
                        Device.input.setClipboardText(translation)
                    end,
                },
            })
        end
    end

    local textviewer = TextViewer:new{
        title = T(_("翻译至 %1"), self:langName(source or target)),
        title_multilines = true,
        text = text_all,
        text_type = "lookup",
        height = height,
        add_default_buttons = true,
        buttons_table = buttons_table,
        close_callback = close_callback,
    }
    UIManager:show(textviewer)
end

-- 引擎失败时的错误弹窗（照 ai_translator 的 _showTranslation 错误分支）。
-- 不回退原生 Google 翻译——墙内原生 Google 必超时，只会让用户多等几十秒
-- 然后还是失败，体验远不如直接弹错误信息来得清楚。
function Live:showError(text, err, source, target, from_highlight, index)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    local Screen = require("device").screen
    local T = require("ffi/util").template

    local output = {}
    output[#output + 1] = "❌ 划词翻译失败"
    output[#output + 1] = ""
    if err and type(err) == "table" then
        if err.message then
            output[#output + 1] = tostring(err.message)
        end
        if err.code then
            output[#output + 1] = "HTTP 状态码: " .. tostring(err.code)
        end
        if err.detail then
            output[#output + 1] = "详情: " .. tostring(err.detail)
        end
    elseif err then
        output[#output + 1] = tostring(err)
    else
        output[#output + 1] = "未知错误"
    end
    output[#output + 1] = ""
    output[#output + 1] = "原文: " .. tostring(text):sub(1, 200)

    -- 失败时也要清掉选区（from_highlight 时），避免"卡在选中"。
    if from_highlight then
        local ok_ui, ui = pcall(require, "apps/reader/readerui")
        if ok_ui and ui and ui.instance and ui.instance.highlight then
            pcall(function()
                if ui.instance.highlight.highlight_dialog then
                    pcall(UIManager.close, UIManager, ui.instance.highlight.highlight_dialog)
                    ui.instance.highlight.highlight_dialog = nil
                end
                ui.instance.highlight:clear()
            end)
        end
    end

    UIManager:show(TextViewer:new{
        title = T(_("翻译至 %1 失败"), self:langName(source or target)),
        title_multilines = true,
        text = table.concat(output, "\n"),
        text_type = "lookup",
        height = math.floor(Screen:getHeight() * 0.6),
        add_default_buttons = true,
    })
end

function Live:_showTranslation(text, detailed_view, source_lang, target_lang, from_highlight, index)
    local target = target_lang or self:getTargetLanguage()
    local translated, err = self:translateText(text, target, source_lang)
    if translated then
        self:showResult(text, translated, detailed_view, source_lang, target, from_highlight, index)
        return
    end
    -- 引擎失败：弹错误弹窗（带引擎返回的错误信息），不回退原生 Google
    -- （墙内原生 Google 必超时，回退只会让用户多等几十秒然后还是失败）。
    self:showError(text, err, source_lang, target, from_highlight, index)
end

function Live:enable(plugin)
    if self._enabled then return end

    if Live.ai_translator_present() then
        self._ai_translator_present = true
        logger.warn("wordgloss: 检测到 ai_translator 已加载，跳过划词翻译接管以免冲突")
        return
    end

    local ok_translator, Translator = pcall(require, "ui/translator")
    if not ok_translator or not Translator or not Translator.showTranslation then
        logger.warn("wordgloss: 找不到 ui/translator.showTranslation，划词翻译接管跳过")
        return
    end

    if not self._original_showTranslation then
        self._original_showTranslation = Translator.showTranslation
    end
    if not self._original_translate then
        self._original_translate = Translator.translate
    end
    self._Translator = Translator
    local original_show = self._original_showTranslation
    local original_translate = self._original_translate

    -- 替换模块级 showTranslation：父进程里被 onTranslateText 直接调用，patch 必生效。
    Translator.showTranslation = function(self_mod, text, detailed_view, source_lang, target_lang, from_highlight, index)
        -- 剪贴板（与原生一致）
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device and Device.hasClipboard and Device.input then
            pcall(Device.input.setClipboardText, text)
        end
        -- 无网络时等联网后再试（与原生一致）
        local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_net and NetworkMgr and NetworkMgr.willRerunWhenOnline then
            if NetworkMgr:willRerunWhenOnline(function()
                    Live:_showTranslation(text, detailed_view, source_lang, target_lang, from_highlight, index)
                end) then
                return
            end
        end
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            Live:_showTranslation(text, detailed_view, source_lang, target_lang, from_highlight, index)
        end)
    end

    -- 覆盖其它入口（如词典「翻译单词」走 translate）
    Translator.translate = function(self_mod, text, target_lang, source_lang)
        local translated = Live:translateText(text, target_lang, source_lang)
        if translated then return translated end
        return original_translate(self_mod, text, target_lang, source_lang)
    end

    self._enabled = true
    logger.dbg("wordgloss: 划词翻译接管已启用（showTranslation）")
end

function Live:disable()
    if not self._enabled then return end
    local ok_translator, Translator = pcall(require, "ui/translator")
    if ok_translator and Translator then
        if self._original_showTranslation then
            Translator.showTranslation = self._original_showTranslation
        end
        if self._original_translate then
            Translator.translate = self._original_translate
        end
    end
    self._original_showTranslation = nil
    self._original_translate = nil
    self._Translator = nil
    self._enabled = false
    logger.dbg("wordgloss: 划词翻译接管已关闭")
end

function Live:enabled()
    return self._enabled
end

-- 是否因检测到 ai_translator 而主动让出（供 UI 提示）。
function Live:ai_translator_conflict()
    return self._ai_translator_present
end

return Live
