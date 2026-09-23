-- 无 shell 依赖的工具函数（移植自 dualtranslate.koplugin 的 dualtranslate_tools.lua，
-- 同为 GPL-3.0 授权）。所有路径都当普通字符串处理，绝不拼进 shell 命令。

local lfs = require("libs/libkoreader-lfs")
local Archiver = require("ffi/archiver")
local util = require("util")
local logger = require("logger")

local Tools = {}

-- 同一本书（路径）永远映射到同一个目录名，且不会与用户文件名冲突。
function Tools.stable_path_hash(value)
    local hash = 7
    value = tostring(value or "")
    for index = 1, #value do
        hash = (hash * 131 + value:byte(index)) % 2147483647
    end
    return string.format("%08x", hash)
end

function Tools.mkdir_p(path)
    if not path or path == "" then return false end
    return util.makePath(path) == true
end

function Tools.rmtree(path)
    if not path or path == "" then return true end
    local mode = lfs.attributes(path, "mode")
    if not mode then return true end
    if mode == "directory" then
        local ok, iterator, state = pcall(lfs.dir, path)
        if ok and iterator then
            for name in iterator, state do
                if name ~= "." and name ~= ".." then
                    Tools.rmtree(path .. "/" .. name)
                end
            end
        end
        pcall(lfs.rmdir, path)
    else
        pcall(lfs.remove, path)
    end
    return lfs.attributes(path, "mode") == nil
end

local function safe_member(entry_path)
    local normalized = tostring(entry_path or ""):gsub("\\", "/")
    if normalized:sub(1, 1) == "/" then return nil end
    local parts = {}
    for part in normalized:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." and part ~= "" then table.insert(parts, part) end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "/")
end

-- 解包 zip/epub 到 dest_dir（拒绝绝对路径与 ".." 逃逸）。
function Tools.unzip_to(archive_path, dest_dir)
    if not Tools.mkdir_p(dest_dir) then return false end
    local arc = Archiver.Reader:new()
    if not arc:open(archive_path) then
        logger.warn("wordgloss: cannot open archive:", archive_path, tostring(arc.err))
        return false
    end
    local ok, err = pcall(function()
        for entry in arc:iterate() do
            local safe = safe_member(entry.path)
            if safe then
                local dest_path = dest_dir .. "/" .. safe
                if entry.path:sub(-1) == "/" then
                    Tools.mkdir_p(dest_path)
                else
                    local parent = dest_path:match("^(.*)/[^/]+$")
                    if parent then Tools.mkdir_p(parent) end
                    if not arc:extractToPath(entry.path, dest_path) then
                        error("extract failed: " .. tostring(entry.path) .. ": " .. tostring(arc.err))
                    end
                end
            end
        end
    end)
    arc:close()
    if not ok then
        logger.warn("wordgloss: archive extract failed:", tostring(err))
        Tools.rmtree(dest_dir)
        return false
    end
    return true
end

-- 个别平台上 io 不可用（与 file_exists 同样的考虑），所以读写一律包 pcall：
-- 失败当作"读不到 / 写不进"，绝不向上抛异常打断调用方。
function Tools.read_file(path)
    local ok, file = pcall(io.open, path, "rb")
    if not ok or not file then return nil end
    local ok_read, data = pcall(function() return file:read("*a") end)
    pcall(function() file:close() end)
    if not ok_read then return nil end
    return data
end

function Tools.write_file(path, data)
    local ok, file = pcall(io.open, path, "wb")
    if not ok or not file then return false end
    local ok_write = pcall(function() file:write(data) end)
    pcall(function() file:close() end)
    return ok_write == true
end

-- 原子替换：先写 .tmp 再 rename，避免断电/强杀留下半个文件。
function Tools.write_file_atomic(path, data)
    local temporary = path .. ".tmp"
    if not Tools.write_file(temporary, data) then return false end
    if not os.rename(temporary, path) then
        os.remove(temporary)
        return false
    end
    return true
end

return Tools
