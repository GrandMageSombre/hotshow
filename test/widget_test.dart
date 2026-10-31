// 基础冒烟测试：用注入的假数据服务验证三个主导航页面可正常构建与切换，
// 不访问真实网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/main.dart';
import 'package:hotshow/models/facet.dart';
import 'package:hotshow/models/genre.dart';
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/pages/genre_page.dart';
import 'package:hotshow/pages/search_page.dart';
import 'package:hotshow/services/show_service.dart';
import 'package:hotshow/widgets/legal_notice.dart';
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
  final List<FilterSelection> filterCalls = [];

  List<Genre> get genreCalls =>
      [for (final s in filterCalls) Genre(s.genreLabel, s.genreTag)];

  @override
  Future<List<ShowItem>> fetchFiltered({
    required HotTab tab,
    required FilterSelection selection,
    int start = 0,
    int count = 21,
  }) async {
    filterCalls.add(selection);
    return List.generate(
      3,
      (i) => ShowItem(
        id: '${selection.tags}$start$i',
        title: '${selection.genreLabel}片$i',
        cover: '',
        subtitle: '2024 / 测试',
      ),
    );
  }
}

/// 第一个类型慢返回，用于验证快速切换时旧回包不会污染新列表
class SlowGenreService extends FakeShowService {
  @override
  Future<List<ShowItem>> fetchFiltered({
    required HotTab tab,
    required FilterSelection selection,
    int start = 0,
    int count = 21,
  }) async {
    if (selection.genreLabel == '喜剧') {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    return List.generate(
      3,
      (i) => ShowItem(
        id: '${selection.tags}$start$i',
        title: '${selection.genreLabel}片$i',
        cover: '',
        subtitle: '2024 / 测试',
      ),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 声明弹窗有进程内单例状态，用例之间要复位
    LegalNotice.debugResetSession();
  });

  testWidgets('每次启动都弹使用声明（默认开启）', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('使用声明'), findsOneWidget);
    expect(find.textContaining('个人自用'), findsWidgets);
    expect(find.textContaining('禁止商业使用'), findsOneWidget);
    expect(find.textContaining('umena'), findsWidgets);
    // 联系方式必须是仓库直链，并给出「点 Star」的引导
    expect(
      find.textContaining('github.com/GrandMageSombre/hotshow'),
      findsWidgets,
    );
    expect(find.textContaining('点一个 Star'), findsWidgets);
    expect(find.text('去 GitHub 点个 Star'), findsOneWidget);
    // 底部新增的开关
    expect(find.text('每次打开时显示此声明'), findsOneWidget);

    await tester.tap(find.text('我已知悉'));
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsNothing);

    // 默认开关值应被原样写回（未改动不改设置）
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(LegalNotice.onLaunchKey), isTrue);
  });

  testWidgets('取消勾选后写入设置，下次启动不再自动弹', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    final box = find.byType(CheckboxListTile);
    await tester.ensureVisible(box);
    await tester.tap(box);
    await tester.pumpAndSettle();

    await tester.tap(find.text('我已知悉'));
    await tester.pumpAndSettle();

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(LegalNotice.onLaunchKey), isFalse);

    // 模拟「下次启动」：进程内状态复位后重新挂载 App
    LegalNotice.debugResetSession();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsNothing);
  });

  testWidgets('关掉后仍可从首页「i」重看，并再次打开自动弹出', (tester) async {
    SharedPreferences.setMockInitialValues({LegalNotice.onLaunchKey: false});
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsNothing);

    await tester.tap(find.byTooltip('使用声明'));
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsOneWidget);

    final box = find.byType(CheckboxListTile);
    // 打开瞬间必须反映已存的 false（若 _present 写死 true，这条会先挂）
    expect(tester.widget<CheckboxListTile>(box).value, isFalse);
    await tester.ensureVisible(box);
    await tester.tap(box); // 重新勾上
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已知悉'));
    await tester.pumpAndSettle();

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool(LegalNotice.onLaunchKey), isTrue);

    LegalNotice.debugResetSession();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsOneWidget);
  });

  testWidgets('首页「i」可随时重看声明', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('使用声明'));
    await tester.pumpAndSettle();
    expect(find.text('使用声明'), findsOneWidget);
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
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
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
    await tester.pumpWidget(HotShowApp(service: service, autoRefresh: false, legalNotice: false));
    await tester.pumpAndSettle();

    expect(find.text('类型'), findsWidgets);
    expect(find.text('喜剧'), findsWidgets);

    await tester.tap(find.text('喜剧').first);
    await tester.pumpAndSettle();

    expect(service.genreCalls, isNotEmpty);
    expect(service.genreCalls.last.label, '喜剧');
    expect(find.textContaining('正在看：喜剧'), findsOneWidget);
    // 地区/年份维度也在
    expect(find.text('地区'), findsWidgets);
    expect(find.text('年份'), findsWidgets);
  });

  testWidgets('选地区会带上地区 tag，文案同步更新', (tester) async {
    final service = RecordingShowService();
    await tester.pumpWidget(HotShowApp(service: service, autoRefresh: false, legalNotice: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('地区').first);
    await tester.pumpAndSettle();
    // 菜单里的「中国大陆」（列表里可能还有同名词条，取菜单项）
    await tester.tap(find.text('中国大陆').last);
    await tester.pumpAndSettle();

    expect(service.filterCalls, isNotEmpty);
    expect(service.filterCalls.last.area.tag, '中国大陆');
    expect(find.textContaining('中国大陆'), findsWidgets);
  });

  testWidgets('电影 Tab 有 5 个子榜单且能渲染网格', (tester) async {
    final service = RecordingShowService();
    await tester.pumpWidget(HotShowApp(service: service, autoRefresh: false, legalNotice: false));
    await tester.pumpAndSettle();

    await tester.tap(find.text('电影').first);
    await tester.pumpAndSettle();

    expect(find.text('正在上映'), findsWidgets);
    expect(find.text('TOP250'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入关键词能搜出结果（回归：v1.7.0 搜索页不重建）', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
    );
    await tester.pumpAndSettle();
    await tapNav(tester, '搜索');

    await tester.enterText(find.byType(TextField), '庆余年');
    // 等 600ms 防抖
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(find.textContaining('庆余年 结果'), findsWidgets);
  });

  testWidgets('回车立即搜索并写入历史，清空后回到历史页', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
    );
    await tester.pumpAndSettle();
    await tapNav(tester, '搜索');

    await tester.enterText(find.byType(TextField), '三体');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('三体 结果'), findsWidgets);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('三体'), findsWidgets);
  });

  testWidgets('搜索后点「全部」能回到搜索历史（回归：isAll 分支不重建）', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
    );
    await tester.pumpAndSettle();
    await tapNav(tester, '搜索');

    await tester.enterText(find.byType(TextField), '三体');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('三体 结果'), findsWidgets);

    // 类型条第一个是「全部」（限定在搜索页，IndexedStack 里首页也有「全部」）
    final allChip = find
        .descendant(of: find.byType(SearchPage), matching: find.text('全部'))
        .first;
    await tester.tap(allChip);
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
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
        HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(GridView), findsWidgets);
    });
  }

  // 手机竖屏（360x800）下，开关若被条款挤出首屏，用户根本发现不了「可以关掉」
  testWidgets('360x800 竖屏：勾选框无需滚动即可见可点', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CheckboxListTile).hitTestable(), findsOneWidget);
  });

  testWidgets('系统字体放大到 1.3 倍时卡片仍不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
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
      HotShowApp(service: FakeShowService(), autoRefresh: false, legalNotice: false),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
