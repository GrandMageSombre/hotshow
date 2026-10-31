import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/services/player_gestures.dart';

void main() {
  group('分区：左音量 / 右亮度', () {
    test('以按下点判定，跨过中线也不换功能', () {
      expect(sideOf(10, 400), GestureSide.left);
      expect(sideOf(200, 400), GestureSide.right);
      expect(sideOf(399, 400), GestureSide.right);
    });

    test('竖直拖动按左右半屏分到音量/亮度', () {
      expect(
        dragMode(dx: 0, dy: -40, startX: 50, width: 400),
        PlayerGestureMode.volume,
      );
      expect(
        dragMode(dx: 0, dy: -40, startX: 350, width: 400),
        PlayerGestureMode.brightness,
      );
    });

    test('横向为主时判为进度，哪怕也在竖直方向动过', () {
      expect(
        dragMode(dx: 60, dy: -20, startX: 50, width: 400),
        PlayerGestureMode.seek,
      );
    });

    test('位移不足阈值当作点击，不触发任何手势', () {
      expect(
        dragMode(dx: 3, dy: -4, startX: 50, width: 400),
        PlayerGestureMode.none,
      );
    });
  });

  group('音量/亮度增量', () {
    test('向上拖满屏高音量到 100，向下到 0（并夹住）', () {
      expect(
        valueFromDrag(
            start: 50, dy: -400, height: 400, span: 100, min: 0, max: 100),
        100,
      );
      expect(
        valueFromDrag(
            start: 50, dy: 400, height: 400, span: 100, min: 0, max: 100),
        0,
      );
      // 继续往下拖不会变成负数
      expect(
        valueFromDrag(
            start: 10, dy: 900, height: 400, span: 100, min: 0, max: 100),
        0,
      );
    });

    test('亮度满屏高度 = 100%，且不低于下限', () {
      expect(
        valueFromDrag(
            start: 1, dy: 200, height: 400, span: 1, min: 0.05, max: 1),
        0.5,
      );
      expect(
        valueFromDrag(
            start: 0.5, dy: 400, height: 400, span: 1, min: 0.05, max: 1),
        0.05,
      );
    });

    test('高度为 0 时不崩、返回起点值', () {
      expect(
        valueFromDrag(
            start: 42, dy: -100, height: 0, span: 100, min: 0, max: 100),
        42,
      );
    });
  });

  group('进度增量', () {
    test('拖满整屏 = 180 秒', () {
      expect(
        seekTargetFromDrag(
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 40),
          dx: 400,
          width: 400,
        ),
        const Duration(minutes: 13),
      );
    });

    test('不支持拖到片头之前 / 片尾之后', () {
      expect(
        seekTargetFromDrag(
          position: const Duration(seconds: 30),
          duration: const Duration(minutes: 40),
          dx: -400,
          width: 400,
        ),
        Duration.zero,
      );
      expect(
        seekTargetFromDrag(
          position: const Duration(minutes: 39),
          duration: const Duration(minutes: 40),
          dx: 400,
          width: 400,
        ),
        const Duration(minutes: 40),
      );
    });

    test('时长未知时保持原位置，不把进度拽回 0', () {
      expect(
        seekTargetFromDrag(
          position: const Duration(minutes: 5),
          duration: Duration.zero,
          dx: 120,
          width: 400,
        ),
        const Duration(minutes: 5),
      );
    });
  });

  group('HUD 文案', () {
    test('时长取整到秒，小时位按需出现', () {
      expect(formatClock(const Duration(minutes: 2, seconds: 7)), '02:07');
      expect(formatClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
      expect(formatClock(Duration.zero), '00:00');
    });

    test('增量带正负号', () {
      expect(
        formatDelta(const Duration(seconds: 130), const Duration(seconds: 100)),
        '+00:30',
      );
      expect(
        formatDelta(const Duration(seconds: 70), const Duration(seconds: 100)),
        '-00:30',
      );
    });

    test('音量/亮度百分比四舍五入', () {
      expect(volumeLabel(47.6), '48%');
      expect(brightnessLabel(0.724), '72%');
    });
  });
}
