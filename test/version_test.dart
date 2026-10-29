// 版本号一致性：pubspec 与 app_info 两处不同步会导致「关于/更新」显示错版本，
// 这里用测试兜住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/app_info.dart';

void main() {
  test('pubspec.yaml 的 version 与 kAppVersion 一致', () {
    final text = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
    expect(m, isNotNull, reason: 'pubspec.yaml 里找不到 version');
    expect(kAppVersion, m!.group(1));
  });
}
