-- KOReader 插件元信息
-- 注意：这个文件由 pluginloader 用 dofile 加载，`_` 不是全局变量，
-- 必须自己 require gettext，否则整份元信息都会加载失败。
local _ = require("gettext")

return {
    name = "wordgloss",
    version = "1.3.0",
    fullname = _("生词注释（WordGloss）"),
    description = _([[把生词的中文释义注在词的上方或下方（类似 Kindle Word Wise）。
词汇量分初级/中级/高级，注释位置、下划线样式（实线/虚线/波浪线）与粗细、密度可调；
释义来自 Microsoft Edge 免费接口并缓存复用；原书文件不会被修改。

插件不会在打开书时自动运行：需要在菜单「工具 → 生词注释」
里手动点「开始转换」，并自己选择词汇量与翻译范围。]]),
}
