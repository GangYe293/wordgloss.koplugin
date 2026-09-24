--[[--
SHA-256（纯 Lua，只是为了校验更新包）。

KOReader 自带的东西不能指望：它的 ffi/sha2 在不同版本里提供的入口不一致，
而 LuaJIT 的 bit 库、Lua 5.3 的原生位运算符、以及"两者都没有"的环境都要能跑。
所以这里自带一份实现，并按环境挑最快的位运算后端：

  1) Lua 5.3+：原生 & | ~ << >>
  2) bit32 / bit 库（LuaJIT 上是 bit）
  3) 纯算术兜底（逐位，很慢，只在两者都缺失时才会走到）

更新包最大十几 MB，1、2 两条路都能在几秒内算完；第 3 条只在极端环境下触发，
慢归慢，但至少不会让"校验"变成"跳过校验"。
]]

local Sha2 = {}

------------------------------------------------------------------------
-- 位运算后端
------------------------------------------------------------------------

local band, bor, bxor, bnot, lshift, rshift

-- 32 位常数一律用十进制写：有些 Lua 实现会把 0xFFFFFFFF 这样的十六进制字面量
-- 当成有符号 32 位（得到 -1），而十进制字面量总是正确的整数。
local POW32 = 4294967296        -- 2^32
local MASK32 = 4294967295       -- 2^32 - 1

-- 探测方式：把一小段带原生位运算符的代码丢给编译器，能编过就说明是 5.3+。
-- （5.1 里 load 叫 loadstring，取一下兼容。）
local chunk = loadstring or load
local native_ok = false
if chunk then
    native_ok = pcall(chunk("local a = 7 & 3; local b = 1 << 2; return a + b"))
end

local ok_bit32, bit32 = pcall(require, "bit32")
local ok_bit, bit = pcall(require, "bit")
local lib = ok_bit32 and bit32 or (ok_bit and bit or nil)

-- 原生位运算符要能用，还得整数装得下 32 位无符号：有些 Lua 的整数只到
-- 2^31-1，0xFFFFFFFF 一进去就变成 float，位运算直接报错。
local native_usable = native_ok and (math.maxinteger or 0) > 2147483647

if lib and lib.band then
    -- KOReader 上是 LuaJIT 的 bit 库：运算本身是原生的，只是返回值可能是
    -- "有符号"那一套，所以取反之后统一拉回 0..2^32-1。
    band = lib.band
    bor = lib.bor
    bxor = lib.bxor
    lshift = lib.lshift
    rshift = lib.rshift
    bnot = function(a)
        local value = lib.bnot(a) % POW32
        if value < 0 then value = value + POW32 end
        return value
    end
elseif native_usable then
    -- Lua 5.3+：整数运算是 64 位的，取反与左移后必须自己截到 32 位。
    band = function(a, b) return a & b end
    bor = function(a, b) return a | b end
    bxor = function(a, b) return a ~ b end
    bnot = function(a) return ~a & MASK32 end
    lshift = function(a, n) return (a << n) & MASK32 end
    rshift = function(a, n) return (a >> n) & MASK32 end
else
    -- 兜底：逐位模拟。只在没有 bit 库、整数又装不下 32 位无符号时出现。
    -- （离线测试用的 Lua 就是这种，测试桩里另有 bit.lua 走上面那条路。）
    local MASK = MASK32
    local MOD = POW32
    local function norm(x)
        x = x % MOD
        return x
    end
    band = function(a, b)
        a, b = norm(a), norm(b)
        local out, place = 0, 1
        for _ = 0, 31 do
            local ab, bb = a % 2, b % 2
            if ab == 1 and bb == 1 then out = out + place end
            a, b = (a - ab) / 2, (b - bb) / 2
            place = place * 2
        end
        return out
    end
    bor = function(a, b)
        a, b = norm(a), norm(b)
        local out, place = 0, 1
        for _ = 0, 31 do
            local ab, bb = a % 2, b % 2
            if ab == 1 or bb == 1 then out = out + place end
            a, b = (a - ab) / 2, (b - bb) / 2
            place = place * 2
        end
        return out
    end
    bxor = function(a, b)
        a, b = norm(a), norm(b)
        local out, place = 0, 1
        for _ = 0, 31 do
            local ab, bb = a % 2, b % 2
            if ab ~= bb then out = out + place end
            a, b = (a - ab) / 2, (b - bb) / 2
            place = place * 2
        end
        return out
    end
    bnot = function(a) return MASK - norm(a) end
    lshift = function(a, n) return norm(norm(a) * (2 ^ n)) end
    rshift = function(a, n) return math.floor(norm(a) / (2 ^ n)) end
end

-- 32 位加法：所有输入都在 0..2^32-1 内，和可能溢出，取模截回。
local function add32(...)
    local sum = 0
    for index = 1, select("#", ...) do
        sum = sum + (select(index, ...))
    end
    return sum % POW32
end

-- 把可能被解析成负数的常量（0x923f82a4 这类）拉回 0..2^32-1。
local function norm32(value)
    if value < 0 then return value + POW32 end
    return value % POW32
end

local function rotr(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

------------------------------------------------------------------------
-- SHA-256
------------------------------------------------------------------------

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
for index = 1, #K do K[index] = norm32(K[index]) end

-- 32 位无符号转成 8 位十六进制。不用 string.format("%08x")：整数只到 2^31-1
-- 的 Lua 里，超过一半的哈希值都会被它判成"没有整数表示"直接报错。
local HEX = { "0", "1", "2", "3", "4", "5", "6", "7",
              "8", "9", "a", "b", "c", "d", "e", "f" }

local function hex32(value)
    local out = {}
    for shift = 28, 0, -4 do
        local nibble = math.floor(value / (2 ^ shift)) % 16
        out[#out + 1] = HEX[math.floor(nibble) + 1]
        value = value - nibble * (2 ^ shift)
    end
    return table.concat(out)
end

-- 把消息补成 64 字节的整数倍：0x80 + 若干 0x00 + 8 字节大端长度（bit 数）。
-- 分块返回字符串，避免整份 4 MB 数据在内存里复制好几遍。
local function blocks(message, length)
    -- 补位后总长 = length + 1(0x80) + zeros + 8(长度)，且必须是 64 的整数倍。
    local zeros = (64 - ((length + 9) % 64)) % 64
    local padded = length + 9 + zeros
    local tail = {}
    tail[#tail + 1] = string.char(0x80)
    while zeros > 0 do
        local chunk = math.min(zeros, 4096)
        tail[#tail + 1] = string.rep("\0", chunk)
        zeros = zeros - chunk
    end
    local bits = length * 8
    for shift = 56, 0, -8 do
        tail[#tail + 1] = string.char(math.floor(bits / (2 ^ shift)) % 256)
    end
    return message .. table.concat(tail)
end

function Sha2.sha256_hex(message)
    if type(message) ~= "string" then return nil, "sha256: input must be a string" end
    local length = #message
    local data = blocks(message, length)

    local h = {
        norm32(0x6a09e667), norm32(0xbb67ae85), norm32(0x3c6ef372), norm32(0xa54ff53a),
        norm32(0x510e527f), norm32(0x9b05688c), norm32(0x1f83d9ab), norm32(0x5be0cd19),
    }
    local w = {}

    for offset = 1, #data, 64 do
        for index = 0, 15 do
            local base = offset + index * 4
            local b1, b2, b3, b4 = data:byte(base, base + 3)
            w[index] = b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
        end
        for index = 16, 63 do
            local a, b = w[index - 15], w[index - 2]
            local s0 = bxor(rotr(a, 7), rotr(a, 18), rshift(a, 3))
            local s1 = bxor(rotr(b, 17), rotr(b, 19), rshift(b, 10))
            w[index] = add32(w[index - 16], s0, w[index - 7], s1)
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for index = 0, 63 do
            local s1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = add32(hh, s1, ch, K[index + 1], w[index])
            local s0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = add32(s0, maj)
            hh, g, f, e, d, c, b, a = g, f, e, add32(d, temp1), c, b, a, add32(temp1, temp2)
        end
        h[1] = add32(h[1], a)
        h[2] = add32(h[2], b)
        h[3] = add32(h[3], c)
        h[4] = add32(h[4], d)
        h[5] = add32(h[5], e)
        h[6] = add32(h[6], f)
        h[7] = add32(h[7], g)
        h[8] = add32(h[8], hh)
    end

    local out = {}
    for index = 1, 8 do
        out[index] = hex32(h[index] % POW32)
    end
    return table.concat(out)
end

-- 读文件算 SHA-256。文件打不开或读不出内容都返回 nil, err。
function Sha2.sha256_file(path)
    if not path then return nil, "sha256: missing path" end
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local chunks = {}
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    file:close()
    return Sha2.sha256_hex(table.concat(chunks))
end

-- 校验文件与期望值（大小写、首尾空白都不挑）。
function Sha2.verify_file(path, expected)
    if type(expected) ~= "string" then return false end
    local want = expected:match("^%s*([0-9a-fA-F]+)")
    if not want or #want ~= 64 then return false end
    local got = Sha2.sha256_file(path)
    if not got then return false end
    return got:lower() == want:lower(), got
end

Sha2._backend = (lib and lib.band) and "bitlib"
    or (native_usable and "native" or "fallback")

return Sha2
