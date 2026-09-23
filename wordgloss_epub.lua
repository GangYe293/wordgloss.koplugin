-- EPUB 结构解析：把每一章拆成"段落"（文本 + 选择器 + 段落里的词）。
--
-- 用途有两个：
--   1. 后台预取需要知道"这一章有哪些词"，不能靠翻页才知道；
--   2. "段落下方生词表"模式需要稳定的 CSS 选择器才能用 ::after 追加注释行，
--      而选择器必须来自书的 XHTML 结构。
--
-- 全程只读：EPUB 解包到临时目录，扫描完就删。选择器寻址的是 CREngine 内部的
-- DocFragment 节点（文档内每一个章节文件都是独立的 DocFragment），所以生成的
-- CSS 能直接命中打开的书，存档本身一个字节都不动。
--
-- 段落扫描逻辑移植自 dualtranslate.koplugin（dualtranslate_epub.lua，GPL-3.0）。

local Tools = require("wordgloss_tools")
local socket_url = require("socket.url")
local logger = require("logger")

local Epub = {}

Epub.PARAGRAPH_TAGS = {
    p = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    li = true, dd = true, dt = true, figcaption = true, blockquote = true,
}

Epub.VOID_TAGS = {
    area = true, base = true, br = true, col = true, embed = true, hr = true,
    img = true, input = true, link = true, meta = true, param = true,
    source = true, track = true, wbr = true,
}

local function attr(tag, name)
    local escaped = name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    return tag:match(escaped .. "%s*=%s*[\"']([^\"']+)[\"']")
end

local function normalize_path(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, "/")
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$") or ""
end

-- XHTML -> 纯文本（去 ruby 注音、把 <br> 当换行、实体解码）
local function html_to_text(html)
    html = html:gsub("<[rR][tT][^>]*>.-</[rR][tT]%s*>", "")
    html = html:gsub("<br%s*/?>", "\n")
    html = html:gsub("<[^>]+>", " ")
    html = html:gsub("&nbsp;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
    return html:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function css_attribute(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

-- 从正文里切词（保留连字符与撇号，规范化交给词频包）
function Epub.tokenize(text)
    local words = {}
    if not text then return words end
    for token in text:gmatch("[%a][%a'%-]*") do
        words[#words + 1] = token
    end
    return words
end

--[[--
解析 container.xml / OPF / spine。

返回 { spine = { "OEBPS/ch1.xhtml", ... }, opf_path = "OEBPS/content.opf" }
]]
function Epub.spine(work_dir)
    local container = Tools.read_file(work_dir .. "/META-INF/container.xml")
    if not container then return nil, "找不到 META-INF/container.xml" end
    local opf_path
    for rootfile_tag in container:gmatch("<[^>]*rootfile[^>]*>") do
        opf_path = attr(rootfile_tag, "full-path")
        if opf_path then break end
    end
    if not opf_path then return nil, "找不到 OPF 路径" end
    opf_path = normalize_path(socket_url.unescape(opf_path))
    local opf = Tools.read_file(work_dir .. "/" .. opf_path)
    if not opf then return nil, "找不到 OPF 文件" end

    local manifest = {}
    for item in opf:gmatch("<[%w_%-]*:?item[^>]*>") do
        local id = attr(item, "id")
        local href = attr(item, "href")
        if id and href then
            manifest[id] = normalize_path(dirname(opf_path) .. "/"
                .. socket_url.unescape(href:gsub("#.*$", "")))
        end
    end
    local spine = {}
    for itemref in opf:gmatch("<[%w_%-]*:?itemref[^>]*>") do
        local idref = attr(itemref, "idref")
        if idref and manifest[idref] then
            spine[#spine + 1] = manifest[idref]
        end
    end
    if #spine == 0 then return nil, "OPF 里没有可读的 spine 项" end
    return { spine = spine, opf_path = opf_path }
end

--[[--
扫描单章：返回段落列表（文本 + 选择器 + 词）以及该章的词表。

  document        —— XHTML 内容
  relative        —— 该章在容器内的相对路径（DocFragment 的 Source）
  fragment_index  —— 该章在 spine 里的序号（1 起）
  options         —— { tags = 覆盖默认可选标签, allow_div_fallback = 默认 true }
]]
function Epub.scan_chapter(document, relative, fragment_index, options)
    options = options or {}
    local result = {
        relative = relative, index = fragment_index,
        paragraphs = {}, words = {}, lowercase = {}, capitalized = {},
    }
    if not document then return result end

    local function walk(tags)
        local paragraphs = {}
        local root = { counts = {}, in_body = false, path = "", xpath = "" }
        local stack = { root }
        local position = 1
        while true do
            local tag_start, tag_end = document:find("<[^>]*>", position)
            if not tag_start then break end
            local raw = document:sub(tag_start, tag_end)
            position = tag_end + 1
            if not raw:match("^<%s*[!?]") then
                local closing = raw:match("^<%s*/") ~= nil
                local name = raw:match("^<%s*/?%s*([%w_:%-]+)")
                if name then
                    name = name:lower():gsub("^.-:", "")
                    if closing then
                        local found
                        for index = #stack, 2, -1 do
                            if stack[index].name == name then found = index; break end
                        end
                        if found then
                            local node = stack[found]
                            if node.target and node.inner_start then
                                local inner = document:sub(node.inner_start, tag_start - 1)
                                local text = html_to_text(inner)
                                if text ~= "" then
                                    paragraphs[#paragraphs + 1] = {
                                        text = text,
                                        selector = 'DocFragment[Source="' .. css_attribute(relative)
                                            .. '"] > body' .. node.path,
                                        xpointer = "/body/DocFragment"
                                            .. (fragment_index > 1
                                                and ("[" .. tostring(fragment_index) .. "]") or "")
                                            .. "/body" .. node.xpath,
                                    }
                                end
                            end
                            for index = #stack, found, -1 do table.remove(stack) end
                        end
                    else
                        local parent = stack[#stack]
                        parent.counts[name] = (parent.counts[name] or 0) + 1
                        local in_body = parent.in_body or name == "body"
                        local path, xpath = parent.path, parent.xpath
                        if name == "body" then
                            path, xpath = "", ""
                        elseif in_body then
                            path = path .. " > " .. name .. ":nth-of-type("
                                .. tostring(parent.counts[name]) .. ")"
                            xpath = xpath .. "/" .. name
                                .. (parent.counts[name] > 1
                                    and ("[" .. tostring(parent.counts[name]) .. "]") or "")
                        end
                        local node = {
                            name = name, counts = {}, in_body = in_body,
                            path = path, xpath = xpath,
                            inner_start = tag_end + 1,
                            target = in_body and tags[name] == true,
                        }
                        local self_closing = raw:match("/%s*>$") ~= nil or Epub.VOID_TAGS[name]
                        if not self_closing then table.insert(stack, node) end
                    end
                end
            end
        end
        return paragraphs
    end

    local paragraphs = walk(options.tags or Epub.PARAGRAPH_TAGS)
    if #paragraphs == 0 and options.allow_div_fallback ~= false then
        -- 有些书没有用 <p>，整章就是一个大 <div>
        paragraphs = walk({ div = true })
    end
    result.paragraphs = paragraphs

    for _, paragraph in ipairs(paragraphs) do
        paragraph.words = Epub.tokenize(paragraph.text)
        for _, token in ipairs(paragraph.words) do
            local key = token:lower()
            result.words[key] = (result.words[key] or 0) + 1
            if token == key then
                result.lowercase[key] = true
            elseif token:sub(1, 1) == token:sub(1, 1):upper() then
                -- 只记"首字母大写"这一个特征，配合 lowercase 集合就能判断专名。
                result.capitalized[key] = true
            end
        end
    end
    return result
end

-- 解包 EPUB 到临时目录，扫描 [first_index, last_index] 范围的章节。
-- on_chapter(analysis) 每章回调一次；返回 true 可提前结束（用户取消）。
function Epub.scan_range(book_path, work_dir, first_index, last_index, on_chapter, should_stop)
    if not Tools.unzip_to(book_path, work_dir) then
        return nil, "无法解包 EPUB（可能受 DRM 保护）"
    end
    local info, err = Epub.spine(work_dir)
    if not info then return nil, err end
    local first = math.max(1, tonumber(first_index) or 1)
    local last = math.min(tonumber(last_index) or #info.spine, #info.spine)
    for index = first, last do
        if should_stop and should_stop() then break end
        local relative = info.spine[index]
        local document = relative and Tools.read_file(work_dir .. "/" .. relative)
        local analysis = Epub.scan_chapter(document, relative, index)
        if on_chapter then on_chapter(analysis) end
    end
    return { chapters = #info.spine, first = first, last = last }
end

return Epub
