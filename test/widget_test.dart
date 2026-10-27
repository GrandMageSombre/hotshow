// 基础冒烟测试：用注入的假数据服务验证三个主导航页面可正常构建与切换，
// 不访问真实网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/main.dart';
import 'package:hotshow/models/genre.dart';
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/pages/genre_page.dart';
import 'package:hotshow/services/show_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeShowService extends ShowService {
  @override
  Future<List<ShowItem>> fetchHot({
    required HotTab tab,
    required SubChannel channel,
    int start = 0,
    int count = 21,
  }) async =>
      List.generate(
        6,
        (i) => ShowItem(
          id: '$start$i',
          title: '${channel.label}测试剧$i',
          cover: '',
          rating: 8.0 + i * 0.1,
          subtitle: '2024 / 测试 / 假数据',
        ),
      );

  @override
  Future<List<ShowItem>> search(String keyword,
      {int start = 0, int count = 20}) async =>
      List.generate(
        5,
        (i) => ShowItem(
          id: 's$start$i',
          title: '$keyword 结果$i',
          cover: '',
          rating: 7.5,
        ),
      );

  @override
  Future<ShowDetail> detail(ShowItem item) async => ShowDetail(
        item: item,
        intro: '测试简介',
        cardSubtitle: item.subtitle,
      );
}

/// 记录分类请求，验证类型切换确实换了数据源
class RecordingShowService extends FakeShowService {
  final List<Genre> genreCalls = [];

  @override
  Future<List<ShowItem>> fetchByGenre({
    required HotTab tab,
    required Genre genre,
    int start = 0,
    int count = 21,
  }) async {
    genreCalls.add(genre);
    return List.generate(
      3,
      (i) => ShowItem(
        id: '${genre.tag}$start$i',
        title: '${genre.label}片$i',
        cover: '',
        subtitle: '2024 / 测试',
      ),
    );
  }
}

/// 第一个类型慢返回，用于验证快速切换时旧回包不会污染新列表
class SlowGenreService extends FakeShowService {
  @override
  Future<List<ShowItem>> fetchByGenre({
    required HotTab tab,
    required Genre genre,
    int start = 0,
    int count = 21,
  }) async {
    if (genre.label == '喜剧') {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return List.generate(
      3,
      (i) => ShowItem(
        id: '${genre.tag}$start$i',
        title: '${genre.label}片$i',
        cover: '',
        subtitle: '2024 / 测试',
      ),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 按底部导航条里的文字点击（页内也可能有同名 chip，必须限定范围）
  Future<void> tapNav(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('底部导航切换三个页面', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    // 首页加载了假榜单数据
    expect(find.textContaining('测试剧0'), findsWidgets);

    await tapNav(tester, '搜索');
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索历史'), findsNothing); // 初始无历史

    await tapNav(tester, '历史');
    expect(find.text('搜索历史'), findsNothing);
    expect(find.text('浏览历史'), findsNothing); // 空状态提示
    expect(find.textContaining('暂无历史记录'), findsOneWidget);

    await tapNav(tester, '热播');
    expect(find.textContaining('测试剧0'), findsWidgets);
  });

  testWidgets('首页有类型筛选条，切类型会走分类接口', (tester) async {
    final service = RecordingShowService();
    await tester.pumpWidget(HotShowApp(service: service, autoRefresh: false));
    await tester.pumpAndSettle();

    expect(find.text('类型'), findsWidgets);
    expect(find.text('喜剧'), findsWidgets);

    await tester.tap(find.text('喜剧').first);
    await tester.pumpAndSettle();

    expect(service.genreCalls, isNotEmpty);
    expect(service.genreCalls.last.label, '喜剧');
    expect(find.textContaining('正在按「喜剧」浏览'), findsOneWidget);
  });

  testWidgets('分类页：切类型后旧请求的回包不会覆盖新列表', (tester) async {
    // 第一个类型故意慢返回，模拟「网络慢时快速切类型」
    final service = SlowGenreService();
    await tester.pumpWidget(MaterialApp(
      home: GenrePage(
        tab: HotTab.tv,
        genre: kTvGenres.firstWhere((g) => g.label == '喜剧'),
        service: service,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('战争').first);
    await tester.pump();

    // 等两个请求都结束
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('战争片'), findsWidgets);
    expect(find.textContaining('喜剧片'), findsNothing);
  });

  // 回归：354–377dp 这类宽度下，旧实现按两套公式算列数/卡片宽度，
  // 会让海报顶出单元格、盖住下一行（真机上表现为「整张剧照占满屏」）。
  for (final size in const [Size(320, 640), Size(360, 780), Size(375, 812), Size(411, 891)]) {
    testWidgets('窄屏 ${size.width.toInt()}dp 海报网格不溢出', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        HotShowApp(service: FakeShowService(), autoRefresh: false),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(GridView), findsWidgets);
    });
  }

  testWidgets('系统字体放大到 1.3 倍时卡片仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('系统字体放大到 2 倍（被夹到上限）仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
