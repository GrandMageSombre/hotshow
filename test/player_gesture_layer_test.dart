import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/widgets/player_gesture_layer.dart';

void main() {
  late ValueNotifier<double> volume;
  late ValueNotifier<double> brightness;
  late List<double> volumeCalls;
  late List<double> brightnessCalls;
  late List<Duration> seeks;
  late Duration position;

  const duration = Duration(minutes: 40);

  setUp(() {
    volume = ValueNotifier<double>(50);
    brightness = ValueNotifier<double>(1);
    volumeCalls = <double>[];
    brightnessCalls = <double>[];
    seeks = <Duration>[];
    position = const Duration(minutes: 10);
  });

  tearDown(() {
    volume.dispose();
    brightness.dispose();
  });

  Widget layer() => PlayerGestureLayer(
        volume: volume,
        brightness: brightness,
        readPosition: () => position,
        readDuration: () => duration,
        onVolumeChanged: (v) {
          volumeCalls.add(v);
          volume.value = v;
        },
        onBrightnessChanged: (v) {
          brightnessCalls.add(v);
          brightness.value = v;
        },
        onSeek: seeks.add,
      );

  /// 铺一个 400x400 的手势层，返回它左上角的全局坐标
  Future<Offset> pumpLayer(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(width: 400, height: 400, child: layer()),
        ),
      ),
    ));
    await tester.pump();
    return tester.getTopLeft(find.byType(PlayerGestureLayer));
  }

  testWidgets('左半边向上拖 → 音量变大，不碰亮度/进度', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(100, 320));
    await g.moveBy(const Offset(0, -100));
    await g.moveBy(const Offset(0, -100));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(volumeCalls, isNotEmpty);
    expect(volumeCalls.last, greaterThan(50));
    expect(brightnessCalls, isEmpty);
    expect(seeks, isEmpty);
    // HUD 显示的是音量而不是别的
    expect(find.text('音量'), findsOneWidget);
  });

  testWidgets('右半边向下拖 → 亮度变暗', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(320, 100));
    await g.moveBy(const Offset(0, 100));
    await g.moveBy(const Offset(0, 100));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(brightnessCalls, isNotEmpty);
    expect(brightnessCalls.last, lessThan(1));
    expect(volumeCalls, isEmpty);
    expect(seeks, isEmpty);
    expect(find.text('画面亮度'), findsOneWidget);
  });

  testWidgets('左右拖 → 松手才 seek 一次，目标按屏宽换算', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(100, 200));
    await g.moveBy(const Offset(100, 0));
    await g.moveBy(const Offset(100, 0));
    // 还没松手，不应该已经跳转
    expect(seeks, isEmpty);
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(seeks.length, 1);
    // 200/400 屏宽 = 90 秒
    expect(seeks.single, const Duration(minutes: 11, seconds: 30));
    expect(volumeCalls, isEmpty);
    expect(brightnessCalls, isEmpty);
  });

  testWidgets('向左拖 → 往回跳，不会变成负数', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(300, 200));
    await g.moveBy(const Offset(-200, 0));
    await g.moveBy(const Offset(-1200, 0));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    // 1400/400 屏宽 = -630 秒，比 10 分钟的当前位置还早 → 夹到片头
    expect(seeks.single, Duration.zero);
  });

  testWidgets('原地点击不触发任何手势（交给下层的播放控件）', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(200, 200));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(volumeCalls, isEmpty);
    expect(brightnessCalls, isEmpty);
    expect(seeks, isEmpty);
  });

  // 进度条就在底部这一带，本层不能抢：否则松手时会跳两次
  testWidgets('底部控件条区域不接管手势', (tester) async {
    final tl = await pumpLayer(tester);
    final g = await tester.startGesture(tl + const Offset(200, 380));
    await g.moveBy(const Offset(120, 0));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(seeks, isEmpty);
    expect(volumeCalls, isEmpty);
    expect(brightnessCalls, isEmpty);
  });

  // 关键回归：手势层盖在播放控件上面，如果它把点击吃掉，
  // 「点一下显隐控件」「双击快进」就全废了
  testWidgets('点击能穿透到下层控件', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const ColoredBox(color: Colors.black),
            ),
            layer(),
          ],
        ),
      ),
    ));
    await tester.pump();

    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('enabled=false 时完全不理手势', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: PlayerGestureLayer(
              volume: volume,
              brightness: brightness,
              readPosition: () => position,
              readDuration: () => duration,
              onVolumeChanged: volumeCalls.add,
              onBrightnessChanged: brightnessCalls.add,
              onSeek: seeks.add,
              enabled: false,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final tl = tester.getTopLeft(find.byType(PlayerGestureLayer));

    final g = await tester.startGesture(tl + const Offset(100, 320));
    await g.moveBy(const Offset(0, -150));
    await g.up();
    await tester.pump(const Duration(milliseconds: 800));

    expect(volumeCalls, isEmpty);
    expect(brightnessCalls, isEmpty);
  });
}
