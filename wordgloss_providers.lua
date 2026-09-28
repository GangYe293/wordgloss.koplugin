-- 释义来源：Microsoft Edge 免费网页接口（无需 API key）。
--
-- 与 dualtranslate.koplugin 用的是同一个端点：
--   POST https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to=zh-Hans
--   body: ["word1", "word2", ...]   （单条也用数组 ["word"]，Edge 对该格式最稳定）
--   返回: [{"translations":[{"text":"..."}]}, ...]
--
-- 行间注释是"一次一个词"的场景，所以这里额外做了三件事：按条数/字节数切块、
-- 失败块自动降级为逐条重试、整块失败不会让整个预取任务崩掉。
--
-- 注意：HTTP 层尽可能与 dualtranslate.koplugin 保持一致（包括不包 pcall、
-- 相同的 headers/URL 编码/超时），因为该插件已在同型号 Kindle 上验证可用。

local logger = require("logger")
local _ = require("gettext")

local Providers = {}

Providers.ENDPOINT = "https://edge.microsoft.com/translate/translatetext"
Providers.MAX_ITEMS = 12       -- 单次请求最多几个词
Providers.MAX_BYTES = 4000     -- 单次请求 body 的最大字节数
Providers.TIMEOUT = 15

local function url_encode(value)
    local ok, socket_url = pcall(require, "socket.url")
    if ok and socket_url and socket_url.escape then
        return socket_url.escape(tostring(value or ""))
    end
    return tostring(value or ""):gsub("[^%w%-%._~]", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

function Providers.build_url(source_lang, target_lang)
    local url = Providers.ENDPOINT .. "?isEnterpriseClient=false&to=" .. url_encode(target_lang or "zh-Hans")
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. url_encode(source_lang)
    end
    return url
end

-- 真实 HTTP 调用。测试可以替换成假的实现。
-- 返回值与 dualtranslate 的 httpRequest 一致：成功返回解码后的 data，
-- 失败返回 nil, { code=..., message=..., detail=..., raw=... }。
function Providers.http_post(url, body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local socketutil = require("socketutil")

    local response = {}
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }

    -- 诊断：请求前记录 URL 与 body 前缀，便于真机排查。
    logger.dbg("wordgloss: HTTP POST", url, "body=", body:sub(1, 120))

    socketutil:set_timeout(Providers.TIMEOUT, Providers.TIMEOUT)
    -- luasocket 的 http.request 用表参数时：成功返回 1, code, headers, status；
    -- 失败返回 nil, errmsg。不写 skip(1) 会把第一个返回值（那个 1/nil）当成状态码，
    -- 真正的 HTTP 码和错误消息就全错位了。
    local ok, code, resp_headers, status = http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    socketutil:reset_timeout()

    local raw = table.concat(response)
    logger.dbg("wordgloss: HTTP response", "ok=", tostring(ok), "code=", tostring(code),
        "status=", tostring(status), "raw_len=", tostring(#raw),
        "raw=", raw:sub(1, 160))

    -- 网络层失败（连不上 / DNS / 超时）：ok 为 nil，第二个返回值是错误消息。
    if not ok then
        logger.warn("wordgloss: provider network error:", tostring(code))
        return nil, {
            code = nil,
            message = _("翻译服务连接失败，请检查网络"),
            detail = tostring(code),
            raw = raw:sub(1, 200),
        }
    end

    local ok_decode, data = pcall(json.decode, raw)
    if not ok_decode or not data then
        logger.warn("wordgloss: provider HTTP error:", tostring(code), tostring(status), raw:sub(1, 160))
        return nil, {
            code = code,
            message = (code == 200)
                and _("翻译服务返回的内容无法解析")
                or string.format(_("翻译服务返回 HTTP %s"), tostring(code)),
            detail = tostring(status),
            raw = raw:sub(1, 200),
        }
    end
    if type(data) == "table" and data.error then
        local message = type(data.error) == "table" and data.error.message or data.error
        return nil, { code = code, message = tostring(message or _("翻译服务错误")), raw = raw:sub(1, 200) }
    end
    return data
end

local function extract_translations(data, expected)
    if type(data) ~= "table" then return nil end
    local results = {}
    -- 单条请求时端点可能返回数组，也可能返回对象
    if data[1] == nil and data.translations then
        data = { data }
    end
    for index = 1, expected do
        local item = data[index]
        local text = item and item.translations and item.translations[1]
            and item.translations[1].text
        if not text then return nil end
        results[index] = text
    end
    return results
end

-- 一次请求（不做切块）。texts 为字符串数组。
function Providers.request(texts, source_lang, target_lang)
    if type(texts) ~= "table" or #texts == 0 then return {} end
    local json = require("json")
    local body = json.encode(texts)
    local data, err = Providers.http_post(Providers.build_url(source_lang, target_lang), body)
    if not data then
        return nil, err
    end
    local results = extract_translations(data, #texts)
    if not results then
        return nil, { message = _("翻译服务返回的条目数不完整"), raw = tostring(data) }
    end
    return results
end

-- 把待翻译的词切成若干块（受条数与字节数限制）。
function Providers.plan_chunks(texts, max_items, max_bytes)
    max_items = max_items or Providers.MAX_ITEMS
    max_bytes = max_bytes or Providers.MAX_BYTES
    local chunks, current, bytes = {}, {}, 0
    for _, text in ipairs(texts or {}) do
        local size = #tostring(text) + 4
        if #current > 0 and (#current >= max_items or bytes + size > max_bytes) then
            chunks[#chunks + 1] = current
            current, bytes = {}, 0
        end
        current[#current + 1] = text
        bytes = bytes + size
    end
    if #current > 0 then chunks[#chunks + 1] = current end
    return chunks
end

--[[--
批量翻译（自动切块 + 失败降级）。

  texts         —— 词数组
  source_lang   —— 源语言（"auto" 或 "en"）
  target_lang   —— 目标语言
  on_result     —— 可选，每翻译出一个词就回调 (index, text, translation)
  should_stop   —— 可选，返回 true 时中止（用户取消）

返回 results 数组（与 texts 等长，失败项为 nil），err（首条错误信息，可为 nil）。
]]
function Providers.translate_all(texts, source_lang, target_lang, on_result, should_stop)
    local results = {}
    -- 位置必须自己数：results[#results + 1] = nil 不会让数组变长，翻译失败的词
    -- 会把后面所有词往前挤，释义就串位了（翻错的词顶到别的词头上）。
    local position = 0
    local first_error
    for _, chunk in ipairs(Providers.plan_chunks(texts)) do
        if should_stop and should_stop() then break end
        local chunk_results, err = Providers.request(chunk, source_lang, target_lang)
        if not chunk_results then
            first_error = first_error or err
            -- 整块失败：降级为逐条，一条失败不影响其它词。
            for index, text in ipairs(chunk) do
                if should_stop and should_stop() then break end
                local single, single_err = Providers.request({ text }, source_lang, target_lang)
                if single then
                    chunk_results = chunk_results or {}
                    chunk_results[index] = single[1]
                else
                    first_error = first_error or single_err
                    logger.warn("wordgloss: single translate failed:", text, tostring(single_err and single_err.message))
                end
            end
        end
        for index, text in ipairs(chunk) do
            position = position + 1
            local translated = chunk_results and chunk_results[index]
            results[position] = translated
            if on_result then on_result(position, text, translated) end
        end
    end
    return results, first_error
end

function Providers.available()
    local ok = pcall(require, "socket.http")
    return ok
end

return Providers
