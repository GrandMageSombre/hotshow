import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/pages/live_page.dart';
import 'package:hotshow/services/live_catalog.dart';

const String _json = '''
{
 "updated": "2026-11-05",
 "groups": [
  {"id":"cctv","name":"央视","channels":[
    {"name":"CCTV-1 综合","url":"http://a/1.m3u8"},
    {"name":"CCTV-5 体育","url":"http://a/5.m3u8"}
  ]},
  {"id":"local","name":"地方","channels":[
    {"name":"湖南卫视","url":"http://a/hn.m3u8"}
  ]},
  {"id":"foreign","name":"国外","channels":[
    {"name":"NHK 综合","url":"http://a/nhk.m3u8"}
  ]},
  {"id":"sports","name":"体育","channels":[
    {"name":"NBA TV","url":"http://a/nba.m3u8"}
  ]}
 ]
}
''';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: LivePage(catalog: LiveCatalog.parse(_json)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('四个分类 Tab 都显示台数，外加一个「全部」', (tester) async {
    await _pump(tester);
    expect(find.text('全部 5'), findsOneWidget);
    expect(find.text('央视 2'), findsOneWidget);
    expect(find.text('地方 1'), findsOneWidget);
    expect(find.text('国外 1'), findsOneWidget);
    expect(find.text('体育 1'), findsOneWidget);
  });

  testWidgets('默认停在「全部」，能看到所有分类的台', (tester) async {
    await _pump(tester);
    expect(find.text('CCTV-1 综合'), findsOneWidget);
    expect(find.text('CCTV-5 体育'), findsOneWidget);
    expect(find.text('湖南卫视'), findsOneWidget);
    expect(find.text('NHK 综合'), findsOneWidget);
    expect(find.text('NBA TV'), findsOneWidget);
  });

  testWidgets('「全部」里搜 NBA 能直接命中', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'NBA');
    await tester.pumpAndSettle();
    expect(find.text('NBA TV'), findsOneWidget);
    expect(find.text('CCTV-1 综合'), findsNothing);
  });

  testWidgets('搜索能过滤当前分类', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'CCTV-5');
    await tester.pumpAndSettle();
    expect(find.text('CCTV-5 体育'), findsOneWidget);
    expect(find.text('CCTV-1 综合'), findsNothing);
  });

  testWidgets('搜索无结果时给出提示', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), '不存在的台');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有匹配的台'), findsOneWidget);
  });

  testWidgets('清空搜索后恢复全部', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'CCTV-5');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('CCTV-1 综合'), findsOneWidget);
  });

  testWidgets('窄屏 320dp 下网格不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester);
    expect(tester.takeException(), isNull);
  });
}
