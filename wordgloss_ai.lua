-- 联网翻译：引擎选择与调用。
--
-- 选 Edge 时沿用 wordgloss_providers（免费、免 key、12 词/块）；
-- 选 AI 引擎时走本模块：智谱 / 硅基流动 / DeepSeek / 通用OpenAI 共用一套
-- OpenAI 兼容的 /chat/completions，DeepL 单独一套 /v2/translate。
--
-- 与参考项目 ai_translator.koplugin 的两点不同（按插件自己的场景调整）：
--   1. DeepL 设置里没有「翻译自 / 翻译至」——注释只可能是英译中，写死 ZH；
--   2. 翻译的是"单词"而不是句子，所以 prompt 要求返回 JSON 数组，
--      由插件按位置对齐回原词，之后仍走 wordgloss_gloss.clean 统一裁剪。
--
-- 配置读取顺序：本插件自己的设置 → 全局同名 key（AI 翻译插件存在那里的可以直接复用）。

local logger = require("logger")
local _ = require("gettext")

local AI = {}

-- 本插件自己的设置前缀；全局回退用的就是不带前缀的同一个名字。
AI.SETTING_PREFIX = "wordgloss_ai_"
AI.DEFAULT_ENGINE = "edge"

--[[--
引擎表。kind: "edge" | "openai" | "deepl"。
free 只用于菜单里的分组（免费 / 收费），不参与调用。
base / model 是该引擎的默认值，用户没填时用它们。
]]
AI.ENGINES = {
    {
        id = "edge", name = "Microsoft Edge 免费翻译", free = true, kind = "edge",
    },
    {
        id = "glm", name = "智谱GLM-4 Flash", free = true, kind = "openai",
        base = "https://open.bigmodel.cn/api/paas/v4", model = "glm-4-flash",
        key_hint = "xxxx.xxxx.xxxx",
        key_help = "https://open.bigmodel.cn/usercenter/apikeys",
    },
    {
        id = "siliconflow", name = "硅基流动", free = true, kind = "openai",
        base = "https://api.siliconflow.cn/v1", model = "Qwen/Qwen2.5-72B-Instruct",
        key_hint = "sk-...",
        key_help = "https://cloud.siliconflow.cn/",
    },
    {
        id = "deepl", name = "DeepL翻译", free = false, kind = "deepl",
        key_hint = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        key_help = "https://www.deepl.com/pro-api",
    },
    {
        id = "deepseek", name = "DeepSeek翻译", free = false, kind = "openai",
        base = "https://api.deepseek.com", model = "deepseek-chat",
        models = {
            { id = "deepseek-chat", name = "DeepSeek Chat（非思考模式）" },
            { id = "deepseek-reasoner", name = "DeepSeek Reasoner（思考模式）" },
        },
        key_hint = "sk-xxxxxxxxxxxxxxxxxxxxxxxx",
        key_help = "https://platform.deepseek.com/",
    },
    {
        id = "openai", name = "通用OpenAI翻译", free = false, kind = "openai",
        base = "https://api.siliconflow.cn/v1", model = "Qwen/Qwen2.5-72B-Instruct",
        key_hint = "YOUR_API_KEY_FROM_CLOUD_SILICONFLOW_CN",
        key_help = "任意 OpenAI 兼容服务",
    },
}

AI.CHAT_PATH = "/chat/completions"
AI.DEEPL_PATH = "/v2/translate"
-- AI 一次能处理的词数比 Edge 大得多（Edge 只有 12），但 Kindle 内存小，
-- 一次别塞太多；回复太长也容易在弱网下超时。
AI.MAX_ITEMS = 20
AI.DEEPL_MAX_ITEMS = 25
-- 大模型首字节慢（尤其 reasoner），15 秒不够用。
AI.TIMEOUT = 45
-- 弱网重试：失败后再试 2 次（共 3 次），退避 2 秒、再 3 秒。
-- 只对网络层失败和 5xx 重试；401/429/456 重试多少次都一样，还会白烧配额。
AI.RETRY_TIMES = 2
AI.RETRY_DELAY = 2
AI.RETRY_FACTOR = 1.5
-- 一次 POST（含重试）的总耗时上限。睡完退避后如果连一次完整请求的超时都留不出来了，
-- 就别再试——整本书几百个词，每个都拖满会把预取拖到几十分钟。
AI.RETRY_BUDGET = 90

function AI.by_id(id)
    for _, engine in ipairs(AI.ENGINES) do
        if engine.id == id then return engine end
    end
    return nil
end

function AI.free_engines()
    local list = {}
    for _, engine in ipairs(AI.ENGINES) do
        if engine.free then list[#list + 1] = engine end
    end
    return list
end

function AI.paid_engines()
    local list = {}
    for _, engine in ipairs(AI.ENGINES) do
        if not engine.free then list[#list + 1] = engine end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- 配置
-- ---------------------------------------------------------------------------

-- 默认读取：本插件设置优先，取不到再读全局（AI 翻译插件填过的 key 可直接复用）。
-- 全局 G_reader_settings 在 KOReader 里是全局变量，子进程 fork 后同样可见。
function AI.default_get(key)
    local store = rawget(_G, "G_reader_settings")
    if not store or not store.readSetting then return nil end
    local value = store:readSetting(AI.SETTING_PREFIX .. key)
    if value == nil then
        value = store:readSetting(key)
    end
    if value == nil or value == "" then return nil end
    return value
end

function AI:new(opts)
    opts = opts or {}
    -- 注入字段叫 getter 而不是 get：与 AI:get() 同名会让 `ai:get(key)` 直接调到
    -- 注入的函数上去（self 变成 key，key 变成 default），读出来的永远是 nil。
    return setmetatable({
        getter = opts.getter or opts.get,
        http_post = opts.http_post,
        providers = opts.providers,
    }, { __index = self })
end

-- Edge 引擎仍然走 wordgloss_providers。可注入，测试里换成假的实现。
-- 方法名不能也叫 providers：那是注入用的字段，同名会把自己盖掉。
function AI:edge_backend()
    return self.providers or require("wordgloss_providers")
end

function AI:get(key, default)
    local value = self.getter and self.getter(key) or AI.default_get(key)
    if value == nil or value == "" then return default end
    return value
end

function AI:engine()
    return self:get("engine", AI.DEFAULT_ENGINE)
end

-- 取出某引擎的完整配置（含默认值）。Edge 返回 kind="edge" 的表。
function AI:config(engine_id)
    local engine = AI.by_id(engine_id or self:engine())
    if not engine then engine = AI.by_id(AI.DEFAULT_ENGINE) end
    if engine.kind == "edge" then
        return { id = engine.id, kind = "edge", name = engine.name }
    end
    return {
        id = engine.id,
        kind = engine.kind,
        name = engine.name,
        api_key = self:get(engine.id .. "_api_key", ""),
        base_url = self:get(engine.id .. "_base_url", engine.base or ""),
        model = self:get(engine.id .. "_model", engine.model or ""),
        api_type = self:get(engine.id .. "_api_type", "free"),  -- 仅 DeepL 用
    }
end

function AI:has_key(engine_id)
    local cfg = self:config(engine_id)
    if not cfg or cfg.kind == "edge" then return true end
    return cfg.api_key ~= nil and cfg.api_key ~= ""
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

--[[--
把 HTTP 状态码翻译成人话。

参考 ai_translator.koplugin 的错误分支：401 密钥错、429 限流、403 无权限、
456 配额用尽（DeepL 特有）。这几条重试多少次结果都一样，给了明确文案用户可以
直接去改设置，比一句「返回 HTTP 429」有用得多。
]]
function AI.http_error_message(code, raw)
    if code == 401 then
        return _("API密钥无效或已过期，请检查密钥")
    end
    if code == 403 then
        return _("没有访问权限，请检查密钥或账户状态")
    end
    if code == 429 then
        return _("请求太频繁，已被限流，请稍后再试")
    end
    if code == 456 then
        return _("配额已用尽")
    end
    if type(code) == "number" and code >= 500 then
        return _("翻译服务暂时不可用，请稍后再试")
    end
    return string.format(_("翻译服务返回 HTTP %s"), tostring(code))
end

-- 是否值得再试一次。网络层失败和 5xx 才重试；其余（含 401/429/456）不重试。
function AI.is_retryable(err)
    if type(err) ~= "table" then return false end
    if err.kind == "network" then return true end
    if err.kind == "http" and type(err.status) == "number" and err.status >= 500 then
        return true
    end
    return false
end

-- 退避用。包一层是为了测试里能换成空实现，不然跑一次测试要真睡好几秒。
function AI.sleep(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then socket.sleep(seconds) end
end

--[[--
带重试的 POST。

对 self.http_post（可注入）做包装：失败时按 2 次上限退避重试，且总耗时不超过
AI.RETRY_BUDGET。返回结构与 http_post 一致。
]]
function AI:post(url, body, headers, opts)
    opts = opts or {}
    local post = self.http_post or AI.http_post
    local timeout = opts.timeout or AI.TIMEOUT
    local budget = opts.budget or AI.RETRY_BUDGET
    local sleep = self.sleep or AI.sleep
    local started = os.time()
    local delay = AI.RETRY_DELAY
    local attempts = 0

    while true do
        local data, err = post(url, body, headers, timeout)
        if data then return data end
        -- 不重试的错误直接返回，别浪费用户时间。
        if attempts >= AI.RETRY_TIMES or not AI.is_retryable(err) then
            return nil, err
        end
        local elapsed = os.time() - started
        -- 睡完这次退避，还得留够一次完整请求的超时，否则重试注定再超时。
        if elapsed + delay + timeout > budget then
            logger.dbg("wordgloss: AI retry skipped, budget exhausted:", tostring(elapsed))
            return nil, err
        end
        attempts = attempts + 1
        logger.warn("wordgloss: AI request failed, retry", attempts, "/", AI.RETRY_TIMES,
            tostring(err and err.message))
        sleep(delay)
        delay = delay * AI.RETRY_FACTOR
    end
end

-- 单次 POST JSON。可注入（测试用）。
-- 成功返回解码后的 data；失败返回 nil, { kind=..., code=..., message=..., raw=... }。
function AI.http_post(url, body, headers, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local socketutil = require("socketutil")

    local response = {}
    local all_headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    for name, value in pairs(headers or {}) do
        all_headers[name] = value
    end

    logger.dbg("wordgloss: AI POST", url, "body=", body:sub(1, 120))

    socketutil:set_timeout(timeout or AI.TIMEOUT, timeout or AI.TIMEOUT)
    -- luasocket 用表参数调用时：成功返回 1, code, headers, status；
    -- 失败返回 nil, errmsg。第一个返回值是"有没有连上"，不是状态码。
    local ok, code, _headers, status = http.request{
        url = url,
        method = "POST",
        headers = all_headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    socketutil:reset_timeout()

    local raw = table.concat(response)
    logger.dbg("wordgloss: AI response", "ok=", tostring(ok), "code=", tostring(code),
        "status=", tostring(status), "raw=", raw:sub(1, 160))

    -- 连不上 / DNS / 超时：ok 为 nil，第二个返回值是 luasocket 的错误消息。
    if not ok then
        logger.warn("wordgloss: AI network error:", tostring(code))
        return nil, {
            kind = "network",
            code = nil,
            message = _("网络连接失败，请检查网络"),
            detail = tostring(code),
            raw = raw:sub(1, 200),
        }
    end

    local decoded, data = pcall(json.decode, raw)
    if not decoded or not data then
        logger.warn("wordgloss: AI HTTP error:", tostring(code), tostring(status), raw:sub(1, 160))
        return nil, {
            kind = "http",
            status = code,
            code = code,
            message = (code == 200)
                and _("翻译服务返回的内容无法解析")
                or AI.http_error_message(code, raw),
            detail = tostring(status),
            raw = raw:sub(1, 200),
        }
    end
    if type(data) == "table" and data.error then
        local error_message = type(data.error) == "table" and (data.error.message or data.error.code)
            or data.error
        return nil, {
            kind = "api",
            code = code,
            message = tostring(error_message or _("翻译服务错误")),
            raw = raw:sub(1, 200),
        }
    end
    return data
end

-- ---------------------------------------------------------------------------
-- OpenAI 兼容（智谱 / 硅基流动 / DeepSeek / 通用OpenAI）
-- ---------------------------------------------------------------------------

--[[--
构造 prompt。

要求模型只回一个 JSON 数组：一项一个词，顺序与输入一致。这样插件可以按位置
把释义对齐回原词，不用去猜模型有没有加序号；空串表示"翻不出来"，由调用方
按失败处理（写空记录，下次不再问同一个词）。
]]
function AI.build_prompt(words, max_chars)
    max_chars = max_chars or 12
    local lines = {}
    for index, word in ipairs(words or {}) do
        lines[index] = tostring(word)
    end
    return string.format([[
Translate each English word below into Simplified Chinese for an inline book glossary.
Reply with a JSON array of strings only: one entry per word, same order, no keys, no markdown, no explanation, no numbering.
Rules for every entry: at most %d characters, the most common meaning only, no part of speech, no example, no trailing punctuation. Use "" when a word has no sensible Chinese meaning.
Words:
%s]], max_chars, table.concat(lines, "\n"))
end

function AI.chat_url(base_url)
    local base = tostring(base_url or "")
    -- 用户可能填了带 /v1 也可能没填，统一下去掉结尾的斜杠再拼。
    base = base:gsub("/+$", "")
    if base == "" then return nil end
    -- 已经以 /chat/completions 结尾就不再拼
    if base:sub(-#AI.CHAT_PATH) == AI.CHAT_PATH then return base end
    return base .. AI.CHAT_PATH
end

-- 从回复里抠出字符串数组。模型常见三种回法：裸数组、包在 ```json 里、
-- 或者干脆把数组当字符串塞进 content。
function AI.parse_translations(data, expected)
    if type(data) ~= "table" then return nil end
    if data.choices and data.choices[1] then
        local message = data.choices[1].message or {}
        local content = message.content or data.choices[1].text
        if type(content) ~= "string" then return nil end
        local cleaned = content:match("```[jJ][sS][oO][nN]%s*(.-)%s*```")
            or content:match("(%[.*%])")
            or content
        local json = require("json")
        local ok, decoded = pcall(json.decode, cleaned)
        if not ok or type(decoded) ~= "table" then return nil end
        data = decoded
    end
    local results = {}
    for index = 1, expected do
        local value = data[index]
        if type(value) == "string" then
            results[index] = value
        elseif type(value) == "table" then
            results[index] = value.text or value.translation or value[1]
        else
            return nil
        end
    end
    return results
end

function AI:translate_chat(words, cfg, opts)
    opts = opts or {}
    local json = require("json")
    local url = AI.chat_url(cfg.base_url)
    if not url then
        return nil, { message = _("Base URL 未填写") }
    end
    if not cfg.api_key or cfg.api_key == "" then
        return nil, { message = _("API密钥未填写") }
    end
    local body = json.encode({
        model = cfg.model,
        messages = {
            {
                role = "user",
                content = AI.build_prompt(words, opts.max_gloss_chars),
            },
        },
        temperature = 0.2,
    })
    local data, err = self:post(url, body, {
        ["Authorization"] = "Bearer " .. tostring(cfg.api_key),
    }, opts)
    if not data then return nil, err end
    local results = AI.parse_translations(data, #words)
    if not results then
        return nil, { message = _("翻译服务返回的内容无法解析"), raw = tostring(data) }
    end
    return results
end

-- ---------------------------------------------------------------------------
-- DeepL
-- ---------------------------------------------------------------------------

function AI.deepl_server(api_type)
    return api_type == "pro" and "https://api.deepl.com" or "https://api-free.deepl.com"
end

function AI:translate_deepl(words, cfg, opts)
    opts = opts or {}
    local json = require("json")
    if not cfg.api_key or cfg.api_key == "" then
        return nil, { message = _("API密钥未填写") }
    end
    -- 注释永远是英译中：源语言交给 DeepL 自动检测，目标写死 ZH（简体中文）。
    local body = json.encode({
        text = words,
        target_lang = "ZH",
    })
    local data, err = self:post(AI.deepl_server(cfg.api_type) .. AI.DEEPL_PATH, body, {
        ["Authorization"] = "DeepL-Auth-Key " .. tostring(cfg.api_key),
    }, opts)
    if not data then return nil, err end
    local list = data.translations
    if type(list) ~= "table" or #list < #words then
        return nil, { message = _("翻译服务返回的条目数不完整"), raw = tostring(data) }
    end
    local results = {}
    for index = 1, #words do
        local item = list[index]
        results[index] = type(item) == "table" and (item.text or item[1]) or item
    end
    return results
end

-- ---------------------------------------------------------------------------
-- 对外入口
-- ---------------------------------------------------------------------------

-- 一次请求（不切块）。按引擎分派。
function AI:request(words, opts)
    opts = opts or {}
    local cfg = opts.config or self:config(opts.engine)
    if cfg.kind == "edge" then
        local Providers = self:edge_backend()
        return Providers.request(words, opts.source_lang, opts.target_lang)
    end
    if cfg.kind == "deepl" then
        return self:translate_deepl(words, cfg, opts)
    end
    return self:translate_chat(words, cfg, opts)
end

-- 切块规则：Edge 沿用 12 词/4000 字节，AI 按引擎自己的上限。
function AI:chunks(words, cfg)
    local Providers = require("wordgloss_providers")
    if cfg.kind == "edge" then
        return Providers.plan_chunks(words)
    end
    local max_items = cfg.kind == "deepl" and AI.DEEPL_MAX_ITEMS or AI.MAX_ITEMS
    return Providers.plan_chunks(words, max_items, 100000)
end

--[[--
批量翻译（自动切块 + 整块失败降级为逐条）。

签名与 Providers.translate_all 一致，返回 results（与 words 等长，失败项 nil）与
首条错误信息。
]]
function AI:translate_all(words, opts)
    opts = opts or {}
    local cfg = opts.config or self:config(opts.engine)
    if cfg.kind == "edge" then
        local Providers = self:edge_backend()
        return Providers.translate_all(words, opts.source_lang, opts.target_lang,
            opts.on_result, opts.should_stop)
    end

    local results = {}
    -- 位置必须自己数：results[#results + 1] = nil 不会让数组变长，
    -- 翻译失败的词会把后面所有词往前挤，释义就串位了。
    local position = 0
    local first_error
    for _, chunk in ipairs(self:chunks(words, cfg)) do
        if opts.should_stop and opts.should_stop() then break end
        local chunk_results, err = self:request(chunk, setmetatable({
            config = cfg,
        }, { __index = opts }))
        if not chunk_results then
            first_error = first_error or err
            -- 整块失败：降级逐条，一个词失败不影响其它词。
            for index, word in ipairs(chunk) do
                if opts.should_stop and opts.should_stop() then break end
                local single, single_err = self:request({ word }, setmetatable({
                    config = cfg,
                }, { __index = opts }))
                if single then
                    chunk_results = chunk_results or {}
                    chunk_results[index] = single[1]
                else
                    first_error = first_error or single_err
                    logger.warn("wordgloss: AI single translate failed:", word,
                        tostring(single_err and single_err.message))
                end
            end
        end
        for index, word in ipairs(chunk) do
            position = position + 1
            local translated = chunk_results and chunk_results[index]
            -- 模型回了空串也算"翻不出来"，按失败处理。
            if translated == "" then translated = nil end
            results[position] = translated
            if opts.on_result then opts.on_result(position, word, translated) end
        end
    end
    return results, first_error
end

return AI
