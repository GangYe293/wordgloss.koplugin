-- 菜单与对话框。

local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local SpinWidget = require("ui/widget/spinwidget")
local _ = require("gettext")
local T = require("ffi/util").template

local Lexicon = require("wordgloss_lexicon")

local UI = {}

function UI.showInfo(text, timeout)
    UIManager:show(Notification:new{ text = text, timeout = timeout or 2 })
end

function UI.confirm(options, on_confirm)
    local dialog
    dialog = ButtonDialog:new{
        title = options.title,
        buttons = {{
            {
                text = options.cancel_text or _("取消"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = options.confirm_text or _("确定"),
                callback = function()
                    UIManager:close(dialog)
                    if on_confirm then on_confirm() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

function UI.spin(options)
    local spin
    spin = SpinWidget:new{
        title_text = options.title,
        info_text = options.info,
        value = options.value,
        value_min = options.min,
        value_max = options.max,
        value_step = options.step or 1,
        value_hold_step = options.hold_step or 10,
        precision = "%d",
        callback = function()
            local value = math.floor(spin.value_widget.value + 0.5)
            value = math.max(options.min, math.min(options.max, value))
            options.callback(value)
        end,
    }
    UIManager:show(spin)
end

function UI.input(options, on_submit)
    local dialog
    dialog = InputDialog:new{
        title = options.title,
        description = options.description,
        input = options.value or "",
        buttons = {{
            {
                text = _("取消"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("确定"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    on_submit(value)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
预取进度窗。返回的 dialog 对象带 close()；调用方负责在任务结束时关闭。

  hooks = {
      progress = function() return progress_table end,
      cancel   = function() 请求取消 end,
      running  = 任务对象（用于读取 started_at 等）
  }
]]
--[[--
进度窗：不必要地频繁重绘。

ProgressbarDialog 的每次刷新都是整窗重绘（reportProgress 内部自带 setDirty），
所以 0.5 秒一次、哪怕百分比没变也重绘 = 屏幕上"一直在闪"。这里按百分比步长
节流：只有进度真的往前走了 PROGRESS_STEP 个点才刷新一次。

抽成纯函数是为了能在离线测试里直接断言阈值。
]]
UI.PROGRESS_STEP = 2

function UI.should_refresh(last_percentage, percentage)
    if type(percentage) ~= "number" then return false end
    if type(last_percentage) ~= "number" then return true end   -- 首次绘制
    if percentage <= last_percentage then return false end      -- 没往前走就不画
    if percentage >= 100 and last_percentage < 100 then return true end  -- 收尾必画
    return (percentage - last_percentage) >= UI.PROGRESS_STEP
end

--[[--
进度窗只留「标题 + 进度条」。

副标题那三行（章节 x/y、已翻译生词、无译文、点按说明）又长又不居中，
挤在进度条下面很难看，直接不显示。这里把 subtitle 置空，并尽量把那一行
从布局里摘掉，免得空行把标题和进度条顶得不居中。
摘不掉也不影响：空文本只是一行留白，布局依旧居中。
]]
function UI.hide_subtitle(dialog)
    local frame = dialog and dialog[1]
    local group = frame and frame[1]
    if not group then return end
    local subtitle_widget
    for index, widget in ipairs(group) do
        if index == 2 then
            subtitle_widget = widget
            break
        end
    end
    if not subtitle_widget then return end
    if subtitle_widget.setText then subtitle_widget:setText("") end
    if group.removeWidget then
        pcall(function()
            group:removeWidget(subtitle_widget)
            if group.resetLayout then group:resetLayout() end
        end)
    end
    pcall(function() UIManager:setDirty(dialog, "ui") end)
end

function UI.progress_dialog(title, hooks)
    local dialog = ProgressbarDialog:new{
        title = title,
        subtitle = "",
        progress_max = 100,
        refresh_time_seconds = 0.5,
        dismissable = true,
    }
    dialog._wordgloss_hidden = false

    local original_close = dialog.onCloseWidget
    function dialog:onCloseWidget()
        self._wordgloss_hidden = true
        if original_close then return original_close(self) end
    end

    function dialog:onTapClose(arg, ges)
        if ges and ges.pos and self[1] and self[1].dimen
            and ges.pos:intersectWith(self[1].dimen) then
            local actions
            actions = ButtonDialog:new{
                title = _("生词翻译进行中。\n已翻译的部分会保留，可以随时继续。"),
                buttons = {{
                    {
                        text = _("继续后台翻译"),
                        callback = function() UIManager:close(actions) end,
                    },
                    {
                        text = _("停止翻译"),
                        callback = function()
                            UIManager:close(actions)
                            if hooks and hooks.cancel then hooks.cancel() end
                            UI.showInfo(_("正在停止…当前批次完成后结束"))
                        end,
                    },
                }},
            }
            UIManager:show(actions)
            return true
        end
        return ProgressbarDialog.onDismiss(self)
    end

    dialog:show()
    UI.hide_subtitle(dialog)

    local active = true
    dialog._wordgloss_stop = function() active = false end
    local last_percentage = nil
    local function poll()
        if not active then return end
        local progress = hooks and hooks.progress and hooks.progress() or nil
        if progress and not dialog._wordgloss_hidden then
            local total = math.max(1, progress.chapters_total or 0)
            local done = progress.chapters_done or 0
            local percentage = math.floor(done * 100 / total + 0.5)
            if percentage > 100 then percentage = 100 end
            -- 只有进度往前走了才重画：整窗重绘在屏幕上就是"闪一下"。
            if UI.should_refresh(last_percentage, percentage) then
                last_percentage = percentage
                dialog.title = string.format("%s  %d%%", title, percentage)
                pcall(function()
                    local frame = dialog[1]
                    local group = frame and frame[1]
                    if group and group[1] and group[1].setText then group[1]:setText(dialog.title) end
                    dialog:reportProgress(percentage)
                    UIManager:setDirty(dialog, "ui")
                end)
            end
        end
        UIManager:scheduleIn(0.5, poll)
    end
    UIManager:scheduleIn(0.5, poll)
    return dialog
end

--[[--
「开始转换」之后问一句翻译范围。

这一步是用户自己点的，不是插件自作主张：范围（本章 / 整本 / 不翻译）
也交给用户选。
]]
function UI.ask_translate_scope(plugin)
    local dialog
    dialog = ButtonDialog:new{
        title = _("已开始注释生词。\n现在联网翻译吗？\n（也可以稍后从「翻译生词」菜单里手动开始）"),
        buttons = {
            {
                {
                    text = _("翻译本章"),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:start_prefetch_chapter()
                    end,
                },
                {
                    text = _("翻译整本（后台）"),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:start_prefetch_book()
                    end,
                },
            },
            {
                {
                    text = _("只用已有释义"),
                    callback = function()
                        UIManager:close(dialog)
                        UI.showInfo(_("已开始注释；没有释义的生词需先在「翻译生词」里翻译"), 3)
                    end,
                },
                {
                    text = _("停止转换"),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:stop_translation()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- 菜单
-- ---------------------------------------------------------------------------

local MODE_LABELS = {
    inline = _("词上方小字"),
    below = _("词下方小字"),
}

-- 线型 -> 菜单文案
local STYLE_LABELS = {
    solid = _("实线"),
    dashed = _("虚线"),
    wavy = _("波浪线"),
}

-- 密度 -> 菜单文案（大 = 更密：虚线更碎、波浪更窄）
local DENSITY_LABELS = {
    small = _("小（疏）"),
    medium = _("中"),
    large = _("大（密）"),
    custom = _("自定义…"),
}

-- 当前密度的菜单文案：自定义档要把数值显示出来。
local function density_text(plugin, id)
    if id == "custom" then
        return T(_("自定义（%1 px）"), plugin:getUnderlineDensityValue())
    end
    return DENSITY_LABELS[id] or DENSITY_LABELS.medium
end

-- ---------------------------------------------------------------------------
-- 字体选择
-- ---------------------------------------------------------------------------

-- 挑字体时只列这些后缀，目录里其它几百个文件不用看。
local FONT_SUFFIXES = { ttf = true, otf = true, ttc = true }

local function is_font_file(name)
    local suffix = tostring(name):match("%.([%w]+)$")
    return suffix ~= nil and FONT_SUFFIXES[suffix:lower()] == true
end

-- 选择器的起始目录：KOReader 自带字体的 fonts 目录；找不到就退到数据目录本身。
function UI.font_root_dir()
    local base
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage and DataStorage.getDataDir then
        local ok_dir, dir = pcall(DataStorage.getDataDir, DataStorage)
        if ok_dir and type(dir) == "string" and dir ~= "" then base = dir end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not base and ok_lfs and lfs and lfs.currentdir then
        base = lfs.currentdir()
    end
    if not base or base == "" then base = "/" end
    if ok_lfs and lfs and lfs.attributes then
        local font_dir = base .. "/fonts"
        local ok_attr, attr = pcall(lfs.attributes, font_dir)
        if ok_attr and attr and attr.mode == "directory" then return font_dir end
    end
    return base
end

--[[--
打开 KOReader 的文件浏览让用户在里面挑字体文件。

PathChooser 的选中方式是"长按项名"（会再弹一次确认），触屏和按键都能操作。
万一当前 KOReader 版本没有这个组件，退回手输——宁可少个方便的点，
也不能让"选字体"这条菜单点下去没反应。
]]
function UI.choose_font_file(on_picked)
    local ok, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok or type(PathChooser) ~= "table" then
        UI.input({
            title = _("注释字体"),
            description = _("填字体名（例如 Noto Sans CJK SC）或完整的字体文件路径。"),
            value = "",
        }, on_picked)
        return
    end
    local chooser
    chooser = PathChooser:new{
        title = _("选择注释字体（长按文件名选中）"),
        path = UI.font_root_dir(),
        select_directory = false,
        select_file = true,
        show_files = true,
        detailed_file_info = false,
        file_filter = function(filename) return is_font_file(filename) end,
        onConfirm = function(file_path)
            UIManager:close(chooser)
            on_picked(file_path)
        end,
    }
    UIManager:show(chooser)
end

-- ---------------------------------------------------------------------------
-- 菜单片段
-- ---------------------------------------------------------------------------

-- 词汇量级别：初级 / 中级 / 高级（按语料库词频 1500 / 3000 / 5000），
-- 另外允许自定义阈值。层级只是"过滤掉常见词"的尺子，释义仍由 Edge 接口提供。
-- 标题只写「词汇量」：三个级别在次级菜单里，主菜单不用再重复一遍。
function UI.level_menu(plugin)
    local items = {}
    -- 循环变量不能叫 `_`：那会遮蔽文件顶部的 gettext 函数 `_()`。
    for level_index = 1, #Lexicon.LEVELS do
        local level = Lexicon.LEVELS[level_index]
        local id = level.id
        local rank = level.rank
        local level_name = level.name
        table.insert(items, {
            text = T(_("%1（不注释最常见的 %2 词）"), level_name, rank),
            radio = true,
            checked_func = function()
                return plugin:getSetting("custom_rank") == nil
                    and plugin:getSetting("level", Lexicon.DEFAULT_LEVEL) == id
            end,
            callback = function()
                plugin:saveSetting("level", id)
                plugin:saveSetting("custom_rank", nil)
                plugin:refreshDocumentStyles()
                plugin:refreshGlosses(true)
            end,
        })
    end
    table.insert(items, {
        text_func = function()
            local custom = plugin:getSetting("custom_rank")
            return custom and T(_("自定义阈值：%1"), custom) or _("自定义阈值…")
        end,
        checked_func = function() return plugin:getSetting("custom_rank") ~= nil end,
        callback = function()
            UI.spin({
                title = _("词汇量级别的词频阈值"),
                info = _("语料库排名超过它的词会被注释\n1500≈初级 / 3000≈中级 / 5000≈高级"),
                value = plugin:getSetting("custom_rank") or plugin:getRankLimit(),
                min = 300, max = Lexicon.MAX_CUSTOM_RANK,
                step = 100, hold_step = 500,
                callback = function(value)
                    plugin:saveSetting("custom_rank", value)
                    plugin:refreshDocumentStyles()
                    plugin:refreshGlosses(true)
                end,
            })
        end,
    })
    return {
        text = _("词汇量"),
        sub_item_table = items,
    }
end

--[[--
「开始转换」与其子项。

父项只当分组用（KOReader 里带子菜单的行点击是进子菜单，不会触发回调），
真正的开关是子项第一行；这一行的勾代表"转换已经开始了"。
]]
function UI.start_menu(plugin)
    return {
        text = _("开始转换"),
        sub_item_table = {
            {
                text = _("开始转换"),
                checked_func = function() return plugin:isEnabled() end,
                callback = function(menu_self)
                    if plugin:isEnabled() then
                        plugin:stop_translation(menu_self)
                    else
                        plugin:start_translation(menu_self)
                    end
                end,
            },
            {
                text = _("显示注释生词"),
                checked_func = function() return plugin:isVisible() end,
                callback = function(menu_self)
                    plugin:toggle_gloss_visibility(menu_self)
                end,
            },
            {
                text = _("说明：释义缓存跨书共享，昨天转过的词今天换本书也能直接显示"),
                enabled_func = function() return false end,
            },
        },
    }
end

-- 注释模式（注释设置里的第一项）
function UI.mode_menu_item(plugin)
    return {
        text_func = function()
            return _("注释样式：") .. (MODE_LABELS[plugin:getMode()] or MODE_LABELS.inline)
        end,
        sub_item_table = (function()
            local items = {}
            -- 循环变量不能叫 `_`：那会遮蔽文件顶部的 gettext 函数 `_()`。
            for _, mode_id in ipairs({ "inline", "below" }) do
                local id, label = mode_id, MODE_LABELS[mode_id]
                table.insert(items, {
                    text = label,
                    radio = true,
                    checked_func = function() return plugin:getMode() == id end,
                    callback = function()
                        plugin:saveSetting("mode", id)
                        plugin:refreshDocumentStyles()
                        plugin:refreshGlosses(true)
                    end,
                })
            end
            table.insert(items, {
                text = _("说明：两种样式都不改动原书；「词下方小字」的顺序是 词→下划线→注释"),
                enabled_func = function() return false end,
            })
            return items
        end)(),
    }
end

-- 注释字体（注释设置里的一项）
function UI.font_menu_item(plugin)
    return {
        text_func = function()
            local label = plugin:fontLabel()
            return _("注释字体：") .. (label or _("跟随KOReader"))
        end,
        sub_item_table = {
            {
                text = _("跟随KOReader"),
                radio = true,
                checked_func = function()
                    local face = plugin:getSetting("font_face")
                    return face == nil or face == ""
                end,
                callback = function()
                    plugin:saveSetting("font_face", nil)
                    plugin:refreshGlosses(true)
                end,
            },
            {
                text = _("选择字体…"),
                callback = function()
                    UI.choose_font_file(function(file_path)
                        if not file_path or file_path == "" then return end
                        plugin:saveSetting("font_face", file_path)
                        plugin:refreshGlosses(true)
                        UI.showInfo(T(_("注释字体：%1"), plugin:fontLabel() or file_path), 3)
                    end)
                end,
            },
            {
                text = _("说明：选 .ttf/.otf/.ttc 文件；没有汉字字形的纯英文字体会显示成方框"),
                enabled_func = function() return false end,
            },
        },
    }
end

-- 注释设置：样式 / 字号 / 每页上限 / 释义长度 / 偏移 / 字体 / 专名过滤
function UI.gloss_settings_menu(plugin)
    return {
        text = _("注释设置"),
        sub_item_table = {
            UI.mode_menu_item(plugin),
            {
                text_func = function() return _("注释字号：") .. plugin:getSetting("font_size", 12) end,
                callback = function()
                    UI.spin({
                        title = _("注释字号"),
                        info = _("字太小看不清可以调大；调大会占用更多行间空间"),
                        value = plugin:getSetting("font_size", 12),
                        min = 8, max = 24,
                        callback = function(value)
                            plugin:saveSetting("font_size", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local max_per_page = plugin:getSetting("max_per_page", 6)
                    if max_per_page <= 0 then return _("每页注释上限：不限") end
                    return T(_("每页注释上限：%1（生僻的优先）"), max_per_page)
                end,
                callback = function()
                    UI.spin({
                        title = _("每页最多显示几条注释"),
                        info = _("一页生词太多时先注释最生僻的；0 表示不限"),
                        value = plugin:getSetting("max_per_page", 6),
                        min = 0, max = 30,
                        callback = function(value)
                            plugin:saveSetting("max_per_page", value)
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            },
            {
                text_func = function() return _("释义长度上限：") .. plugin:getSetting("max_gloss_chars", 12) .. _(" 字") end,
                callback = function()
                    UI.spin({
                        title = _("释义长度上限"),
                        info = _("超出部分会被截断，保证注释能塞进两行之间"),
                        value = plugin:getSetting("max_gloss_chars", 12),
                        min = 4, max = 30,
                        callback = function(value)
                            plugin:saveSetting("max_gloss_chars", value)
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("注释偏移：%1 px"), plugin:getGlossOffset())
                end,
                callback = function()
                    UI.spin({
                        title = _("注释离单词的距离"),
                        info = _("正值把注释推离单词（词上方模式往上、词下方模式往下）；负值压近词身。\n范围 -20~40，0 = 紧贴单词。\n偏移变大时行距会自动加大，不会压到相邻的行"),
                        value = plugin:getGlossOffset(),
                        min = -20, max = 40,
                        callback = function(value)
                            plugin:saveSetting("gloss_offset", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            },
            UI.font_menu_item(plugin),
            {
                text = _("不注释人名/地名（只大写出现过的词）"),
                checked_func = function() return plugin:getSetting("reject_names", true) == true end,
                callback = function()
                    plugin:saveSetting("reject_names", not (plugin:getSetting("reject_names", true) == true))
                    plugin:refreshGlosses(true)
                end,
            },
        },
    }
end

-- 下划线设置：开关 / 样式（含粗细、密度）/ 偏移
function UI.underline_settings_menu(plugin)
    return {
        text = _("下划线设置"),
        sub_item_table = {
            {
                text = _("显示下划线"),
                checked_func = function() return plugin:getSetting("underline", true) == true end,
                callback = function()
                    plugin:saveSetting("underline", not (plugin:getSetting("underline", true) == true))
                    plugin:refreshGlosses(true)
                end,
            },
            UI.underline_style_menu_item(plugin),
            {
                text_func = function()
                    return T(_("下划线偏移：%1 px"), plugin:getUnderlineOffset())
                end,
                callback = function()
                    UI.spin({
                        title = _("下划线离单词的距离"),
                        info = _("正值把下划线往下推、离单词更远；负值往上贴近词身。\n范围 -20~40，0 = 紧贴单词下方"),
                        value = plugin:getUnderlineOffset(),
                        min = -20, max = 40,
                        callback = function(value)
                            plugin:saveSetting("underline_offset", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            },
        },
    }
end

-- 下划线样式：实线 / 虚线 / 波浪线 + 粗细 + 密度
function UI.underline_style_menu_item(plugin)
    return {
        text_func = function()
            local style = STYLE_LABELS[plugin:getUnderlineStyle()] or STYLE_LABELS.solid
            return _("下划线样式：") .. style .. " · " .. plugin:getUnderlineThickness() .. _(" px")
        end,
        sub_item_table = (function()
            local items = {}
            for _, style_id in ipairs({ "solid", "dashed", "wavy" }) do
                local id = style_id
                table.insert(items, {
                    text = STYLE_LABELS[id],
                    radio = true,
                    checked_func = function() return plugin:getUnderlineStyle() == id end,
                    callback = function()
                        plugin:saveSetting("underline_style", id)
                        plugin:refreshDocumentStyles()
                        plugin:refreshGlosses(true)
                    end,
                })
            end
            table.insert(items, {
                text_func = function()
                    return _("下划线粗细：") .. plugin:getUnderlineThickness() .. _(" px")
                end,
                callback = function()
                    UI.spin({
                        title = _("下划线粗细"),
                        info = _("1~6 像素。调粗会占用更多行间空间，行距会自动跟着加大"),
                        value = plugin:getUnderlineThickness(),
                        min = 1, max = 6,
                        callback = function(value)
                            plugin:saveSetting("underline_thickness", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                        end,
                    })
                end,
            })
            -- 密度：虚线与波浪线共用一份（实线没有密度）
            table.insert(items, {
                text_func = function()
                    return _("线的密度：") .. density_text(plugin, plugin:getUnderlineDensity())
                end,
                enabled_func = function() return plugin:getUnderlineStyle() ~= "solid" end,
                sub_item_table = (function()
                    local options = {}
                    -- 循环变量绝不能叫 `_`：那会遮蔽 gettext 的 `_()`，
                    -- 下面自定义分支里的 _("…") 会变成"调用一个数字"而崩掉。
                    local density_ids = { "small", "medium", "large", "custom" }
                    for density_index = 1, #density_ids do
                        local id = density_ids[density_index]
                        table.insert(options, {
                            text_func = function() return density_text(plugin, id) end,
                            radio = true,
                            checked_func = function() return plugin:getUnderlineDensity() == id end,
                            callback = function()
                                if id ~= "custom" then
                                    plugin:saveSetting("underline_density", id)
                                    plugin:refreshDocumentStyles()
                                    plugin:refreshGlosses(true)
                                    return
                                end
                                -- 自定义：弹数字框，让用户自己定密度
                                UI.spin({
                                    title = _("自定义线的密度"),
                                    info = _("单位：像素，数值越小越密。\n虚线 = 一段实线的长度；波浪线 = 半个波的宽度（一个完整波 = 2 倍）。\n范围 2~24，默认 6"),
                                    value = plugin:getUnderlineDensityValue(),
                                    min = 2, max = 24,
                                    callback = function(value)
                                        plugin:saveSetting("underline_density", "custom")
                                        plugin:saveSetting("underline_density_value", value)
                                        plugin:refreshDocumentStyles()
                                        plugin:refreshGlosses(true)
                                    end,
                                })
                            end,
                        })
                    end
                    return options
                end)(),
            })
            table.insert(items, {
                text = _("说明：密度只对虚线和波浪线生效；数值越小越密（虚线更碎、波浪更窄）。\n自定义档以像素为单位，可填 2~24"),
                enabled_func = function() return false end,
            })
            return items
        end)(),
    }
end

-- 清除注释数据：本书数据 / 全部释义缓存
function UI.clear_menu(plugin)
    return {
        text = _("清除注释数据"),
        sub_item_table = {
            {
                text = _("清除本书注释数据"),
                callback = function()
                    UI.confirm({
                        title = _("清除本书的章节索引、专名表与已翻章节记录？\n已翻译的释义会保留（其它书也能用）。原书不会被修改。"),
                        confirm_text = _("清除"),
                    }, function() plugin:clear_book_data() end)
                end,
            },
            {
                text = _("清空全部释义缓存"),
                callback = function()
                    UI.confirm({
                        title = _("删除所有已翻译的释义（全部书）？\n下次使用需要重新联网翻译。"),
                        confirm_text = _("清空"),
                    }, function() plugin:clear_gloss_cache() end)
                end,
            },
        },
    }
end

--[[--
菜单骨架。

层级：开始转换 / 词汇量 / 注释设置 / 下划线设置 / 翻译生词 / 清除注释数据 / 状态。
设置项按"注释"与"下划线"分两组收起来，主菜单只留六七个入口，
不用在十几行里找某个偏移。
]]
function UI.build_menu(plugin)
    local menu = {}

    -- 主入口：手动开始/停止。插件默认不启用，也不会在打开书时自己跑起来。
    table.insert(menu, UI.start_menu(plugin))

    -- 词汇量级别：开始前先选好，初级/中级/高级。
    table.insert(menu, UI.level_menu(plugin))

    table.insert(menu, UI.gloss_settings_menu(plugin))

    table.insert(menu, UI.underline_settings_menu(plugin))

    -- 翻译：联网动作一律手动触发（「开始转换」时也会问一次）
    table.insert(menu, {
        text_func = function()
            local running = plugin.prefetch ~= nil and plugin.prefetch:is_running()
            return running and _("翻译生词（联网）：进行中…") or _("翻译生词（联网）")
        end,
        sub_item_table_func = function()
            return UI.build_prefetch_menu(plugin)
        end,
    })

    -- 维护
    table.insert(menu, UI.clear_menu(plugin))

    table.insert(menu, {
        text_func = function() return _("状态：") .. plugin:status_text() end,
        enabled_func = function() return false end,
    })

    return menu
end

-- 兜底菜单：正常菜单构建失败时用。这里只调用最基本的接口，
-- 保证"入口一定在"，并把出错原因直接显示在菜单里。
function UI.fallback_menu(plugin)
    return {
        {
            text_func = function()
                return plugin:isEnabled() and _("停止转换") or _("开始转换")
            end,
            callback = function(menu_self)
                if plugin:isEnabled() then
                    plugin:stop_translation(menu_self)
                else
                    plugin:start_translation(menu_self)
                end
            end,
        },
        {
            text_func = function()
                return _("插件初始化异常：") .. tostring(plugin._init_error or _("菜单构建失败"))
            end,
            enabled_func = function() return false end,
        },
        {
            text = _("请查看 koreader/crash.log 里的 wordgloss 记录"),
            enabled_func = function() return false end,
        },
    }
end

function UI.build_prefetch_menu(plugin)
    local items = {}
    local prefetch = plugin.prefetch
    local function is_running()
        return prefetch ~= nil and prefetch:is_running()
    end

    table.insert(items, {
        text = _("翻译当前章的生词"),
        callback = function() plugin:start_prefetch_chapter() end,
    })
    table.insert(items, {
        text = _("翻译整本书的生词（后台）"),
        callback = function() plugin:start_prefetch_book() end,
    })
    table.insert(items, {
        text = _("重新翻译整本（联网，覆盖已有释义）"),
        callback = function()
            UI.confirm({
                title = _("重新翻译整本书的生词，覆盖已有的释义？\n会重新联网一次；原书不会被修改。"),
                confirm_text = _("开始"),
            }, function() plugin:start_prefetch_book(true) end)
        end,
    })
    table.insert(items, {
        text = _("查看翻译进度"),
        enabled_func = function() return is_running() end,
        callback = function() plugin:show_prefetch_progress() end,
    })
    table.insert(items, {
        text = _("停止翻译"),
        enabled_func = function() return is_running() end,
        callback = function()
            if prefetch then prefetch:request_cancel() end
            UI.showInfo(_("正在停止翻译…已翻译部分会保留"))
        end,
    })
    table.insert(items, {
        text = _("说明：翻译是联网动作，只发送生词本身，不发送正文"),
        enabled_func = function() return false end,
    })
    table.insert(items, {
        text = _("阅读时自动补翻译生词（默认关，会自己联网）"),
        checked_func = function()
            return plugin:getSetting("auto_prefetch", false) == true
        end,
        callback = function()
            local enabled = plugin:getSetting("auto_prefetch", false) == true
            plugin:saveSetting("auto_prefetch", not enabled)
            if not enabled then
                UI.showInfo(_("已开启：翻页遇到没有释义的生词时会自动联网翻译当前章"))
            end
        end,
    })
    return items
end

return UI
