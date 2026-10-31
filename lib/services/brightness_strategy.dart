import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 亮度调节策略：把「怎么改亮度」和「播放页」解耦。
///
/// 现在只有「画面遮罩」一种实现（三端一致、零依赖）。以后要接
/// `screen_brightness` 之类的插件做**系统亮度**，只要再写一个实现、在播放页换一行，
/// 其余逻辑（手势、HUD、边界值）都不用动。
abstract class BrightnessStrategy {
  /// 当前亮度，0..1（1 = 最亮）
  double get value;

  /// 供手势层读取当前值 / 供遮罩层订阅
  ValueListenable<double> get listenable;

  /// 设置亮度，实现内部负责夹到 [minValue, 1]
  void set(double value);

  /// 盖在视频之上、播放控件之下的那一层（系统亮度实现可以返回空）
  Widget buildOverlay(BuildContext context);

  void dispose();
}

/// 画面遮罩实现：叠一层半透明黑，只暗画面不暗控件。
///
/// 亮度 1.0 → 不遮；降到 [minValue] 时最多遮 [maxDim]（留一点画面，
/// 免得用户以为播放器黑了）。
class OverlayBrightnessStrategy implements BrightnessStrategy {
  OverlayBrightnessStrategy({
    double initial = 1,
    this.minValue = 0.05,
    this.maxDim = 0.85,
  })  : _value = initial.clamp(minValue, 1).toDouble(),
        _notifier = ValueNotifier<double>(initial.clamp(minValue, 1).toDouble());

  final double minValue;

  /// 最暗时的遮罩不透明度（0.85 → 画面还剩约 15%）
  final double maxDim;

  final ValueNotifier<double> _notifier;
  double _value;

  @override
  double get value => _value;

  @override
  ValueListenable<double> get listenable => _notifier;

  /// 亮度换算成遮罩不透明度（便于单测与外部复用）
  double get dim => (1 - _value) * maxDim;

  @override
  void set(double value) {
    final v = value.clamp(minValue, 1).toDouble();
    if (v == _value) return;
    _value = v;
    _notifier.value = v;
  }

  @override
  Widget buildOverlay(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _notifier,
      builder: (_, brightness, _) {
        final alpha = (1 - brightness) * maxDim;
        if (alpha <= 0.001) return const SizedBox.shrink();
        // 遮罩是整块视频面积的 alpha 混合，单独包一层避免连带重绘视频
        return RepaintBoundary(
          child: IgnorePointer(
            child: ColoredBox(color: Colors.black.withValues(alpha: alpha)),
          ),
        );
      },
    );
  }

  @override
  void dispose() => _notifier.dispose();
}
