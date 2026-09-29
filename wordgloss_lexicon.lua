-- 生词判定：插件内置的紧凑词频包（data/wordgloss_en.sqlite3）。
--
-- 数据包只回答一个问题："这个词有多常见，它的原形是什么？" 释义完全不存，
-- 由插件在运行时向 Edge 免费接口取。这样数据包只有几百 KB，而不是它所源自的
-- 790 MB 大词典（见 tools/build_en_db.py）。
--
-- 表结构：
--   lex(word TEXT PRIMARY KEY, rank INTEGER, base TEXT)
--     rank 行：word 是原形，rank 为语料库词频排名（1 = the），base 为 NULL
--     form 行：word 是变形，rank 为其原形的排名，base 为原形
--   meta(key, value)

local logger = require("logger")

local Lexicon = {}

-- 语料库排名阈值：排名 <= 阈值 的词视为"已掌握"，不注释。
-- 与 epub-rosetta 的口径一致（初级 1500 / 中级 3000 / 高级 5000）。
Lexicon.LEVELS = {
    { id = "beginner",     name = "初级", rank = 1500 },
    { id = "intermediate", name = "中级", rank = 3000 },
    { id = "advanced",     name = "高级", rank = 5000 },
}

Lexicon.DEFAULT_LEVEL = "beginner"
Lexicon.MAX_CUSTOM_RANK = 20000
-- 不在词频包内的词一律当作最生僻处理（专有名词由另外的规则过滤）。
Lexicon.RANK_UNKNOWN = 1000000

Lexicon.MIN_WORD_LEN = 3
-- 否定缩写拆出来的词干（don't -> don）不是生词。
Lexicon.IGNORE_STEMS = {
    don = true, doesn = true, didn = true, isn = true, aren = true,
    wasn = true, weren = true, hasn = true, haven = true, hadn = true,
    won = true, wouldn = true, couldn = true, shouldn = true, mustn = true,
    needn = true, shan = true, ain = true, let = true, cannot = true,
    y = true, tis = true,
}

function Lexicon.level_rank(level_id)
    for _, level in ipairs(Lexicon.LEVELS) do
        if level.id == level_id then return level.rank end
    end
    return nil
end

function Lexicon.level_name(level_id)
    for _, level in ipairs(Lexicon.LEVELS) do
        if level.id == level_id then return level.name end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 词形规范化
-- ---------------------------------------------------------------------------

-- 把页面上取到的原始词形规整成可以查词频包的键，或返回 nil（不值得注释）。
function Lexicon.normalize(token)
    if not token or token == "" then return nil end
    local word = token:lower()
    -- 去掉首尾非字母（引号、括号、连字符等）
    word = word:gsub("^[^%a]+", ""):gsub("[^%a]+$", "")
    if word == "" then return nil end
    if word:find("'") then
        -- 缩写：只看撇号之前的部分。don't -> don（词干，忽略）；
        -- it's -> it（长度不足，忽略）；Mary's -> mary（专名，后面再滤）。
        word = word:match("^([^']+)") or ""
    end
    if #word < Lexicon.MIN_WORD_LEN then return nil end
    if #word > 32 then return nil end
    if Lexicon.IGNORE_STEMS[word] then return nil end
    if not word:match("^%a+$") then return nil end
    return word
end

-- 连字符复合词：取最后一段判断难度（well-known -> known）。
function Lexicon.normalize_hyphenated(token)
    if token and token:find("%-") then
        return Lexicon.normalize(token:match("([^%-]+)$") or token)
    end
    return Lexicon.normalize(token)
end

-- 粗暴但有效的变形回退：词频包里没有该词形时，尝试常见后缀。
-- 只有回退结果确实在词频包内（即真的常见词）才被接受，避免误判。
local SUFFIX_RULES = {
    { suffix = "ies", base = "y" },
    { suffix = "ier", base = "y" },
    { suffix = "iest", base = "y" },
    { suffix = "es", base = "" },
    { suffix = "ed", base = "" },
    { suffix = "ing", base = "" },
    { suffix = "ly", base = "" },
    { suffix = "est", base = "" },
    { suffix = "er", base = "" },
    { suffix = "s", base = "" },
    { suffix = "d", base = "" },
}

-- ---------------------------------------------------------------------------
-- 实例
-- ---------------------------------------------------------------------------

function Lexicon:new(plugin_path)
    local o = {
        plugin_path = plugin_path,
        db = nil,
        backend_open = nil,   -- 可注入（测试用）
        cache = {},           -- word -> {rank, base} | false
        closed = false,
        -- data/ 不在时每个词都会重试一次 sqlite open 并打一条 warn：
        -- 一页几百个词 = 几百条日志 + 几百次无谓的开库尝试。失败记住就够了。
        open_failed = false,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- 测试可以把打开数据库的方式换成内存实现。
function Lexicon:set_backend(open_fn)
    self.backend_open = open_fn
end

function Lexicon:pack_path()
    return (self.plugin_path or ".") .. "/data/wordgloss_en.sqlite3"
end

function Lexicon:open()
    if self.db then return self.db end
    if self.open_failed then return nil end
    if not self.backend_open then
        local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
        if not ok or not SQ3 then
            logger.warn("wordgloss: sqlite binding unavailable")
            self.open_failed = true
            return nil
        end
        self.backend_open = function(path)
            local open_ok, db = pcall(SQ3.open, path)
            if not open_ok or not db then return nil end
            return db
        end
    end
    self.db = self.backend_open(self:pack_path())
    if not self.db then
        -- 只报一次：在此之前这行日志会按"页面上的每个词"刷屏（10 分钟上千条）。
        self.open_failed = true
        logger.warn("wordgloss: language pack not readable:", self:pack_path())
    end
    return self.db
end

--[[--
忘了上一次的探测结果，下次访问时重新去读文件。

在线更新补回 data/（「重装离线词典」）之后必须调一次，否则这份实例会
一直坚持"词频包不在"，哪怕文件已经被装回来了。
]]
function Lexicon:reset()
    if self.db and self.db.close then pcall(function() self.db:close() end) end
    self.db = nil
    self.open_failed = false
    self.closed = false
    self.cache = {}
end

function Lexicon:close()
    if self.db and self.db.close then pcall(function() self.db:close() end) end
    self.db = nil
    self.closed = true
end

function Lexicon:available()
    return self:open() ~= nil
end

-- 查一行；结果缓存在内存里（一本书会有几千次查询）。
function Lexicon:row(word)
    local cached = self.cache[word]
    if cached ~= nil then
        if cached == false then return nil, nil end
        return cached.rank, cached.base
    end
    local db = self:open()
    if not db then
        -- 数据包不可用（缺失 / 不可读）：记成"这个词查不到"，别每个词都去试一遍。
        self.cache[word] = false
        return nil, nil
    end
    local ok, stmt = pcall(function() return db:prepare("select rank, base from lex where word = ?") end)
    if not ok or not stmt then
        self.cache[word] = false
        return nil, nil
    end
    local row_ok, row = pcall(function()
        stmt:bind(word)
        return stmt:step()
    end)
    pcall(function() stmt:close() end)
    if not row_ok or not row then
        self.cache[word] = false
        return nil, nil
    end
    local rank = tonumber(row[1])
    local base = row[2]
    self.cache[word] = { rank = rank, base = base }
    return rank, base
end

-- 先查原词，再按后缀规则回退（只接受"回退词本身在词频包内"的情况）。
function Lexicon:resolve(word)
    local rank, base = self:row(word)
    if rank then return rank, base end
    if word:find("%-") then
        local tail = word:match("([^%-]+)$")
        if tail and tail ~= word then
            local tail_rank, tail_base = self:row(tail)
            if tail_rank then return tail_rank, tail_base end
        end
    end
    if #word >= 4 then
        for _, rule in ipairs(SUFFIX_RULES) do
            if word:sub(-#rule.suffix) == rule.suffix then
                local stem = word:sub(1, #word - #rule.suffix) .. rule.base
                if #stem >= 3 and stem ~= word then
                    local stem_rank, stem_base = self:row(stem)
                    if stem_rank then
                        return stem_rank, stem_base or stem
                    end
                    -- 辅音重复（stopped -> stop）
                    local last = stem:sub(-1)
                    if last ~= "" and stem:sub(-2, -2) == last then
                        local short = stem:sub(1, -2)
                        if #short >= 3 then
                            local short_rank, short_base = self:row(short)
                            if short_rank then return short_rank, short_base or short end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

--[[--
判断一个词形值不值得注释。

参数：
  surface  —— 页面上取到的原始词形（保留大小写，用于专名判断）
  options  —— {
      rank_limit      = number  排名超过它才算生词（初级 1500 / 中级 3000 / 高级 5000）
      reject_names    = boolean 只以大写形式出现过的词视为人名/地名，不注释
      lower_seen      = table   本书中出现过小写形式的词集合（word -> true）
      names           = table   已知专名集合（word -> true）
  }

返回：nil（不注释）或 { word=, base=, rank=, surface= }
]]
function Lexicon:classify(surface, options)
    if not surface or surface == "" then return nil end
    options = options or {}
    local word = Lexicon.normalize_hyphenated(surface)
    if not word then return nil end

    if options.names and options.names[word] then return nil end
    if options.reject_names ~= false then
        local first = surface:match("^[^%a]*(%a)")
        local starts_upper = first ~= nil and first == first:upper() and first ~= first:lower()
        if starts_upper and not (options.lower_seen and options.lower_seen[word]) then
            return nil
        end
    end

    local rank, base = self:resolve(word)
    local limit = tonumber(options.rank_limit) or Lexicon.level_rank(Lexicon.DEFAULT_LEVEL)
    if rank and rank <= limit then
        return nil  -- 在用户的词汇量之内
    end
    return {
        word = word,
        base = base or word,
        rank = rank or Lexicon.RANK_UNKNOWN,
        surface = surface,
    }
end

function Lexicon:stats()
    local db = self:open()
    if not db then return nil end
    local stats = {}
    local ok, stmt = pcall(function() return db:prepare("select key, value from meta") end)
    if ok and stmt then
        local run_ok = pcall(function()
            stmt:bind()
            while stmt:step() do
                stats[stmt:get_value(0)] = tonumber(stmt:get_value(1)) or stmt:get_value(1)
            end
        end)
        pcall(function() stmt:close() end)
        if not run_ok then return {} end
    end
    return stats
end

return Lexicon
