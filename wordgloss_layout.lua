-- 注释排布算法（纯函数，不依赖 KOReader，方便离线单测）。
--
-- 页面上每个生词都有一个屏幕坐标 box，注释画在词的上方、以词为中心。注释通常比
-- 词本身宽，所以同一行的相邻注释会互相压住，需要横向推开；如果一行实在放不下，
-- 就得舍掉一些——舍掉最常见的那几个（rank 最小），因为如果 abate 和 feature
-- 只能解释一个，该解释的是 abate。这正是词汇量级别存在的意义。

local Layout = {}

Layout.DEFAULT_MARGIN = 6

--[[--
为一行里的注释安排横向位置。

  line       —— { {box={x=,w=}, w=注释宽度, rank=生僻度}, ... }（同一行）
  max_x      —— 可用的最右边界（屏幕宽度）
  margin     —— 相邻注释之间的最小间隙

返回 { {item=..., x=...}, ... }，已按 x 排好序。
]]
function Layout.placeLine(line, max_x, margin)
    margin = margin or Layout.DEFAULT_MARGIN
    local remaining = {}
    for index = 1, #line do remaining[index] = line[index] end

    while #remaining > 0 do
        local placed, cursor, fits = {}, 0, true
        for index = 1, #remaining do
            local item = remaining[index]
            local box = item.box
            local text_x = box.x + (box.w - item.w) / 2
            if text_x < cursor then text_x = cursor end
            if text_x < 0 then text_x = 0 end
            if text_x + item.w > max_x then
                fits = false
                break
            end
            placed[index] = { item = item, x = text_x }
            cursor = text_x + item.w + margin
        end
        if fits then return placed end
        -- 放不下：丢掉这一行里最常见的词。rank 越小越常见（1 = the），
        -- 所以丢掉 rank 最小的那个，保留最生僻的。
        local worst, worst_rank = 1, nil
        for index = 1, #remaining do
            local rank = remaining[index].rank
            if rank == nil then rank = 0 end
            if worst_rank == nil or rank < worst_rank then
                worst, worst_rank = index, rank
            end
        end
        table.remove(remaining, worst)
    end
    return {}
end

--[[--
按行分组后逐行排布。

  items —— { {box={x=,y=,w=,h=}, w=注释宽度, rank=...}, ... }
返回 { {item=..., x=...}, ... }
]]
function Layout.plan(items, max_x, margin)
    local lines, order = {}, {}
    for _, item in ipairs(items or {}) do
        local key = item.box and item.box.y
        if key then
            if not lines[key] then
                lines[key] = {}
                order[#order + 1] = key
            end
            lines[key][#lines[key] + 1] = item
        end
    end
    local placed = {}
    for _, key in ipairs(order) do
        local line = lines[key]
        table.sort(line, function(a, b) return a.box.x < b.box.x end)
        local line_placed = Layout.placeLine(line, max_x, margin)
        for _, entry in ipairs(line_placed) do
            placed[#placed + 1] = entry
        end
    end
    return placed
end

--[[--
计算一行文字实际占用的 y 区间（行盒里去掉上下半个行距的部分）。
字号的额外行高会平均分在文字上下，所以盒顶不是文字的顶部。
]]
function Layout.textBand(box, text_height)
    local height = text_height or box.h
    if height > box.h then height = box.h end
    local half_leading = (box.h - height) / 2
    return box.y + half_leading, box.y + box.h - half_leading
end

return Layout
