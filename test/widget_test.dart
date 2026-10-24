// 基础冒烟测试：用注入的假数据服务验证三个主导航页面可正常构建与切换，
// 不访问真实网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/main.dart';
import 'package:hotshow/models/show_item.dart';
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

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('底部导航切换三个页面', (tester) async {
    await tester.pumpWidget(
      HotShowApp(service: FakeShowService(), autoRefresh: false),
    );
    await tester.pumpAndSettle();

    // 首页加载了假榜单数据
    expect(find.textContaining('测试剧0'), findsWidgets);

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('搜索历史'), findsNothing); // 初始无历史

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsNothing);
    expect(find.text('浏览历史'), findsNothing); // 空状态提示
    expect(find.textContaining('暂无历史记录'), findsOneWidget);

    await tester.tap(find.text('热播'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试剧0'), findsWidgets);
  });
}
