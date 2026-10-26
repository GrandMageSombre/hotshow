import 'package:flutter/foundation.dart';

import 'subtitle/subtitle_exception.dart';

/// 把任意异常转成能展示给用户的一句话。
///
/// 只有我们主动抛出的 [SubtitleException] / [FormatException] 带可读文案；
/// 其它异常（磁盘写满、json 解析、RangeError 等）不把英文原文糊到界面上，
/// 但会在 debug 日志里留下完整信息，方便排查。
String subtitleErrorMessage(Object error) {
  if (error is SubtitleException) return error.message;
  if (error is FormatException) return error.message;
  debugPrint('[subtitle] 未预期异常: $error');
  return '字幕处理失败，请稍后重试';
}
