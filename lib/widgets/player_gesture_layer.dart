import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/player_gestures.dart';

/// 播放器手势层：左半边上下拖 = 音量，右半边上下拖 = 亮度，左右拖 = 进度。
///
/// 两个刻意的设计：
/// 1. 用 [Listener]（裸指针事件）而不是 `GestureDetector`——media_kit 的控件自身
///    挂着一整套 tap / doubleTap / longPress / 拖拽识别器，再加一个 GestureDetector
///    会进同一个手势竞技场抢胜负，容易把「点一下显隐控件」或进度条拖动抢走；
///    Listener 只旁观指针、不参与竞技场，两边互不干扰。
/// 2. 音量/亮度用 [ValueListenable] 传入，拖动时**不 setState 整页**：否则 60fps
///    的指针事件会把 Video 整棵子树重建几十次，真机上会掉帧。
///
/// 亮度是「画面遮罩」而不是系统亮度：桌面/安卓/iOS 表现一致，也不用加插件。
class PlayerGestureLayer extends StatefulWidget {
  /// 当前音量（0..100，media_kit 的取值域）
  final ValueListenable<double> volume;

  /// 当前亮度（0.05..1.0，1.0 = 不遮罩）
  final ValueListenable<double> brightness;

  /// 播放位置/时长用回调现取：播放进度每秒都在变，放进 widget 字段必然过期
  final Duration Function() readPosition;
  final Duration Function() readDuration;

  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<Duration> onSeek;

  /// 关掉后忽略手势（例如正在打开新片源时避免误触）
  final bool enabled;

  /// 底部留给播放控件条的高度：进度条就在这一带，让它自己处理拖动，
  /// 否则「拖动进度条」会同时触发本层的手势，松手时位置跳两次
  final double controlsBarHeight;

  const PlayerGestureLayer({
    super.key,
    required this.volume,
    required this.brightness,
    required this.readPosition,
    required this.readDuration,
    required this.onVolumeChanged,
    required this.onBrightnessChanged,
    required this.onSeek,
    this.enabled = true,
    this.controlsBarHeight = 64,
  });

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

class _PlayerGestureLayerState extends State<PlayerGestureLayer> {
  /// 亮度下限：留一点画面，别让人以为播放器黑了
  static const double _minBrightness = 0.05;

  PlayerGestureMode _mode = PlayerGestureMode.none;
  int? _pointer;
  double _startX = 0;
  double _startValue = 0;
  double _accumDx = 0;
  double _accumDy = 0;

  bool _hudVisible = false;
  IconData _hudIcon = Icons.volume_up_rounded;
  String _hudTitle = '';
  String _hudValue = '';
  double? _hudRatio;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onDown(PointerDownEvent e, Size size) {
    if (!widget.enabled) return;
    if (_pointer != null) return; // 已在拖动，忽略第二根手指
    // 底部控件条（进度条）区域不接管，交给 media_kit 自己的拖动逻辑
    if (e.localPosition.dy >
        size.height - widget.controlsBarHeight) {
      return;
    }
    _pointer = e.pointer;
    _startX = e.localPosition.dx;
    _accumDx = 0;
    _accumDy = 0;
    _mode = PlayerGestureMode.none;
    _hideTimer?.cancel();
  }

  void _onMove(PointerMoveEvent e, Size size) {
    if (!widget.enabled || e.pointer != _pointer) return;
    _accumDx += e.delta.dx;
    _accumDy += e.delta.dy;

    if (_mode == PlayerGestureMode.none) {
      final mode = dragMode(
        dx: _accumDx,
        dy: _accumDy,
        startX: _startX,
        width: size.width,
      );
      if (mode == PlayerGestureMode.none) return;
      _mode = mode;
      // 模式确定的那一刻再取起点值，保证「手指按下之后、方向判定之前」
      // 由别处改动的音量/亮度也能被尊重
      _startValue = switch (mode) {
        PlayerGestureMode.volume => widget.volume.value,
        PlayerGestureMode.brightness => widget.brightness.value,
        _ => 0,
      };
    }

    switch (_mode) {
      case PlayerGestureMode.volume:
        final v = valueFromDrag(
          start: _startValue,
          dy: _accumDy,
          height: size.height,
          span: 100,
          min: 0,
          max: 100,
        );
        widget.onVolumeChanged(v);
        _showHud(
          icon: v <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          title: '音量',
          value: volumeLabel(v),
          ratio: v / 100,
        );
      case PlayerGestureMode.brightness:
        final v = valueFromDrag(
          start: _startValue,
          dy: _accumDy,
          height: size.height,
          span: 1,
          min: _minBrightness,
          max: 1,
        );
        widget.onBrightnessChanged(v);
        _showHud(
          icon: Icons.brightness_6_rounded,
          title: '画面亮度',
          value: brightnessLabel(v),
          ratio: (v - _minBrightness) / (1 - _minBrightness),
        );
      case PlayerGestureMode.seek:
        final duration = widget.readDuration();
        // 以实时位置为锚：拖动这几秒里视频还在往前走，
        // 用按下时的快照会让松手后的落点越来越偏
        final live = widget.readPosition();
        final target = seekTargetFromDrag(
          position: live,
          duration: duration,
          dx: _accumDx,
          width: size.width,
        );
        _showHud(
          icon: Icons.fast_forward_rounded,
          title: formatClock(target),
          value: duration > Duration.zero
              ? '${formatDelta(target, live)} / ${formatClock(duration)}'
              : formatDelta(target, live),
          ratio: duration > Duration.zero
              ? (target.inMilliseconds / duration.inMilliseconds)
                  .clamp(0.0, 1.0)
              : null,
        );
      case PlayerGestureMode.none:
        break;
    }
  }

  void _onUp(Size size) {
    if (_pointer == null) return;
    Duration? seekTo;
    if (_mode == PlayerGestureMode.seek) {
      final live = widget.readPosition();
      final target = seekTargetFromDrag(
        position: live,
        duration: widget.readDuration(),
        dx: _accumDx,
        width: size.width,
      );
      // 时长未知时 target == live，不做无意义的 seek
      if (target != live) seekTo = target;
    }
    _pointer = null;
    _mode = PlayerGestureMode.none;
    _scheduleHideHud();
    if (seekTo != null) widget.onSeek(seekTo);
  }

  void _onCancel() {
    _pointer = null;
    _mode = PlayerGestureMode.none;
    _scheduleHideHud();
  }

  void _showHud({
    required IconData icon,
    required String title,
    required String value,
    double? ratio,
  }) {
    // 内容没变就不重建：拖动时指针回调频率很高，绝大多数帧的 HUD 文本是一样的
    final unchanged = _hudVisible &&
        _hudIcon == icon &&
        _hudTitle == title &&
        _hudValue == value &&
        (_hudRatio ?? -1).toStringAsFixed(2) ==
            (ratio ?? -1).toStringAsFixed(2);
    if (unchanged) return;
    _hideTimer?.cancel();
    setState(() {
      _hudVisible = true;
      _hudIcon = icon;
      _hudTitle = title;
      _hudValue = value;
      _hudRatio = ratio;
    });
  }

  void _scheduleHideHud() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _onDown(e, size),
          onPointerMove: (e) => _onMove(e, size),
          onPointerUp: (_) => _onUp(size),
          onPointerCancel: (_) => _onCancel(),
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedOpacity(
              opacity: _hudVisible ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
                child: Center(child: _hud()),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _hud() {
    return Container(
      constraints: const BoxConstraints(minWidth: 132, maxWidth: 262),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_hudIcon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                _hudTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _hudValue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          if (_hudRatio != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _hudRatio!.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.amberAccent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
