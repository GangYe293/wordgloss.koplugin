-- 离线释义包查询：data/wordgloss_gloss_en.sqlite3（ECDICT 裁剪版，随插件分发）。
--
-- 与 wordgloss_lexicon.lua 的关系：词频包回答"这个词有多常见、原形是谁"，
-- 这个包回答"它是什么意思、什么词性"。两个包都是从同一个 ECDICT 库里裁出来的，
-- 所以键完全一致（小写原形），命中率很高。
--
-- 表结构：
--   gloss(word PK, meaning, pos)   —— 原形词的中文释义 + 词性标签（pos 可为空）
--   form(form PK, base)            —— 变形 -> 原形的重定向（abandons -> abandon）
--   meta(key, value)
--
-- 查询顺序：先按原形查 gloss；查不到再按变形查 form 拿原形、用原形的释义。
-- 也就是说 "abandons" 和 "abandon" 拿到的是同一条释义，跟在线翻译的行为一致
-- （在线也是查原形后再回落）。
--
-- 只在预取（整本翻译）阶段被调用，翻页路径不碰它 —— 结果全部落到释义缓存里。

local logger = require("logger")

-- LuaJIT(5.1) 里 unpack 是全局函数，Lua 5.2+ 移到了 table 里。
local unpack = table.unpack or unpack

local Dict = {}

Dict.FILENAME = "wordgloss_gloss_en.sqlite3"

-- 老版本 SQLite 的 SQLITE_MAX_VARIABLE_NUMBER 可能只到 999（甚至 250）。
-- 一次绑定 400 个变量在任何构建上都安全，剩下的分批再来。
Dict.BATCH = 400

-- 内存缓存上限：一本书几万次查询，缓存住能省掉绝大多数 SQL；
-- 到顶就整体丢掉重来（比做 LRU 简单，最坏情况只是重新查一遍）。
Dict.MAX_CACHE = 40000

function Dict:new(plugin_path)
    local o = {
        plugin_path = plugin_path,
        db = nil,
        backend_open = nil,   -- 可注入（测试用）
        cache = {},           -- word -> {meaning=..., pos=...} | false（查过但没有）
        cache_size = 0,
        unavailable = false,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- 测试可以把打开数据库的方式换成内存实现。
function Dict:set_backend(open_fn)
    self.backend_open = open_fn
    self.db = nil
    self.unavailable = false
    return self
end

function Dict:pack_path()
    return (self.plugin_path or ".") .. "/data/" .. Dict.FILENAME
end

function Dict:open()
    if self.db then return self.db end
    if self.unavailable then return nil end
    if not self.backend_open then
        local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
        if not ok or not SQ3 then
            logger.warn("wordgloss: sqlite binding unavailable")
            self.unavailable = true
            return nil
        end
        self.backend_open = function(path)
            local open_ok, db = pcall(SQ3.open, path)
            if not open_ok or not db then return nil end
            -- 只读库，但主进程和预取子进程可能同时开它：等锁而不是报错。
            pcall(function() db:exec("PRAGMA busy_timeout=5000;") end)
            return db
        end
    end
    self.db = self.backend_open(self:pack_path())
    if not self.db then
        self.unavailable = true
        logger.warn("wordgloss: offline gloss pack not readable:", self:pack_path())
    end
    return self.db
end

function Dict:close()
    if self.db and self.db.close then pcall(function() self.db:close() end) end
    self.db = nil
end

function Dict:available()
    return self:open() ~= nil
end

function Dict:remember(word, meaning, pos)
    local entry = (meaning and meaning ~= "") and { meaning = meaning, pos = pos } or false
    if self.cache[word] == nil then
        self.cache_size = self.cache_size + 1
    end
    self.cache[word] = entry
    if self.cache_size > Dict.MAX_CACHE then
        self.cache = {}
        self.cache_size = 0
    end
end

-- 执行一条带 IN (?,?,...) 的查询，逐行回调。分批执行，返回是否全部成功。
local function query_in(db, sql, words, on_row)
    local ok_all = true
    for start = 1, #words, Dict.BATCH do
        local chunk = {}
        for index = start, math.min(start + Dict.BATCH - 1, #words) do
            chunk[#chunk + 1] = words[index]
        end
        local sql_in = sql .. "(" .. string.rep("?,", #chunk - 1) .. "?)"
        local ok, stmt = pcall(function() return db:prepare(sql_in) end)
        if not ok or not stmt then
            ok_all = false
        else
            local ran, run_err = pcall(function()
                stmt:bind(unpack(chunk))
                while true do
                    local row = stmt:step()
                    if not row then break end
                    on_row(row)
                end
            end)
            pcall(function() stmt:close() end)
            if not ran then
                logger.warn("wordgloss: dict query failed:", tostring(run_err))
                ok_all = false
            end
        end
    end
    return ok_all
end

-- 一批词 -> {word = {meaning, pos}}。查不到的词不在结果里。
function Dict:lookup_all(words)
    local result = {}
    if type(words) ~= "table" or #words == 0 then return result end

    local pending, seen = {}, {}
    for _, raw in ipairs(words) do
        local key = type(raw) == "string" and raw:lower() or nil
        if key and key ~= "" and not seen[key] then
            seen[key] = true
            local hit = self.cache[key]
            if hit ~= nil then
                if hit ~= false then result[key] = hit end
            else
                pending[#pending + 1] = key
            end
        end
    end
    if #pending == 0 then return result end

    local db = self:open()
    if not db then return result end

    -- 第一步：原形直接命中
    local found = {}
    local gloss_ok = query_in(db, "select word, meaning, pos from gloss where word in ",
        pending, function(row)
            local word = tostring(row[1])
            local meaning = row[2]
            if meaning ~= nil and meaning ~= "" then
                found[word] = true
                self:remember(word, meaning, row[3])
                result[word] = self.cache[word]
            end
        end)

    -- 第二步：变形 -> 原形 -> 释义
    local missed = {}
    for _, word in ipairs(pending) do
        if not found[word] then missed[#missed + 1] = word end
    end
    local forms_ok = true
    if #missed > 0 then
        local redirects = {}
        forms_ok = query_in(db, "select form, base from form where form in ",
            missed, function(row)
                redirects[tostring(row[1])] = tostring(row[2])
            end)
        local bases, base_seen = {}, {}
        for _, base in pairs(redirects) do
            if not base_seen[base] then
                base_seen[base] = true
                bases[#bases + 1] = base
            end
        end
        if #bases > 0 then
            local base_meaning = {}
            forms_ok = query_in(db, "select word, meaning, pos from gloss where word in ",
                bases, function(row)
                    base_meaning[tostring(row[1])] = { meaning = row[2], pos = row[3] }
                end) and forms_ok
            for form, base in pairs(redirects) do
                local entry = base_meaning[base]
                if entry and entry.meaning and entry.meaning ~= "" then
                    found[form] = true
                    self:remember(form, entry.meaning, entry.pos)
                    result[form] = self.cache[form]
                end
            end
        end
    end

    -- 只有两步查询都成功，"没查到"才是可信结论，才值得缓存下来避免反复查。
    -- 查询本身出错时留空缓存，下次还能再试一次。
    if gloss_ok and forms_ok then
        for _, word in ipairs(pending) do
            if not found[word] then self:remember(word, nil, nil) end
        end
    end

    return result
end

-- 单个词：返回 (meaning, pos)，没有则 nil。
function Dict:lookup(word)
    if type(word) ~= "string" or word == "" then return nil, nil end
    local found = self:lookup_all({ word })
    local entry = found[word:lower()]
    if not entry then return nil, nil end
    return entry.meaning, entry.pos
end

-- 包的自述信息（词条数等），状态菜单用；读不到返回空表。
function Dict:info()
    local info = {}
    local db = self:open()
    if not db then return info end
    local ok, stmt = pcall(function() return db:prepare("select key, value from meta") end)
    if not ok or not stmt then return info end
    pcall(function()
        while true do
            local row = stmt:step()
            if not row then break end
            info[tostring(row[1])] = row[2]
        end
    end)
    pcall(function() stmt:close() end)
    return info
end

return Dict
