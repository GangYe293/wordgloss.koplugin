-- 持久化缓存（SQLite / WAL），放在 KOReader 数据目录：
--
--   wordgloss.sqlite3
--     gloss(word, lang, gloss, ts, pos)   —— 单词释义缓存，跨书共享、一次翻译永久复用
--     bookstate(book, key, value)       —— 每本书的状态（章节索引、专名表、进度）
--     meta(key, value)                  —— 杂项
--
-- pos（词性，如 "adj."）是 1.1.6 加的列：老库没有它，由 _ensure_pos_column 补一列。
-- 补列失败（只读介质等）时自动退回不含 pos 的 SQL，绝不让释义缓存整体失效。
--
-- 1.1.9 起不再显示词性（在线接口并不返回它），但这一列与它的兼容逻辑保留：
-- 老库里已经存着 pos 数据，删列反而要动 schema；不写不读，没有副作用。
--
-- 释义按"查询词"缓存：我们优先查原形（took -> take），所以 take 的释义会被
-- took/taken/takes 共用。查询失败也落一条空值记录，避免每次翻页都重试同一个词。

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- LuaJIT(5.1) 里 unpack 是全局函数，Lua 5.2+ 移到了 table 里。
local unpack = table.unpack or unpack

local Cache = {}

local DB_FILENAME = "wordgloss.sqlite3"

function Cache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Cache:getDbPath()
    return DataStorage:getDataDir() .. "/" .. DB_FILENAME
end

-- 每本书的缓存目录（章节索引文件、进度文件都放这里）。
function Cache:getBookDir(book_id)
    return DataStorage:getDataDir() .. "/cache/wordgloss/books/" .. tostring(book_id)
end

function Cache:getBookCacheRoot()
    return DataStorage:getDataDir() .. "/cache/wordgloss"
end

-- 书 ID：路径 + 大小 + 修改时间。同一本书换了位置也不会串数据。
function Cache.book_id(path)
    if not path or path == "" then return nil end
    local size = lfs.attributes(path, "size") or 0
    local mtime = lfs.attributes(path, "modification") or 0
    local Tools = require("wordgloss_tools")
    return Tools.stable_path_hash(tostring(path) .. "|" .. tostring(size) .. "|" .. tostring(mtime))
end

function Cache:open()
    if self.db then return self.db end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then
        logger.warn("wordgloss: sqlite binding unavailable, cache disabled")
        return nil
    end
    local db_path = self:getDbPath()
    local open_ok, db = pcall(SQ3.open, db_path)
    if not open_ok or not db then
        -- 断电/崩溃可能让库文件损坏，重建而不是让插件崩掉。
        logger.warn("wordgloss: cache db corrupt, recreating:", db_path)
        os.remove(db_path)
        os.remove(db_path .. "-wal")
        os.remove(db_path .. "-shm")
        open_ok, db = pcall(SQ3.open, db_path)
        if not open_ok or not db then
            logger.err("wordgloss: cannot recreate cache db:", db)
            return nil
        end
    end
    local setup_ok, setup_err = pcall(function()
        db:exec([[
            -- 主进程与预取子进程可能同时写库：等锁而不是立刻报
            -- "database is locked" 丢数据。
            PRAGMA busy_timeout=8000;
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS gloss (
                word TEXT NOT NULL,
                lang TEXT NOT NULL,
                gloss TEXT NOT NULL,
                ts INTEGER,
                pos TEXT,
                PRIMARY KEY (word, lang)
            );
            CREATE TABLE IF NOT EXISTS bookstate (
                book TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT,
                PRIMARY KEY (book, key)
            );
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        ]])
    end)
    if not setup_ok then
        logger.err("wordgloss: cache db setup failed:", tostring(setup_err))
        return nil
    end
    self.db = db
    self:_ensure_pos_column(db)
    return db
end

-- 1.1.6 之前建的库没有 pos 列。探测不出来时一律当"没有"：
-- 猜"有"却实际没有，会让每条 SELECT 都带着一个不存在的列失败，
-- 结果是整份释义缓存失效——远比少显示词性严重。
function Cache:_has_column(db, table_name, column)
    local ok, stmt = pcall(function()
        return db:prepare("pragma table_info(" .. table_name .. ")")
    end)
    if not ok or not stmt then return false end
    local names = {}
    local read_ok = pcall(function()
        local row = stmt:step()
        while row do
            -- pragma table_info 返回的是 (cid, name, type, ...)：name 是第 2 列。
            -- 以前只认 row[1]（也就是 cid 0/1/2…），永远找不到列名，于是每次都误判
            -- "pos 列不存在" -> 反复 ALTER（列已存在必然报错）-> 词性被永久禁用。
            -- 这里整行扫一遍，别去赌索引位置。
            for _, value in ipairs(row) do
                if value ~= nil then names[tostring(value)] = true end
            end
            if type(row.name) == "string" then names[row.name] = true end
            row = stmt:step()
        end
    end)
    pcall(function() stmt:close() end)
    if not read_ok then return false end
    return names[column] == true
end

function Cache:_ensure_pos_column(db)
    if self._pos_ready ~= nil then return self._pos_ready end
    if self:_has_column(db, "gloss", "pos") then
        self._pos_ready = true
        return true
    end
    -- ALTER 之后必须再查一次 schema：exec 没报错不等于列真的加上了（列已存在时
    -- SQLite 会报 "duplicate column name"，被 pcall 吞掉，效果和"没加"一样）。
    local ok, err = pcall(function() db:exec("ALTER TABLE gloss ADD COLUMN pos TEXT") end)
    if ok and self:_has_column(db, "gloss", "pos") then
        self._pos_ready = true
        return true
    end
    self._pos_ready = false
    logger.warn("wordgloss: cannot add gloss.pos column, part-of-speech tags disabled:",
        tostring(err))
    return false
end

-- 词性列能不能用。状态行用它自曝：开了词性开关却看不到缩写时，一眼能看出是
-- 缓存库补列失败，而不是"翻译没给词性"。
function Cache:posEnabled()
    local db = self:open()
    if not db then return false end
    return self._pos_ready == true
end

function Cache:close()
    if self.db and self.db.close then pcall(function() self.db:close() end) end
    self.db = nil
end

-- 所有读写都包一层：SQLite 出错时退化成"缓存未命中"，绝不向上抛异常。
function Cache:_query(sql, ...)
    local args = { ... }
    local db = self:open()
    if not db then return nil end
    local ok, stmt = pcall(function() return db:prepare(sql) end)
    if not ok or not stmt then return nil end
    local step_ok, row = pcall(function()
        stmt:bind(unpack(args))
        return stmt:step()
    end)
    pcall(function() stmt:close() end)
    if not step_ok or not row then return nil end
    return row
end

function Cache:_execute(sql, ...)
    local args = { ... }
    local db = self:open()
    if not db then return false end
    local ok, stmt = pcall(function() return db:prepare(sql) end)
    if not ok or not stmt then return false end
    local run_ok, err = pcall(function()
        stmt:bind(unpack(args))
        stmt:step()
    end)
    pcall(function() stmt:close() end)
    if not run_ok then
        logger.warn("wordgloss: cache write error:", tostring(err))
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 释义缓存
-- ---------------------------------------------------------------------------

-- 返回：nil = 没查过；false = 查过但没有释义；字符串 = 释义
-- 第二个返回值是词性标签（"adj."），老库/没有词性时为 nil。
-- 只取一个返回值的旧调用不受影响。
function Cache:getGloss(word, lang)
    if not word or word == "" then return nil end
    lang = lang or "zh"
    local sql = self._pos_ready and "select gloss, pos from gloss where word = ? and lang = ?"
        or "select gloss from gloss where word = ? and lang = ?"
    local row = self:_query(sql, word, lang)
    -- 兼容旧版本：早期版本用 "zh-Hans" 作为缓存键，统一成 "zh" 后能继续读到旧数据。
    if not row and lang == "zh" then
        row = self:_query(sql, word, "zh-Hans")
    end
    if not row then return nil end
    local value = row[1]
    if value == nil or value == "" then return false end
    local pos = row[2]
    return value, (pos ~= nil and pos ~= "" and pos or nil)
end

function Cache:putGloss(word, lang, gloss, pos)
    if not word or word == "" then return false end
    if self._pos_ready then
        return self:_execute(
            "insert or replace into gloss(word, lang, gloss, pos, ts) values(?, ?, ?, ?, ?)",
            word, lang or "zh", gloss or "", pos or "", os.time())
    end
    return self:_execute(
        "insert or replace into gloss(word, lang, gloss, ts) values(?, ?, ?, ?)",
        word, lang or "zh", gloss or "", os.time())
end

function Cache:countGlosses(lang)
    local row = self:_query("select count(*) from gloss where lang = ?", lang or "zh")
    return row and tonumber(row[1]) or 0
end

function Cache:clearGlosses()
    return self:_execute("delete from gloss")
end

-- ---------------------------------------------------------------------------
-- 每本书的状态
-- ---------------------------------------------------------------------------

function Cache:getBookState(book, key)
    if not book or not key then return nil end
    local row = self:_query("select value from bookstate where book = ? and key = ?", book, key)
    return row and row[1] or nil
end

function Cache:setBookState(book, key, value)
    if not book or not key then return false end
    return self:_execute("insert or replace into bookstate(book, key, value) values(?, ?, ?)",
        book, key, value)
end

function Cache:delBookStateKey(book, key)
    return self:_execute("delete from bookstate where book = ? and key = ?", book, key)
end

function Cache:clearBookState(book)
    return self:_execute("delete from bookstate where book = ?", book)
end

return Cache
