-- 菜单与对话框。

local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local SpinWidget = require("ui/widget/spinwidget")
local Trapper = require("ui/trapper")
local _ = require("gettext")
local T = require("ffi/util").template

local Lexicon = require("wordgloss_lexicon")
local Updater = require("wordgloss_update")

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
        -- 窗一关就停掉轮询：不然这条每 0.5 秒读一次进度文件的定时器会一直
        -- 跑到 KOReader 退出为止。想再看进度，从菜单里重开一个窗即可。
        if self._wordgloss_stop then pcall(self._wordgloss_stop) end
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
        -- worker 收尾时会把 state 写成 done / cancelled / error。见到这个就收工，
        -- 别让 "已完成" 的进度窗继续空转（也别留一条永远排队的定时器）。
        if progress and progress.state and progress.state ~= "running" then
            active = false
            pcall(function() if dialog.close then dialog:close() end end)
            return
        end
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
            return custom and T(_("自定义：%1"), custom) or _("自定义…")
        end,
        checked_func = function() return plugin:getSetting("custom_rank") ~= nil end,
        callback = function(menu)
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
                    -- 这一项有 checked_func，菜单不会关，但标题里的数字要手动刷
                    if menu and menu.updateItems then menu:updateItems() end
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
                keep_menu_open = true,
                callback = function(menu)
                    UI.choose_font_file(function(file_path)
                        if not file_path or file_path == "" then return end
                        plugin:saveSetting("font_face", file_path)
                        plugin:refreshGlosses(true)
                        if menu and menu.updateItems then menu:updateItems() end
                        UI.showInfo(T(_("注释字体：%1"), plugin:fontLabel() or file_path), 3)
                    end)
                end,
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
            UI.font_menu_item(plugin),
            {
                text_func = function() return _("注释字号：") .. plugin:getSetting("font_size", 12) end,
                -- keep_menu_open：调完字号回到这一层菜单，而不是掉回阅读页
                -- （KOReader 对没有 checked_func 的项默认是执行完回调就关菜单）。
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("注释字号"),
                        info = _("字太小看不清可以调大；调大会占用更多行间空间"),
                        value = plugin:getSetting("font_size", 12),
                        min = 8, max = 24,
                        callback = function(value)
                            plugin:saveSetting("font_size", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                            -- 菜单上的「注释字号：12」要跟着变成新值
                            if menu and menu.updateItems then menu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local max_per_page = plugin:getSetting("max_per_page", 6)
                    if max_per_page <= 0 then return _("每页注释上限：不限") end
                    return T(_("每页注释上限：%1（生僻字优先）"), max_per_page)
                end,
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("每页最多显示几条注释"),
                        info = _("一页生词太多时先注释最生僻的；0 表示不限"),
                        value = plugin:getSetting("max_per_page", 6),
                        min = 0, max = 30,
                        callback = function(value)
                            plugin:saveSetting("max_per_page", value)
                            plugin:refreshGlosses(true)
                            if menu and menu.updateItems then menu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function() return _("释义长度上限：") .. plugin:getSetting("max_gloss_chars", 12) .. _(" 字") end,
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("释义长度上限"),
                        info = _("超出部分会被截断，保证注释能塞进两行之间"),
                        value = plugin:getSetting("max_gloss_chars", 12),
                        min = 4, max = 30,
                        callback = function(value)
                            plugin:saveSetting("max_gloss_chars", value)
                            plugin:refreshGlosses(true)
                            if menu and menu.updateItems then menu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("注释偏移：%1 px"), plugin:getGlossOffset())
                end,
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("注释离单词的距离"),
                        info = _("正值把注释推离单词（词上方模式往上、词下方模式往下）；负值压近词身。\n范围 -20~40，0 = 紧贴单词。\n偏移变大时行距会自动加大，不会压到相邻的行"),
                        value = plugin:getGlossOffset(),
                        min = -20, max = 40,
                        callback = function(value)
                            plugin:saveSetting("gloss_offset", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                            if menu and menu.updateItems then menu:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("显示词性（adj./n./vt.）"),
                checked_func = function() return plugin:showPos() end,
                callback = function()
                    plugin:saveSetting("show_pos", not plugin:showPos())
                    plugin:refreshGlosses(true)
                end,
            },
            {
                text = _("不注释人名/地名"),
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
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("下划线离单词的距离"),
                        info = _("正值把下划线往下推、离单词更远；负值往上贴近词身。\n范围 -20~40，0 = 紧贴单词下方"),
                        value = plugin:getUnderlineOffset(),
                        min = -20, max = 40,
                        callback = function(value)
                            plugin:saveSetting("underline_offset", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                            if menu and menu.updateItems then menu:updateItems() end
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
                keep_menu_open = true,
                callback = function(menu)
                    UI.spin({
                        title = _("下划线粗细"),
                        info = _("1~6 像素。调粗会占用更多行间空间，行距会自动跟着加大"),
                        value = plugin:getUnderlineThickness(),
                        min = 1, max = 6,
                        callback = function(value)
                            plugin:saveSetting("underline_thickness", value)
                            plugin:refreshDocumentStyles()
                            plugin:refreshGlosses(true)
                            if menu and menu.updateItems then menu:updateItems() end
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
                            callback = function(menu)
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
                                        -- 同上：菜单不关，但「自定义（N px）」要手动刷新
                                        if menu and menu.updateItems then menu:updateItems() end
                                    end,
                                })
                            end,
                        })
                    end
                    return options
                end)(),
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
            {
                text = _("用本地词典补齐词性（不联网）"),
                callback = function()
                    local filled, total = plugin:backfill_pos()
                    if not total then
                        UI.showInfo(_("离线释义包不可用（data/wordgloss_gloss_en.sqlite3 缺失）"), 3)
                    elseif total == 0 then
                        UI.showInfo(_("缓存里的释义都已经有词性了"), 3)
                    else
                        UI.showInfo(T(_("已补齐 %1 / %2 条词性"), filled, total), 3)
                        plugin:refreshGlosses(true)
                    end
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
            return running and _("翻译生词设置：进行中…") or _("翻译生词设置")
        end,
        sub_item_table_func = function()
            return UI.build_prefetch_menu(plugin)
        end,
    })

    -- 维护
    table.insert(menu, UI.clear_menu(plugin))

    table.insert(menu, UI.about_menu(plugin))

    -- 状态行不再进菜单（信息在「词汇量」「开始转换」里都能看到，多一行反而吵）。
    -- plugin:status_text() 保留，兜底菜单 / 排查时还能用。

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

--[[--
释义来源：本地优先 / 仅本地 / 仅在线。

离线释义包随插件分发（约 4 MB），本地优先时整本书几秒就能翻完且完全不联网，
只有词典里没有的词（生造词、人名地名、新词）才走在线。
]]
function UI.gloss_source_menu(plugin)
    local options = {
        { id = "local_first", text = _("本地优先（本地没有的再联网）") },
        { id = "local_only", text = _("仅本地（完全不联网）") },
        { id = "online_only", text = _("仅在线（不用本地词典）") },
    }
    local items = {}
    for _, option in ipairs(options) do
        table.insert(items, {
            text = option.text,
            radio = true,
            checked_func = function() return plugin:getGlossSource() == option.id end,
            callback = function() plugin:saveSetting("gloss_source", option.id) end,
        })
    end
    return {
        text_func = function()
            return _("释义来源：") .. ({
                local_first = _("本地优先"),
                local_only = _("仅本地"),
                online_only = _("仅在线"),
            })[plugin:getGlossSource()]
        end,
        sub_item_table = items,
    }
end

--[[--
单个引擎的设置。

结构照 ai_translator.koplugin：API密钥 / Base URL / 模型。两处按本插件的场景调整：
  1. DeepL 去掉「翻译自 / 翻译至」——注释只可能是英译中，目标语言写死中文；
  2. 末尾那行置灰的「API密钥：已设置」不要了，状态并进 API密钥 自己的标题。

配置存在本插件设置里（wordgloss_ai_*）；本插件没填时回退读全局同名 key，
所以另一款 AI 翻译插件里填过的密钥可以直接复用，不必再填一遍。
]]
function UI.ai_engine_menu(plugin, engine)
    local AI = require("wordgloss_ai")
    local items = {}
    -- 设置菜单的标题用 menu_name（较短），引擎选择列表里仍用 name（带具体模型名）。
    local label = engine.menu_name or engine.name
    local function key_of(suffix)
        return "ai_" .. engine.id .. "_" .. suffix
    end
    local function value_of(suffix, default)
        local own = plugin:getSetting(key_of(suffix), nil)
        if own ~= nil and own ~= "" then return own end
        -- 只有密钥回退全局：同一个 key 打哪家都一样，可以共用。
        -- 地址和模型名是跟服务商绑定的，搬别人的值只会配错——通用OpenAI 就曾经
        -- 因为读到别的插件存的模型名，显示成了 glm-4-flash。
        if suffix == "api_key" then
            local shared = AI.default_get(engine.id .. "_" .. suffix)
            if shared ~= nil then return shared end
        end
        return default
    end
    local function save(suffix, value)
        -- 只写自己的设置，不去动别的插件的全局配置。
        plugin:saveSetting(key_of(suffix), value)
    end
    local function trimmed(value)
        return tostring(value or ""):match("^%s*(.-)%s*$")
    end

    -- API密钥：标题带"已设置 / 未设置"，不另起一行。
    table.insert(items, {
        text_func = function()
            local key = value_of("api_key", "")
            return key ~= "" and _("API密钥：已设置") or _("API密钥：未设置")
        end,
        keep_menu_open = true,
        callback = function(menu)
            UI.input({
                title = T(_("%1 API密钥"), label),
                description = engine.key_help and T(_("获取地址：%1"), engine.key_help) or nil,
                value = value_of("api_key", ""),
            }, function(value)
                local text = trimmed(value)
                save("api_key", text ~= "" and text or nil)
                if menu and menu.updateItems then menu:updateItems() end
            end)
        end,
    })

    if engine.kind == "openai" then
        table.insert(items, {
            text_func = function()
                return T(_("Base URL：%1"), value_of("base_url", engine.base or ""))
            end,
            keep_menu_open = true,
            callback = function(menu)
                UI.input({
                    title = T(_("%1 Base URL"), label),
                    value = value_of("base_url", engine.base or ""),
                }, function(value)
                    local text = trimmed(value)
                    save("base_url", text ~= "" and text or nil)
                    if menu and menu.updateItems then menu:updateItems() end
                end)
            end,
        })

        -- DeepSeek 有两个模型可选，其余引擎手填模型名。
        if engine.models then
            local model_items = {}
            for _, model in ipairs(engine.models) do
                table.insert(model_items, {
                    text = model.name,
                    radio = true,
                    checked_func = function()
                        return value_of("model", engine.model) == model.id
                    end,
                    callback = function() save("model", model.id) end,
                })
            end
            table.insert(items, {
                text_func = function()
                    return T(_("模型：%1"), value_of("model", engine.model))
                end,
                sub_item_table = model_items,
            })
        else
            table.insert(items, {
                text_func = function()
                    return T(_("模型名：%1"), value_of("model", engine.model))
                end,
                keep_menu_open = true,
                callback = function(menu)
                    UI.input({
                        title = T(_("%1 模型名"), label),
                        value = value_of("model", engine.model),
                    }, function(value)
                        local text = trimmed(value)
                        save("model", text ~= "" and text or nil)
                        if menu and menu.updateItems then menu:updateItems() end
                    end)
                end,
            })
        end
    end

    if engine.kind == "deepl" then
        table.insert(items, {
            text_func = function()
                return value_of("api_type", "free") == "pro"
                    and _("API类型：专业版") or _("API类型：免费")
            end,
            sub_item_table = {
                {
                    text = _("免费API"),
                    radio = true,
                    checked_func = function()
                        return value_of("api_type", "free") ~= "pro"
                    end,
                    callback = function() save("api_type", "free") end,
                },
                {
                    text = _("专业版API"),
                    radio = true,
                    checked_func = function()
                        return value_of("api_type", "free") == "pro"
                    end,
                    callback = function() save("api_type", "pro") end,
                },
            },
        })
    end

    return {
        text = T(_("%1设置"), label),
        sub_item_table = items,
    }
end

--[[--
联网设置：用哪个在线引擎，以及各引擎的密钥 / 地址 / 模型。

上面一行是当前引擎（单选），下面按「免费」「收费」分组放各引擎的设置，
与 ai_translator.koplugin 的排法一致。默认 Edge：免费、免密钥、开箱可用。
]]
function UI.network_menu(plugin)
    local AI = require("wordgloss_ai")
    local function current_engine()
        return AI.by_id(plugin:getSetting("ai_engine", AI.DEFAULT_ENGINE))
            or AI.by_id(AI.DEFAULT_ENGINE)
    end

    local engine_items = {}
    for _, engine in ipairs(AI.ENGINES) do
        table.insert(engine_items, {
            text = engine.name,
            radio = true,
            checked_func = function()
                return current_engine().id == engine.id
            end,
            callback = function()
                plugin:saveSetting("ai_engine", engine.id)
                -- 免密钥的两个引擎（Edge / Google）不用提示填密钥。
                if engine.kind == "openai" or engine.kind == "deepl" then
                    local own = plugin:getSetting("ai_" .. engine.id .. "_api_key", nil)
                    local shared = AI.default_get(engine.id .. "_api_key")
                    if (own == nil or own == "") and shared == nil then
                        UI.showInfo(T(_("已选%1：请在「%2设置」里填 API密钥"),
                            engine.name, engine.menu_name or engine.name), 4)
                    end
                end
            end,
        })
    end

    -- 需要填东西的只有 OpenAI 兼容和 DeepL；Edge 与 Google 免密钥，不给设置入口。
    local function needs_settings(engine)
        return engine.kind == "openai" or engine.kind == "deepl"
    end

    local function group(title, engines)
        local items = {}
        for _, engine in ipairs(engines) do
            if needs_settings(engine) then
                table.insert(items, UI.ai_engine_menu(plugin, engine))
            end
        end
        return { text = title, sub_item_table = items }
    end

    return {
        text = _("联网设置"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("当前：%1"), current_engine().name)
                end,
                sub_item_table = engine_items,
                separator = true,
            },
            group(_("免费"), AI.free_engines()),
            group(_("收费"), AI.paid_engines()),
        },
    }
end

------------------------------------------------------------------------
-- 关于 / 更新
------------------------------------------------------------------------

local UPDATE_STAGES = {
    preparing = _("准备"),
    downloading = _("下载"),
    checksum = _("取校验值"),
    verifying = _("校验"),
    extracting = _("解压"),
    installing = _("安装"),
    done = _("完成"),
}

function UI.format_size(bytes)
    local size = tonumber(bytes) or 0
    if size >= 1024 * 1024 then
        return string.format("%.1f MB", size / (1024 * 1024))
    end
    if size >= 1024 then
        return string.format("%d KB", math.floor(size / 1024 + 0.5))
    end
    return tostring(size) .. " B"
end

-- 更新进度窗：标题显示"阶段 xx%"，只在百分比真的往前走时重绘。
function UI.update_progress()
    local dialog = ProgressbarDialog:new{
        title = _("正在更新…"),
        subtitle = "",
        progress_max = 100,
        dismissable = false,
    }
    dialog:show()
    UI.hide_subtitle(dialog)
    local last = -1
    return {
        dialog = dialog,
        set = function(self, stage, percent)
            percent = math.floor(tonumber(percent) or 0)
            if percent > 100 then percent = 100 end
            if percent <= last then return end
            last = percent
            local label = UPDATE_STAGES[stage] or (stage and tostring(stage) or "")
            pcall(function()
                local frame = dialog[1]
                local group = frame and frame[1]
                if group and group[1] and group[1].setText then
                    group[1]:setText(T(_("%1 %2%"), label, percent))
                end
                dialog:reportProgress(percent)
                UIManager:setDirty(dialog, "ui")
            end)
        end,
        close = function(self) UIManager:close(dialog) end,
    }
end

--[[--
「关于」：版本、作者、检查更新。

更新是联网动作，默认不自动跑；勾上「每天检查一次」后才会在打开书时静默问
一次 GitHub，有新版本也只是提示，装不装由用户点。
]]
function UI.about_menu(plugin)
    local updater = plugin.updater
    local items = {
        {
            text_func = function()
                return _("版本：") .. tostring(plugin.VERSION or _("未知"))
            end,
        },
        {
            text = _("作者：GangYe293"),
        },
        {
            text = _("小红书ID：老王的生活指南"),
        },
        {
            text_func = function()
                if not updater then return _("检查更新") end
                local latest = updater:available_version()
                if latest then
                    return T(_("检查更新（有新版 %1）"), latest)
                end
                return _("检查更新")
            end,
            callback = function() UI.check_update(plugin) end,
        },
        {
            text_func = function()
                if plugin.hasLocalLexicon and not plugin:hasLocalLexicon() then
                    return _("重装离线词典（当前缺失，翻译会失败）")
                end
                return _("重装离线词典")
            end,
            callback = function() UI.reinstall_data(plugin) end,
        },
        {
            text = _("每天自动检查一次"),
            checked_func = function()
                return updater ~= nil and updater:get_auto_check() == true
            end,
            callback = function()
                if not updater then
                    UI.showInfo(_("更新组件未就绪，重启 KOReader 后再试"), 3)
                    return
                end
                local enabled = updater:get_auto_check() ~= true
                updater:set_auto_check(enabled)
                UI.showInfo(enabled
                    and _("已开启：每天第一次打开书时检查一次更新")
                    or _("已关闭：只在手动点「检查更新」时联网"), 3)
            end,
        },
    }
    return {
        text = _("关于"),
        sub_item_table = items,
    }
end

--[[--
重装离线词典（词频包 + 释义包）。

「只更新代码」那个包里不含 data/，而更新是整目录换名激活的——一旦丢过一次，
就再也没有机会自己长回来，症状是翻译整本书必然失败（"词频包未能加载"）。
这是唯一的自助修复入口：不管当前版本号是多少，直接拉最新的完整包覆盖装上，
顺便把代码也更到最新。
]]
function UI.reinstall_data(plugin)
    local updater = plugin.updater
    if not updater then
        UI.showInfo(_("更新组件未就绪，重启 KOReader 后再试"), 3)
        return
    end
    UI.showInfo(_("正在检查可用的安装包…"), 2)
    local release, err
    local ok, wrap_err = Trapper:wrap(function()
        release, err = updater:fetch()
    end)
    if not ok then
        UI.showInfo(_("检查安装包失败：") .. tostring(wrap_err), 4)
        return
    end
    if not release then
        UI.showInfo(_("检查安装包失败：") .. tostring(err or _("网络不可用")), 4)
        return
    end
    if not release.assets or not release.assets.full then
        UI.showInfo(_("这个版本没有可用的完整包"), 4)
        return
    end
    UI.confirm({
        title = _("重装离线词典：下载最新的完整包装上？\n"
                 .. "约 3 MB，需要有网络；已翻译的释义缓存不会丢。"),
        confirm_text = _("重装"),
    }, function() UI.install_update(plugin, release, "full") end)
end

-- 查一次更新。silent = 自动检查（没有更新就不吭声）。
function UI.check_update(plugin, silent)
    local updater = plugin.updater
    if not updater then
        if not silent then UI.showInfo(_("更新组件未就绪，重启 KOReader 后再试"), 3) end
        return
    end
    if not silent then UI.showInfo(_("正在检查更新…"), 2) end

    local release, err
    local ok, wrap_err = Trapper:wrap(function()
        release, err = updater:fetch()
    end)
    if not ok then
        if not silent then
            UI.showInfo(_("检查更新失败：") .. tostring(wrap_err), 3)
        end
        return
    end
    if not release then
        if silent then return end
        UI.showInfo(_("检查更新失败：") .. tostring(err or _("网络不可用")), 3)
        return
    end
    if Updater.compare_versions(release.version, updater.current_version) ~= 1 then
        if not silent then
            UI.showInfo(T(_("已是最新版（%1）"), updater.current_version), 3)
        end
        return
    end
    UI.offer_update(plugin, release)
end

-- 更新说明可以长到 1200 字符（`wordgloss_update.lua` 的上限）。整份塞进
-- ButtonDialog 的标题会把按钮顶出屏幕——1.8.4 的提示就出现过"说明占满整屏、
-- 看不到安装按钮"。所以标题里只放几行预览，完整内容交给可滚动的「查看说明」。
UI.NOTES_PREVIEW_LINES = 4
UI.NOTES_PREVIEW_CHARS = 200

-- 返回 (预览文本, 是否被截断)。行数与字符数任一超限就截断。
function UI.notes_preview(notes)
    if type(notes) ~= "string" or notes == "" then return "", false end
    local text = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "", false end

    local shown, chars, truncated = {}, 0, false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cost = #line + 1
        if #shown >= UI.NOTES_PREVIEW_LINES or chars + cost > UI.NOTES_PREVIEW_CHARS then
            truncated = true
            break
        end
        shown[#shown + 1] = line
        chars = chars + cost
    end
    if #shown == 0 then
        -- 第一行本身就超长（Release 说明里偶尔有一整段）
        return (text:match("^[^\n]*") or ""):sub(1, UI.NOTES_PREVIEW_CHARS) .. "…", true
    end
    return table.concat(shown, "\n"), truncated
end

-- 标题 = "发现新版本 x（当前 y）" + 说明预览。返回 (标题, 是否被截断)。
function UI.update_offer_title(version, current, notes)
    local title = T(_("发现新版本 %1（当前 %2）"), version, current)
    local preview, truncated = UI.notes_preview(notes)
    if preview ~= "" then
        title = title .. "\n\n" .. preview .. (truncated and "\n…" or "")
    end
    return title, truncated
end

-- 可滚动的纯文本查看窗（更新说明用）。TextViewer 是 KOReader 自带组件。
function UI.show_text(title, text)
    local ok, TextViewer = pcall(require, "ui/widget/textviewer")
    if not ok or not TextViewer then
        -- 极老版本没有这个组件时退化成通知，至少别让按钮点了没反应
        UI.showInfo(text, 6)
        return
    end
    UIManager:show(TextViewer:new{
        title = title,
        text = text,
        justified = true,
    })
end

--[[--
问用户装哪个包。

  code —— 只有代码（几十 KB）：本地已经有离线词典时用这个就够了
  full —— 含离线词典（几 MB）：词典缺失、或想顺便换词典时用

本地词典缺失时推荐 full，否则推荐 code。
]]
function UI.offer_update(plugin, release)
    local assets = release.assets or {}
    local kinds = {}
    if assets.code then kinds[#kinds + 1] = "code" end
    if assets.full then kinds[#kinds + 1] = "full" end
    if #kinds == 0 then
        UI.showInfo(_("这个版本没有可下载的安装包"), 3)
        return
    end
    -- 两个离线数据包（词频包 + 释义包）都在，才可以只更新代码；
    -- 少一个都得走完整包，否则装完翻译整本书会因为缺词频包直接失败。
    local has_data = plugin:hasLocalDict() and plugin:hasLocalLexicon()
    local preferred = (has_data and assets.code) and "code"
        or (assets.full and "full" or kinds[1])
    local function label(kind)
        local asset = assets[kind]
        local size = asset and UI.format_size(asset.size) or ""
        if kind == "code" then
            return T(_("只更新代码（%1）"), size)
        end
        return T(_("完整包（含离线词典，%1）"), size)
    end

    local offer
    local buttons = {}
    local row = {}
    for _, kind in ipairs(kinds) do
        if kind == preferred then
            row[#row + 1] = {
                text = label(kind),
                callback = function()
                    UIManager:close(offer)
                    UI.install_update(plugin, release, kind)
                end,
            }
        end
    end
    for _, kind in ipairs(kinds) do
        if kind ~= preferred then
            row[#row + 1] = {
                text = label(kind),
                callback = function()
                    UIManager:close(offer)
                    UI.install_update(plugin, release, kind)
                end,
            }
        end
    end
    buttons[#buttons + 1] = row

    local title, truncated = UI.update_offer_title(release.version,
        plugin.updater and plugin.updater.current_version or _("未知"), release.notes)
    if truncated then
        buttons[#buttons + 1] = {{
            text = _("查看完整更新说明"),
            callback = function()
                UI.show_text(T(_("WordGloss %1 更新说明"), release.version),
                    release.notes or "")
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("以后再说"),
        callback = function() UIManager:close(offer) end,
    }}

    offer = ButtonDialog:new{ title = title, buttons = buttons }
    UIManager:show(offer)
end

-- 下载 → 校验 → 解压 → 备份替换。装完问一句要不要重启。
function UI.install_update(plugin, release, kind)
    local updater = plugin.updater
    if not updater then
        UI.showInfo(_("更新组件未就绪，重启 KOReader 后再试"), 3)
        return
    end
    local progress = UI.update_progress()
    local ok, err
    Trapper:wrap(function()
        ok, err = updater:install(release, {
            kind = kind,
            on_progress = function(stage, percent) progress:set(stage, percent) end,
        })
    end)
    UIManager:nextTick(function()
        progress:close()
        if ok then
            UI.confirm({
                title = _("更新已安装。要现在重启 KOReader 吗？\n"
                       .. "（不重启就还是旧版本，下次启动自动生效）"),
                confirm_text = _("立即重启"),
            }, function()
                if UIManager.restartKOReader then
                    UIManager:restartKOReader()
                else
                    UI.showInfo(_("请手动退出并重启 KOReader"), 4)
                end
            end)
        else
            UI.showInfo(tostring(err or _("更新失败")), 4)
        end
    end)
end

function UI.build_prefetch_menu(plugin)
    local items = {}
    local prefetch = plugin.prefetch
    local function is_running()
        return prefetch ~= nil and prefetch:is_running()
    end

    table.insert(items, UI.network_menu(plugin))
    table.insert(items, UI.gloss_source_menu(plugin))
    table.insert(items, {
        text = _("翻译当前章的生词"),
        callback = function() plugin:start_prefetch_chapter() end,
    })
    table.insert(items, {
        text = _("翻译整本书的生词（后台）"),
        callback = function() plugin:start_prefetch_book() end,
    })
    table.insert(items, {
        text = _("重新翻译整本"),
        callback = function()
            UI.confirm({
                title = _("重新翻译整本书的生词，覆盖已有的释义？\n原书不会被修改。"),
                confirm_text = _("开始"),
            }, function() plugin:start_prefetch_book(true) end)
        end,
    })
    -- 「查看翻译进度」「停止翻译」只在后台真的有任务时才出现：
    -- 平时摆两个点不动的灰项只会把菜单拉长。任务跑起来后重新打开菜单就能看到。
    if is_running() then
        table.insert(items, {
            text = _("查看翻译进度"),
            callback = function() plugin:show_prefetch_progress() end,
        })
        table.insert(items, {
            text = _("停止翻译"),
            callback = function()
                if prefetch then prefetch:request_cancel() end
                UI.showInfo(_("正在停止翻译…已翻译部分会保留"))
            end,
        })
    end
    table.insert(items, {
        text = _("阅读时自动补翻译生词（需要联网）"),
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
