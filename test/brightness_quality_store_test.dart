import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/brightness_strategy.dart';
import 'package:hotshow/services/player_gestures.dart';
import 'package:hotshow/services/quality_service.dart';
import 'package:hotshow/services/quality_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _options = [
  QualityOption(label: '自动', rank: 1 << 20, isAuto: true),
  QualityOption(label: '1080P', url: 'https://a/1080.m3u8', rank: 1080000000),
  QualityOption(label: '720P', url: 'https://a/720.m3u8', rank: 720000000),
];

void main() {
  group('亮度策略', () {
    test('设置值会夹到 [min, 1]', () {
      final s = OverlayBrightnessStrategy();
      s.set(0.4);
      expect(s.value, 0.4);
      s.set(-3);
      expect(s.value, 0.05);
      s.set(9);
      expect(s.value, 1);
    });

    test('遮罩不透明度随亮度线性增加，最暗不超过 maxDim', () {
      final s = OverlayBrightnessStrategy();
      expect(s.dim, 0);
      s.set(0.5);
      expect(s.dim, closeTo(0.425, 1e-9));
      s.set(0.05);
      expect(s.dim, closeTo(0.8075, 1e-9));
    });

    testWidgets('遮罩层按当前亮度画黑色半透明，且不吃点击', (tester) async {
      final s = OverlayBrightnessStrategy();
      s.set(0.5);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Stack(children: [s.buildOverlay(ctx)]),
        ),
      ));
      // 框架自身的 ColoredBox 也在树里，按「黑色且不透明度>0」挑出遮罩这颗
      final boxes = tester.widgetList<ColoredBox>(find.byType(ColoredBox));
      final overlay = boxes.firstWhere(
        (b) => b.color.a > 0.001 && b.color.r == 0 && b.color.g == 0,
      );
      expect(overlay.color.a, closeTo(0.425, 0.01));
      // 遮罩必须完全不拦指针
      expect(find.byType(IgnorePointer), findsWidgets);
    });
  });

  group('清晰度记忆', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      qualityStore.debugReset();
      await qualityStore.load();
    });

    test('按剧记住标签，重启后仍是同一条', () async {
      await qualityStore.remember('s1#100', '1080P');
      expect(qualityStore.labelFor('s1#100'), '1080P');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('quality_choice_by_show'), contains('1080P'));
    });

    test('传 null 表示忘掉这部剧', () async {
      await qualityStore.remember('s1#100', '720P');
      await qualityStore.remember('s1#100', null);
      expect(qualityStore.labelFor('s1#100'), isNull);
    });

    test('记住的标签能在新探测结果里解析回具体变体', () {
      expect(resolveRemembered('720P', _options)?.url, 'https://a/720.m3u8');
      expect(resolveRemembered('auto', _options)?.isAuto, isTrue);
      // 片源换了没有这一档 → 解析不到，按「不应用」处理
      expect(resolveRemembered('4K', _options), isNull);
      // 线路选项不参与记忆解析
      const withLine = [..._options, QualityOption(label: '蓝光', groupIndex: 1, rank: 1080)];
      expect(resolveRemembered('蓝光', withLine), isNull);
    });
  });

  group('手势配置', () {
    test('更钝的一套：小的抖动不算拖动', () {
      const cfg = GestureConfig.comfortable;
      expect(
        dragMode(dx: 10, dy: 10, startX: 10, width: 400, slop: cfg.dragSlop),
        PlayerGestureMode.none,
      );
      // 默认灵敏度下同样的位移已经算拖动
      expect(
        dragMode(dx: 10, dy: 10, startX: 10, width: 400),
        PlayerGestureMode.volume,
      );
    });

    test('满屏秒数可按配置放大（电视远距离操作）', () {
      final a = seekTargetFromDrag(
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
        dx: 400,
        width: 400,
      );
      final b = seekTargetFromDrag(
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
        dx: 400,
        width: 400,
        secondsPerScreen: GestureConfig.comfortable.seekSecondsPerScreen,
      );
      expect(a, const Duration(minutes: 13));
      expect(b, const Duration(minutes: 14));
    });
  });
}
