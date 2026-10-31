/// 播放器手势的纯计算部分：分区判定、音量/亮度增量、进度增量与 HUD 文案。
///
/// 单独抽出来是为了能脱离 media_kit 单测——`PlayerPage` 里 `Player()` 依赖原生
/// 库，在 `flutter test` 的 VM 里起不来，手势逻辑放进去就没法回归。
library;

/// 判定为「一次拖动」的最小位移（逻辑像素）
const double kDragSlop = 8;

/// 横向拖满整屏宽度对应的进度跨度（秒）。
/// 定值而不是按时长比例：两小时的电影按时长比例会让 100dp 就跳几分钟，太灵敏。
const double kSeekSecondsPerScreen = 180;

/// 手势参数。默认值就是真机上手感调好的那套；抽成配置对象是为了
/// 以后能按设备调（平板/电视远距离操作需要更钝一些的灵敏度）。
class GestureConfig {
  /// 判定为「一次拖动」的最小位移
  final double dragSlop;

  /// 横向拖满整屏对应的进度跨度（秒）
  final double seekSecondsPerScreen;

  /// 亮度下限（别让人觉得播放器黑了）
  final double minBrightness;

  /// 底部留给播放控件条的高度，这一带不接管手势
  final double controlsBarHeight;

  const GestureConfig({
    this.dragSlop = kDragSlop,
    this.seekSecondsPerScreen = kSeekSecondsPerScreen,
    this.minBrightness = 0.05,
    this.controlsBarHeight = 64,
  });

  /// 更钝的一套：电视/平板远距离操作时用
  static const GestureConfig comfortable = GestureConfig(
    dragSlop: 12,
    seekSecondsPerScreen: 240,
    controlsBarHeight: 72,
  );
}

/// 拖动落在屏幕哪半边（以**按下时**的横坐标判定，拖过中线也不会突然换功能）
enum GestureSide { left, right }

/// 一次拖动最终归到哪个功能
enum PlayerGestureMode { none, volume, brightness, seek }

GestureSide sideOf(double x, double width) =>
    x < width / 2 ? GestureSide.left : GestureSide.right;

/// 根据累计位移判定手势类型；位移不足 `slop` 时返回 none（当点击处理）。
PlayerGestureMode dragMode({
  required double dx,
  required double dy,
  required double startX,
  required double width,
  double slop = kDragSlop,
}) {
  final ax = dx.abs();
  final ay = dy.abs();
  if (ax < slop && ay < slop) return PlayerGestureMode.none;
  if (ay >= ax) {
    return sideOf(startX, width) == GestureSide.left
        ? PlayerGestureMode.volume
        : PlayerGestureMode.brightness;
  }
  return PlayerGestureMode.seek;
}

/// 竖直拖动改变数值：向上为增，满屏高度对应 [span] 个单位。
///
/// 音量：start 0..100、span 100；亮度：start 0..1、span 1。
double valueFromDrag({
  required double start,
  required double dy,
  required double height,
  required double span,
  required double min,
  required double max,
}) {
  if (height <= 0) return start.clamp(min, max).toDouble();
  final v = start - dy / height * span;
  return v.clamp(min, max).toDouble();
}

/// 横向拖动换算播放位置：会夹在 `[0, duration]` 内。
/// 时长未知（0）时原样返回，避免把播放位置拽回 0。
Duration seekTargetFromDrag({
  required Duration position,
  required Duration duration,
  required double dx,
  required double width,
  double secondsPerScreen = kSeekSecondsPerScreen,
}) {
  if (width <= 0 || duration <= Duration.zero) return position;
  final deltaMs = dx / width * secondsPerScreen * 1000;
  final ms = (position.inMilliseconds + deltaMs)
      .round()
      .clamp(0, duration.inMilliseconds);
  return Duration(milliseconds: ms);
}

/// `01:23` / `1:02:03`
String formatClock(Duration d) {
  final v = d.abs();
  final h = v.inHours;
  final m = (v.inMinutes % 60).toString().padLeft(2, '0');
  final s = (v.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// `+01:30` / `-00:45`
String formatDelta(Duration target, Duration base) {
  final ms = target.inMilliseconds - base.inMilliseconds;
  final sign = ms >= 0 ? '+' : '-';
  return '$sign${formatClock(Duration(milliseconds: ms.abs()))}';
}

/// 音量 HUD 文本：`48%`
String volumeLabel(double volume) => '${volume.round()}%';

/// 亮度 HUD 文本：`72%`
String brightnessLabel(double brightness) =>
    '${(brightness * 100).round()}%';
