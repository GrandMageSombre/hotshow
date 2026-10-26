/// 统一的浏览器 User-Agent。
///
/// 豆瓣图床、部分采集站与 OpenSubtitles 都会拒绝非常规 UA
/// （Flutter/Dart 默认的 `Dart/3.x (dart:io)` 会被直接 403），
/// 所有对外抓取都从这里取同一个值。
const String kBrowserUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
