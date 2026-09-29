-- 注释绘制层（"词上方小字" / "词下方小字"模式）。
--
-- KOReader 的 ReaderView 会把注册过的 view module 在页面之后画到同一个
-- blitbuffer 上（高亮就是这么做的），所以我们能拿到页面的屏幕坐标系，把注释
-- 文字直接画在某个词的上（下）方——不需要往书里写任何东西。
--
-- 注释要占地方：正常排版里行间距是紧的，所以 main.lua 会往 document 的样式表里
-- 注入一条 line-height，让每行上（下）方留出空间（开关注释时会重排一次，因此需要
-- 重新加载一次书）。
--
-- 注释字体：释义是中文、正文是英文，用户的阅读字体很可能没有汉字字形。这里优先
-- 用 KOReader 里单独设置的 "CJK 字体"（cjk_font_face），没有才退回正文字体。

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local Widget = require("ui/widget/widget")
local logger = require("logger")

local Layout = require("wordgloss_layout")

local Overlay = Widget:extend{
    -- { {text=, box={x=,y=,w=,h=}, word=, rank=}, ... }
    glosses = nil,
    font_size = 12,
    font_face = nil,        -- 具体字体名；nil = 自动
    underline = true,
    -- 正文字号（像素）。引擎给的词盒是行盒，字身在行盒里居中，上下各留半个行距；
    -- 需要它才能把注释放进行间的空白里。
    text_height = nil,
    dim = nil,              -- 是否停止刷新
    -- "inline" = 注释在词上方；"below" = 注释画在下划线下方。
    mode = "inline",
    -- 注释离单词的额外距离（像素，正 = 推离单词：上方模式往上、下方模式往下；
    -- 负 = 压近词身）。
    gloss_offset = 0,
    -- 下划线离单词的额外距离（像素，正 = 往下、离词更远）。
    underline_offset = 0,
    -- 下划线样式："solid" 实线 / "dashed" 虚线 / "wavy" 波浪线。
    underline_style = "solid",
    -- 下划线粗细（像素）。
    underline_thickness = 2,
    -- 线的密度："small" 疏 / "medium" 中 / "large" 密 / "custom" 自定义。
    -- 虚线与波浪线共用一份。
    underline_density = "medium",
    -- 自定义密度时的数值（像素）。只有 underline_density == "custom" 时才读。
    underline_density_value = nil,
}

-- 偏移可调范围（像素）。两端都留得比"行间空白"宽，用户想压字也可以。
Overlay.MAX_OFFSET = 40
Overlay.MIN_THICKNESS = 1
Overlay.MAX_THICKNESS = 6
Overlay.DEFAULT_THICKNESS = 2
--[[--
线的密度：一个数字同时管虚线和波浪线（两者共用一份设置），**数值越小越密**。

  虚线   —— 数值 = 一段实线的长度（像素），间隔取它的一半
  波浪线 —— 数值 = 半个波的宽度，一个完整波 = 2 倍

波浪要乘 2 是因为：一个波只有 6~8px 时，正弦被压成锯齿，很难看；拉到 20px
左右才平缓舒展（custombg.koplugin 的波浪就是 20px 一个波 + 振幅 2，很好看）。
]]
Overlay.DENSITY_PRESETS = { small = 11, medium = 6, large = 3 }
Overlay.DENSITY_DEFAULT = 6
Overlay.DENSITY_MIN = 2
Overlay.DENSITY_MAX = 24

-- 取一条偏移设置：只认数字，超出允许范围就夹住。
local function offset_value(raw, limit)
    local value = tonumber(raw) or 0
    local bound = limit or Overlay.MAX_OFFSET
    if value < -bound then value = -bound end
    if value > bound then value = bound end
    return value
end

-- 下划线粗细：1~6 像素。
local function thickness_value(raw)
    local value = math.floor(tonumber(raw) or Overlay.DEFAULT_THICKNESS)
    if value < Overlay.MIN_THICKNESS then value = Overlay.MIN_THICKNESS end
    if value > Overlay.MAX_THICKNESS then value = Overlay.MAX_THICKNESS end
    return value
end

-- 密度档位：只认四档，其它一律当中等。
local function density_value(raw)
    if raw == "small" or raw == "large" or raw == "custom" then return raw end
    return "medium"
end

-- 自定义密度时的数值（像素）：只认数字，超出范围就夹住。
local function density_unit_value(raw)
    local value = math.floor(tonumber(raw) or Overlay.DENSITY_DEFAULT)
    if value < Overlay.DENSITY_MIN then value = Overlay.DENSITY_MIN end
    if value > Overlay.DENSITY_MAX then value = Overlay.DENSITY_MAX end
    return value
end

function Overlay:init()
    self.glosses = self.glosses or {}
    self.placed = nil
    self.gloss_offset = offset_value(self.gloss_offset)
    self.underline_offset = offset_value(self.underline_offset)
    self.underline_thickness = thickness_value(self.underline_thickness)
    self.underline_density = density_value(self.underline_density)
    self.underline_density_value = density_unit_value(self.underline_density_value)
    if self.underline_style ~= "dashed" and self.underline_style ~= "wavy" then
        self.underline_style = "solid"
    end
end

-- 注释画在词的下方（词 -> 下划线 -> 注释）。
function Overlay:isBelow()
    return self.mode == "below"
end

-- 密度的数值（像素）：自定义档直接取值，预设档查表。
function Overlay:densityUnit()
    if self.underline_density == "custom" then
        return density_unit_value(self.underline_density_value)
    end
    return Overlay.DENSITY_PRESETS[self.underline_density] or Overlay.DENSITY_PRESETS.medium
end

-- 虚线：一段实线的长度与间隔（像素）。
function Overlay:dashPattern()
    local dash = self:densityUnit()
    local gap = math.floor(dash * 0.5 + 0.5)
    if gap < 1 then gap = 1 end
    return dash, gap
end

--[[--
给定密度档位与自定义值，算出波浪的波长与振幅（纯函数）。

main 算行距时也要知道波浪占多高，所以抽成模块级函数，避免两处各写一份公式。
]]
function Overlay.wave_metrics(density, custom_value)
    local unit
    if density == "custom" then
        unit = density_unit_value(custom_value)
    else
        unit = Overlay.DENSITY_PRESETS[density] or Overlay.DENSITY_PRESETS.medium
    end
    local wavelength = 2 * unit
    if wavelength < 3 then wavelength = 3 end
    local amplitude = wavelength >= 12 and 2 or 1
    return wavelength, amplitude
end

-- 波浪线：一个完整波占的宽度（像素）。
function Overlay:waveLength()
    local wavelength = Overlay.wave_metrics(self.underline_density, self.underline_density_value)
    return wavelength
end

--[[--
波浪的振幅（半波高）。

不跟着线的粗细走——粗细 6 时振幅也 6 会画成一座山。振幅只跟波长挂钩：
波长够长就给 2，短了压到 1，免得短波被拉成锯齿。
]]
function Overlay:waveAmplitude()
    local _, amplitude = Overlay.wave_metrics(self.underline_density, self.underline_density_value)
    return amplitude
end

--[[--
一条下划线实际占的高度（不含偏移）。

波浪线要把波峰波谷一起算进来，否则行距不够、波峰会被下一行压住。
]]
function Overlay:underlineHeight()
    local thickness = thickness_value(self.underline_thickness)
    if self.underline_style == "wavy" then
        return 2 * self:waveAmplitude() + thickness
    end
    return thickness
end

-- 实际使用的字体名：显式设置 > KOReader 的 CJK 字体 > 正文字体。
function Overlay:resolveFaceName()
    if self.font_face and self.font_face ~= "" and self.font_face ~= "auto" then
        return self.font_face
    end
    local cjk = G_reader_settings and G_reader_settings:readSetting("cjk_font_face")
    if cjk and cjk ~= "" then return cjk end
    return "cfont"
end

-- 字体对象按（字体名 + 字号）缓存：任何一项变了都自动失效。
-- 以前只缓存 _face 本身，改字号/换字体后拿到的还是旧对象，
-- 注释看起来"没生效"，要把书退出去再进来才对。
function Overlay:face()
    local name = self:resolveFaceName()
    local key = tostring(name) .. "|" .. tostring(self.font_size)
    if self._face and self._face_key == key then return self._face end
    local ok, face = pcall(Font.getFace, Font, name, self.font_size)
    if not ok or not face then
        ok, face = pcall(Font.getFace, Font, "cfont", self.font_size)
    end
    if not ok or not face then return nil end
    self._face_key = key
    self._face = face
    return face
end

-- 设置注释列表。text_height 由调用方从 document:getFontSize() 拿。
function Overlay:setGlosses(list, text_height)
    self.glosses = list or {}
    if text_height then self.text_height = text_height end
    self.placed = nil
end

function Overlay:clear()
    self.glosses = {}
    self.placed = nil
end

function Overlay:isEmpty()
    return #self.glosses == 0
end

function Overlay:textBand(box)
    return Layout.textBand(box, self.text_height)
end

function Overlay:paintTo(bb, x, y)
    if self.dim or not self.glosses or #self.glosses == 0 then return end
    local face = self:face()
    if not face then return end

    local max_x = bb:getWidth()
    if not self.placed then
        local measured = {}
        for _, item in ipairs(self.glosses) do
            if item.box and item.text and item.text ~= "" then
                local ok, size = pcall(RenderText.sizeUtf8Text, RenderText, 0, max_x, face,
                    item.text, true, false)
                if ok and size then
                    measured[#measured + 1] = {
                        text = item.text, box = item.box, boxes = item.boxes,
                        rank = item.rank, word = item.word, w = size.x, y_top = size.y_top,
                    }
                end
            end
        end
        self.placed = Layout.plan(measured, max_x, Size.span.horizontal_small)
    end

    local color = self.color or Blitbuffer.COLOR_BLACK
    local underline_color = self.underline_color or Blitbuffer.COLOR_GRAY_4
    for _, entry in ipairs(self.placed) do
        local item = entry.item
        local box = item.box
        local text_top, text_bottom = self:textBand(box)
        local band_bottom = math.floor(text_bottom)
        local ascent = item.y_top or self.font_size
        -- 下划线：贴着文字带的底边，再按偏移平移（正 = 往下、离词更远）。
        local underline_y = band_bottom + self.underline_offset
        local baseline
        if self:isBelow() then
            -- 词 -> 下划线 -> 注释：注释顶边贴着下划线底部再往下一点。
            -- 偏移为正时继续往下推（离词更远），为负时上抬，但不会抬到词身上。
            local base = underline_y + self:underlineHeight() + 1 + ascent
            baseline = math.max(band_bottom + ascent, base + self.gloss_offset)
        else
            -- 基准位置：注释顶边贴着行盒顶（行距不够时）或贴着文字带上沿（行距够时），
            -- 取更靠下的那个，保证注释不会跑到上一行；再整体按偏移平移：
            -- 正 = 往上（离词更远），负 = 往下（压近词身）。
            local base = math.max(box.y + ascent, text_top - 1)
            baseline = math.max(0, base - self.gloss_offset)
        end
        local ok = pcall(RenderText.renderUtf8Text, RenderText, bb,
            x + math.floor(entry.x), y + math.floor(baseline), face, item.text, true, false, color)
        if ok and self.underline then
            -- 跨行的词有多个盒子：每一段都要画，否则第二行的半截词没有下划线。
            -- 每段的 y 各自算（行盒不同），所以下划线跟着各自那行走。
            local parts = item.boxes
            if not parts or #parts == 0 then parts = { box } end
            for index = 1, #parts do
                local part = parts[index]
                pcall(function()
                    local _, part_bottom = self:textBand(part)
                    self:paintUnderline(bb, x + part.x,
                        y + math.floor(part_bottom) + self.underline_offset,
                        part.w, underline_color)
                end)
            end
        end
    end
end

--[[--
画一个词的下划线。

  x, y —— 左上角（y 已含下划线偏移）
  w    —— 宽度（词的宽度）
]]
function Overlay:paintUnderline(bb, x, y, w, color)
    local thickness = thickness_value(self.underline_thickness)
    local left, top = math.floor(x), math.floor(y)
    local width = math.floor(w)
    if width <= 0 then return end

    if self.underline_style == "wavy" then
        self:paintWave(bb, left, top, width, thickness, color)
        return
    end
    if self.underline_style == "dashed" then
        -- 虚线：按密度的段长/间隔逐段画。最后一段不足一段长就截断。
        local dash, gap = self:dashPattern()
        local position = 0
        while position < width do
            local segment = math.min(dash, width - position)
            bb:paintRect(left + position, top, segment, thickness, color)
            position = position + dash + gap
        end
        return
    end
    bb:paintRect(left, top, width, thickness, color)
end

--[[--
波浪线：逐像素列画竖条，列的上下位置按正弦走。

振幅（半波高）跟着粗细走；整条线从 top 开始向下占 2*振幅 + 粗细，
所以不会往上顶到词身。
]]
function Overlay:paintWave(bb, left, top, width, thickness, color)
    local wavelength = self:waveLength()
    local amplitude = self:waveAmplitude()
    local center = top + amplitude
    for position = 0, width - 1 do
        local dy = math.floor(amplitude * math.sin(2 * math.pi * position / wavelength) + 0.5)
        bb:paintRect(left + position, center + dy, 1, thickness, color)
    end
end

return Overlay
