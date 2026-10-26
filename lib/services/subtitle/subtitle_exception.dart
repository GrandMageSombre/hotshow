/// 字幕相关的可读异常，UI 直接展示 [message]。
///
/// 这个文件保持 **纯 Dart**（不 import Flutter），
/// 这样 `tool/subtitle_check.dart` 可以直接 `dart run` 验证字幕链路。
class SubtitleException implements Exception {
  final String message;

  /// 该错误可以通过「填 OpenSubtitles API Key」解决（匿名额度用尽 / Key 无效）。
  /// UI 据此决定要不要给「填入 API Key」的快捷入口，而不是靠文案匹配。
  final bool needsApiKey;

  SubtitleException(this.message, {this.needsApiKey = false});

  @override
  String toString() => message;
}

/// 把任意异常转成能展示给用户的一句话。
///
/// 只有我们主动抛出的 [SubtitleException] / [FormatException] 带可读文案，
/// 其它异常（json 解析、RangeError 之类）不要把英文原文糊到界面上。
String subtitleErrorMessage(Object error) {
  if (error is SubtitleException) return error.message;
  if (error is FormatException) return error.message;
  return '字幕处理失败，请稍后重试';
}
