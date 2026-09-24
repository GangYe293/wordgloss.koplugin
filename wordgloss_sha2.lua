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

-- 5.1 里 load 叫 loadstring，取一下兼容。
local chunk = loadstring or load

--[[--
**为什么原生位运算符只能放在字符串里编译，不能直接写进源码**

Kindle 上的 KOReader 跑的是 LuaJIT（Lua 5.1 语法）。Lua 是"先解析整份文件、再执行"，
所以源码里只要出现一个裸的 `&`，LuaJIT 在**解析期**就会报
`'end' expected near '&'`，整个模块加载失败——哪怕那段代码永远轮不到执行。

曾经就是这么写的，结果插件在真机上整个消失。现在改成：把带运算符的源码当字符串
交给 load 编译，编不过就自动退回 bit 库，永远不会因为语法而加载失败。
]]
local function make_native_ops()
    if not chunk then return nil end
    -- 还得整数装得下 32 位无符号：有些实现的整数只到 2^31-1，一运算就变 float。
    if (math.maxinteger or 0) <= 2147483647 then return nil end
    local source = [[
        local MASK = 4294967295
        return {
            band = function(a, b) return a & b end,
            bor = function(a, b) return a | b end,
            bxor = function(a, b) return a ~ b end,
            bnot = function(a) return ~a & MASK end,
            lshift = function(a, n) return (a << n) & MASK end,
            rshift = function(a, n) return a >> n end,
        }
    ]]
    local factory = chunk(source)
    if not factory then return nil end
    local ok, ops = pcall(factory)
    if not ok or type(ops) ~= "table" or not ops.band then return nil end
    return ops
end

-- bit32（Lua 5.2）/ bit（LuaJIT 自带）
local function make_bitlib_ops()
    local ok_bit32, bit32 = pcall(require, "bit32")
    local ok_bit, bit = pcall(require, "bit")
    local lib = ok_bit32 and bit32 or (ok_bit and bit or nil)
    if not lib or not lib.band then return nil end
    return {
        band = lib.band,
        bor = lib.bor,
        bxor = lib.bxor,
        lshift = lib.lshift,
        rshift = lib.rshift,
        -- bit 库的取反返回"有符号"那一套（bnot(0) == -1），统一拉回 0..2^32-1。
        bnot = function(a)
            local value = lib.bnot(a) % POW32
            if value < 0 then value = value + POW32 end
            return value
        end,
    }
end

-- 兜底：逐位模拟。只在没有 bit 库、又不是 5.3 的环境里出现（慢，但结果一样）。
local function make_pure_ops()
    local MASK, MOD = MASK32, POW32
    local function norm(x) return x % MOD end
    local function bit_at(a, b)
        local ab, bb = a % 2, b % 2
        return ab, bb
    end
    local function walk(a, b, keep)
        a, b = norm(a), norm(b)
        -- 写成 0.0 / 1.0：place 会一路乘到 2^31，在整数只有 32 位的 Lua 上
        -- 用整数累加会直接溢出成负数，浮点则能精确表示到 2^53。
        local out, place = 0.0, 1.0
        for _ = 0, 31 do
            local ab, bb = bit_at(a, b)
            if keep(ab, bb) then out = out + place end
            a, b = (a - ab) / 2, (b - bb) / 2
            place = place * 2
        end
        return out
    end
    return {
        band = function(a, b) return walk(a, b, function(x, y) return x == 1 and y == 1 end) end,
        bor = function(a, b) return walk(a, b, function(x, y) return x == 1 or y == 1 end) end,
        bxor = function(a, b) return walk(a, b, function(x, y) return x ~= y end) end,
        bnot = function(a) return MASK - norm(a) end,
        -- 一次移一位、每步都取模：直接乘 2^n 会产生 ~2^64 的中间值，
        -- 双精度浮点存不下（>2^53 就开始丢位），移出来就是错的。
        lshift = function(a, n)
            a = norm(a)
            for _ = 1, n do a = (a * 2) % MOD end
            return a
        end,
        rshift = function(a, n)
            a = norm(a)
            for _ = 1, n do a = math.floor(a / 2) end
            return a
        end,
    }
end

local function pick_ops(forced)
    if forced ~= "bitlib" and forced ~= "pure" then
        local native = make_native_ops()
        if native then return native, "native" end
    end
    if forced ~= "pure" then
        local bitlib = make_bitlib_ops()
        if bitlib then return bitlib, "bitlib" end
    end
    return make_pure_ops(), "pure"
end

-- 主循环里会出现 bxor(a, b, c) 这种三参数写法，而不同后端的多参数支持并不一致
-- （bit32 / LuaJIT 的 bit 支持，5.3 原生写成两个参数就不支持）。统一折叠成两两运算，
-- 免得换个环境就算错。
local function fold(op)
    return function(...)
        local count = select("#", ...)
        if count <= 2 then return op(...) end
        local acc = select(1, ...)
        for index = 2, count do
            acc = op(acc, (select(index, ...)))
        end
        return acc
    end
end

-- 换后端（测试用：真机走的是 bit 分支，必须单独验证一遍）。
local function apply_backend(name)
    local ops, name_got = pick_ops(name)
    band, bor, bxor = fold(ops.band), fold(ops.bor), fold(ops.bxor)
    bnot, lshift, rshift = ops.bnot, ops.lshift, ops.rshift
    Sha2._backend = name_got
    return name_got
end
apply_backend()

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

-- 供测试强制切换后端：_use_backend("bitlib") 走真机那条路，不给参数就回到自动选择。
function Sha2._use_backend(name)
    return apply_backend(name)
end

return Sha2
