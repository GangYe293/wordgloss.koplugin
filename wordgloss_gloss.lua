-- 释义精简：把在线翻译返回的一段文字压成"能塞进两行之间"的短注释。
--
-- Edge 免费接口对单个词通常返回"adj. 无所不在的"这类短文本，但也会返回多义项
-- （"n. 书, 书籍, 帐簿"）或整句。行间注释只有几个字的空间，所以这里做四件事：
--   1. 只取第一行；
--   2. 去掉词性前缀（n./v./adj.…）与括号里的补充说明（[计] 工作簿）；
--   3. 按分隔符切成义项，只保留能放下的前几个；
--   4. 去掉首尾标点。
--
-- 重要：Lua 的模式匹配是"按字节"的，字符集合里只要混进中文（比如 [，；、]）
-- 就会把汉字拆成半个字符，产生乱码。所以这里所有涉及中文的分隔/截断都用
-- 逐字符扫描 + 明文比较实现，绝不用含多字节字符的字符集合。

local Gloss = {}

Gloss.DEFAULT_MAX_CHARS = 12
Gloss.DEFAULT_MAX_ITEMS = 2

-- 义项分隔符（中英文都要认）
local SEPARATORS = { ",", ";", "/", "|", "，", "；", "、", "。" }
-- 需要从行尾剥掉的标点
local TRAILING_PUNCTUATION = {
    ".", ",", ";", ":", "!", "?", " ", "…", "。", "，", "；", "：", "！", "？", "、",
}

-- 词性前缀：把简写归并到统一写法（a. -> adj.，pl. -> n.）。
-- 只用于"清洗时识别并剥掉前缀"——词性不再显示（在线接口并不返回它）。
local POS_ALIASES = {
    n = "n.",      v = "v.",       vt = "vt.",     vi = "vi.",
    adj = "adj.",  adv = "adv.",   prep = "prep.", conj = "conj.",
    pron = "pron.", art = "art.",  num = "num.",   int = "int.",
    aux = "aux.",  abbr = "abbr.", det = "det.",   excl = "int.",
    a = "adj.",    ad = "adv.",    pl = "n.",      pp = "v.",
    adjs = "adj.", advr = "adv.",
}

local BRACKET_PAIRS = { { "[", "]" }, { "(", ")" }, { "【", "】" }, { "（", "）" } }

-- ---------------------------------------------------------------------------
-- UTF-8 基本操作（按首字节判断字符宽度）
-- ---------------------------------------------------------------------------

function Gloss.char_width(byte)
    if not byte then return 1 end
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

function Gloss.char_count(text)
    if not text or text == "" then return 0 end
    local count, index = 0, 1
    while index <= #text do
        index = index + Gloss.char_width(text:byte(index))
        count = count + 1
    end
    return count
end

-- 按字符数截断（不会切断多字节字符）。
function Gloss.sub_chars(text, limit)
    if not text or text == "" or limit <= 0 then return "" end
    local count, index = 0, 1
    while index <= #text do
        if count >= limit then return text:sub(1, index - 1) end
        index = index + Gloss.char_width(text:byte(index))
        count = count + 1
    end
    return text
end

function Gloss.has_cjk(text)
    if not text then return false end
    local index = 1
    while index <= #text do
        local byte = text:byte(index)
        if byte >= 0xE4 and byte <= 0xE9 then return true end
        index = index + Gloss.char_width(byte)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 文本清洗
-- ---------------------------------------------------------------------------

local function starts_at(text, index, needle)
    return text:sub(index, index + #needle - 1) == needle
end

-- 删除成对括号（含内容）。逐字节拷贝，不会破坏多字节字符。
local function remove_brackets(text)
    local out, index = {}, 1
    while index <= #text do
        local matched = false
        for _, pair in ipairs(BRACKET_PAIRS) do
            if starts_at(text, index, pair[1]) then
                local _, stop = text:find(pair[2], index + #pair[1], true)
                index = stop and (stop + 1) or (index + #pair[1])
                matched = true
                break
            end
        end
        if not matched then
            out[#out + 1] = text:sub(index, index)
            index = index + 1
        end
    end
    return table.concat(out)
end

local function collapse_spaces(text)
    text = text:gsub("[\r\n\t]+", " ")
    text = text:gsub(" +", " ")
    text = text:gsub("^ +", "")
    text = text:gsub(" +$", "")
    return text
end

local function strip_trailing_punctuation(text)
    local changed = true
    while changed do
        changed = false
        for _, punctuation in ipairs(TRAILING_PUNCTUATION) do
            local length = #punctuation
            if #text > length and text:sub(-length) == punctuation then
                text = text:sub(1, #text - length)
                changed = true
                break
            end
        end
    end
    return text
end

--[[--
取文本开头的词性标注。

返回 (标签, 余下文本)：标签是统一写法（"adj."），余下文本已去掉该前缀；
开头没有词性标注时返回 (nil, text)。

注意继续用纯 ASCII 模式匹配：Lua 的模式是按字节的，字符集里混入中文会把
汉字切成半个。这里只匹配 [%a]（英文字母），中文译文天然落不到里面。
]]
local function take_pos_prefix(text)
    local head = text:match("^%s*([%a]-%.)")
    if not head then return nil, text end
    local label = POS_ALIASES[head:sub(1, -2):lower()]
    if not label then return nil, text end
    local escaped = head:gsub("%p", "%%%0")
    return label, (text:gsub("^%s*" .. escaped, "", 1))
end

-- 去掉开头的词性标注（n. / adj. / vt. 之类）
local function strip_pos_prefix(text)
    local changed = true
    while changed do
        changed = false
        local label, rest = take_pos_prefix(text)
        if label then text, changed = rest, true end
    end
    return text
end

-- 按分隔符切成义项（逐字符扫描，中文分隔符按明文匹配）。
local function split_items(text)
    local items, current, index = {}, {}, 1
    while index <= #text do
        local matched
        for _, separator in ipairs(SEPARATORS) do
            if starts_at(text, index, separator) then
                matched = separator
                break
            end
        end
        if matched then
            items[#items + 1] = table.concat(current)
            current = {}
            index = index + #matched
        else
            local width = Gloss.char_width(text:byte(index))
            current[#current + 1] = text:sub(index, index + width - 1)
            index = index + width
        end
    end
    items[#items + 1] = table.concat(current)
    return items
end

--[[--
把一条原始译文压成短注释。

  raw       —— 在线接口返回的原文
  max_chars —— 最多保留多少字符（默认 12）
  max_items —— 最多保留几个义项（默认 2）
  source    —— 被翻译的原词（用于识别"原样返回"的情况）

返回短注释字符串，或 nil（没有可用内容）。
]]
function Gloss.clean(raw, max_chars, max_items, source)
    if not raw or raw == "" then return nil end
    max_chars = tonumber(max_chars) or Gloss.DEFAULT_MAX_CHARS
    max_items = tonumber(max_items) or Gloss.DEFAULT_MAX_ITEMS

    local text = tostring(raw)
    text = text:match("^([^\r\n]*)") or text        -- 只取第一行
    text = collapse_spaces(text)
    text = strip_pos_prefix(text)
    text = remove_brackets(text)
    text = collapse_spaces(text)
    if text == "" then return nil end

    local items = split_items(text)
    local kept, used = {}, 0
    for _, item in ipairs(items) do
        local cleaned = collapse_spaces(strip_trailing_punctuation(collapse_spaces(item)))
        if cleaned ~= "" then
            local chars = Gloss.char_count(cleaned)
            if used + chars > max_chars and #kept > 0 then break end
            if used + chars > max_chars then
                cleaned = strip_trailing_punctuation(Gloss.sub_chars(cleaned, max_chars))
            end
            if cleaned ~= "" then
                kept[#kept + 1] = cleaned
                used = used + Gloss.char_count(cleaned) + 1
            end
            if #kept >= max_items then break end
        end
    end
    if #kept == 0 then return nil end

    local result = strip_trailing_punctuation(table.concat(kept, "，"))
    if result == "" then return nil end

    -- 接口把原词原样吐回来（常见于专名、无译文）——当作没有释义
    if source and source ~= "" and not Gloss.has_cjk(result) then
        if result:lower() == source:lower() then return nil end
    end
    return result
end

return Gloss
