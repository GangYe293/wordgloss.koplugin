-- 每本书的数据访问层：章节扫描结果、专名表、已覆盖章节。
--
-- 都存进 Cache 的 bookstate 表（JSON 字符串），所以换书、退出进程都不会丢；
-- 也不会在书旁边生成任何文件（连 .sdr 都不碰）。
--
-- 注意：实例字段统一加下划线前缀，避免与同名方法（如 coverage）撞名。

local json = require("json")
local logger = require("logger")

local Book = {}

function Book:new(cache)
    local o = {
        cache = cache,
        _chapters = {},
        _names = nil,
        _lower = nil,
        _coverage = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

local function decode(raw)
    if not raw or raw == "" then return nil end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function encode(value)
    local ok, raw = pcall(json.encode, value)
    if not ok then return nil end
    return raw
end

function Book:_state(book_id, key)
    if not book_id or not self.cache then return nil end
    return decode(self.cache:getBookState(book_id, key))
end

function Book:_save(book_id, key, value)
    if not book_id or not self.cache then return false end
    local raw = encode(value)
    if not raw then return false end
    return self.cache:setBookState(book_id, key, raw)
end

function Book:chapter(book_id, index)
    index = tonumber(index)
    if not book_id or not index then return nil end
    if self._chapters[index] then return self._chapters[index] end
    local data = self:_state(book_id, "chapter:" .. index)
    if data then self._chapters[index] = data end
    return data
end

function Book:save_chapter(book_id, index, analysis)
    index = tonumber(index)
    if not book_id or not index or not analysis then return false end
    analysis.index = index
    self._chapters[index] = analysis
    return self:_save(book_id, "chapter:" .. index, analysis)
end

-- 只以大写形式出现过的词 = 人名/地名等专名。
function Book:names(book_id)
    if not self._names then
        self._names = self:_state(book_id, "names") or {}
    end
    return self._names
end

function Book:save_names(book_id, names)
    self._names = names or {}
    return self:_save(book_id, "names", self._names)
end

-- 本书中"小写形式出现过"的词集合，用来判断大写开头的词到底是专名还是句首生词。
function Book:lower_seen(book_id)
    if not self._lower then
        self._lower = self:_state(book_id, "lower") or {}
    end
    return self._lower
end

function Book:save_lower_seen(book_id, lower)
    self._lower = lower or {}
    return self:_save(book_id, "lower", self._lower)
end

function Book:coverage(book_id)
    if not self._coverage then
        self._coverage = self:_state(book_id, "coverage") or {}
    end
    return self._coverage
end

function Book:mark_covered(book_id, index)
    local coverage = self:coverage(book_id)
    local key = tostring(tonumber(index) or index)
    if coverage[key] then return true end
    coverage[key] = true
    return self:_save(book_id, "coverage", coverage)
end

function Book:covered(book_id, index)
    local coverage = self:coverage(book_id)
    return coverage[tostring(tonumber(index) or index)] == true
end

function Book:reset(book_id)
    self._chapters, self._names, self._lower, self._coverage = {}, nil, nil, nil
    if self.cache and book_id then self.cache:clearBookState(book_id) end
end

return Book
