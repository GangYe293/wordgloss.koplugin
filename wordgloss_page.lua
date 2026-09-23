-- 当前页的单词遍历与注释装配。
--
-- 用 CREngine 的 xpointer 接口逐词走动（不需要解析 EPUB），再用
-- getScreenBoxesFromPositions 把词的位置解析成屏幕坐标——这一步必须在页面渲染
-- 之后做，所以调用方要保证在 PageUpdate/PosUpdate 之后触发。

local logger = require("logger")
local Lexicon = require("wordgloss_lexicon")

local Page = {}

Page.MAX_WORDS = 4000

local function call(object, method, ...)
    if not object or not object[method] then return nil end
    local ok, value = pcall(object[method], object, ...)
    if not ok then return nil end
    return value
end

-- 本页可见页数（双栏模式一次可能有两页）。
local function visible_pages(document)
    local count = call(document, "getVisiblePageCount")
    if type(count) ~= "number" or count < 1 then return 1 end
    return count
end

-- 收集本页所有可见单词：{ {word=原始词形, ws=起 xpointer, we=止 xpointer}, ... }
function Page.collect_words(document, page)
    if not document then return {} end
    page = page or call(document, "getCurrentPage") or 1
    local start_xp = call(document, "getPageXPointer", page)
    if not start_xp then return {} end
    local end_xp = call(document, "getPageXPointer", page + visible_pages(document))
    local words, xp = {}, start_xp
    for _ = 1, Page.MAX_WORDS do
        local ws = call(document, "getNextVisibleWordStart", xp)
        if not ws then break end
        if end_xp and call(document, "compareXPointers", end_xp, ws) == 1 then break end
        local we = call(document, "getNextVisibleWordEnd", ws)
        if not we then break end
        local text = call(document, "getTextFromXPointers", ws, we)
        if text and text ~= "" then
            words[#words + 1] = { word = text, ws = ws, we = we }
        end
        xp = we
    end
    return words
end

-- 把词的 xpointer 区间解析成屏幕坐标；解析不到的（跨页、被裁掉）直接丢掉。
--
-- 一个词可能跨行（断词换行 / 超长词折行），此时 getScreenBoxesFromPositions 会
-- 返回多个盒子，一行一个。全部保留下来：box 取第一个（注释画在它上/下方，跟原来
-- 一样），boxes 用来给每一段都画上——否则第二行的那半截词就没有下划线了。
function Page.resolve_boxes(document, words)
    local resolved = {}
    if not document then return resolved end
    for _, item in ipairs(words or {}) do
        local boxes = call(document, "getScreenBoxesFromPositions", item.ws, item.we, false)
        local parts = {}
        for _, box in ipairs(boxes or {}) do
            -- 宽度或高度非正的盒子画出来是空的，直接跳过。
            if box and box.w and box.w > 0 and box.h and box.h > 0 then
                parts[#parts + 1] = box
            end
        end
        if #parts > 0 then
            resolved[#resolved + 1] = {
                word = item.word, ws = item.ws, we = item.we,
                box = parts[1], boxes = parts,
            }
        end
    end
    return resolved
end

--[[--
装配本页的生词注释。

  config = {
      lexicon      = Lexicon 实例
      cache        = Cache 实例
      rank_limit   = 排名阈值（排名超过它才算生词）
      reject_names = 是否过滤只以大写出现的词
      lower_seen   = 本书小写出现过的词集合（会被就地补充）
      names        = 已知专名集合
      lang         = 目标语言（缓存键的一部分）
      max_gloss_chars = 注释字数上限（用于显示裁剪，超长会截断）
  }

返回 glosses, pending, stats：
  glosses  —— { {text=, box=, word=, rank=}, ... }  可直接交给绘制层
  pending  —— { {word=, base=, rank=}, ... }        有生词但还没有释义，等预取
  stats    —— { words=, candidates=, cached=, missing= }
]]
function Page.build_glosses(document, page, config)
    config = config or {}
    local words = Page.collect_words(document, page)
    local stats = { words = #words, candidates = 0, cached = 0, missing = 0, dropped = 0 }
    local glosses, pending = {}, {}
    local lower_seen = config.lower_seen
    if not words or #words == 0 then return glosses, pending, stats end

    local resolved = Page.resolve_boxes(document, words)
    local candidates = {}
    for _, item in ipairs(resolved) do
        local surface = item.word
        -- 记录小写出现过的事实，供"专名过滤"使用（越读越准）。
        if lower_seen and surface:match("^%a+$") and surface == surface:lower() then
            local key = Lexicon.normalize(surface)
            if key then lower_seen[key] = true end
        end
        local info = config.lexicon and config.lexicon:classify(surface, {
            rank_limit = config.rank_limit,
            reject_names = config.reject_names,
            lower_seen = lower_seen,
            names = config.names,
        }) or nil
        if info then
            candidates[#candidates + 1] = {
                info = info, box = item.box, boxes = item.boxes, surface = surface,
            }
        end
    end
    stats.candidates = #candidates

    -- 生僻优先：超出一页上限时先保最生僻的词。
    table.sort(candidates, function(a, b) return a.info.rank > b.info.rank end)
    if config.max_per_page and config.max_per_page > 0 and #candidates > config.max_per_page then
        stats.dropped = #candidates - config.max_per_page
        for index = #candidates, config.max_per_page + 1, -1 do
            candidates[index] = nil
        end
    end

    for _, candidate in ipairs(candidates) do
        local info = candidate.info
        local key = (info.base and info.base ~= "") and info.base:lower() or info.word
        local gloss
        if config.cache then
            gloss = config.cache:getGloss(key, config.lang)
            if gloss == nil then
                -- 缓存里没有：先试试原词（原形可能不在词频包里）
                gloss = config.cache:getGloss(info.word, config.lang)
                if gloss == nil then missing = true else key = info.word end
            end
        else
            missing = true
        end

        if gloss and gloss ~= "" and gloss ~= false then
            stats.cached = stats.cached + 1
            glosses[#glosses + 1] = {
                text = gloss, word = candidate.surface, rank = info.rank,
                box = candidate.box, boxes = candidate.boxes,
            }
        elseif missing then
            stats.missing = stats.missing + 1
            pending[#pending + 1] = { word = info.word, base = info.base, rank = info.rank, key = key }
        end
    end
    return glosses, pending, stats
end

return Page
