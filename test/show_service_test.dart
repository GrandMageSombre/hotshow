// 「全部」聚合流的纯函数部分（mergeShowPages）单测 + 封面字段解析 / 类型映射。
// 不访问网络。
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/genre.dart';
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/show_service.dart';

ShowItem item(String id) =>
    ShowItem(id: id, title: '剧$id', cover: '', subtitle: '2024 / 测试');

void main() {
  test('轮播交织：各榜单轮流取第 i 条', () {
    final merged = mergeShowPages([
      [item('a1'), item('a2')],
      [item('b1'), item('b2')],
      [item('c1')],
    ], start: 0, count: 21);
    expect(merged.map((e) => e.id).toList(),
        ['a1', 'b1', 'c1', 'a2', 'b2']);
  });

  test('按 id 去重，保留首次出现', () {
    final merged = mergeShowPages([
      [item('x'), item('y')],
      [item('y'), item('z')],
    ], start: 0, count: 21);
    expect(merged.map((e) => e.id).toList(), ['x', 'y', 'z']);
  });

  test('分页切片：第 2 页不与第 1 页重复，且前缀稳定', () {
    final pages = [
      [for (var i = 0; i < 4; i++) item('a$i')],
      [for (var i = 0; i < 4; i++) item('b$i')],
    ];
    final page1 = mergeShowPages(pages, start: 0, count: 4);
    final page2 = mergeShowPages(pages, start: 4, count: 4);
    final ids1 = page1.map((e) => e.id).toSet();
    final ids2 = page2.map((e) => e.id).toSet();
    expect(page1, hasLength(4));
    expect(page2, hasLength(4));
    expect(ids1.intersection(ids2), isEmpty);
    // 交织顺序固定：a0 b0 a1 b1 | a2 b2 a3 b3
    expect(page1.map((e) => e.id).toList(), ['a0', 'b0', 'a1', 'b1']);
    expect(page2.map((e) => e.id).toList(), ['a2', 'b2', 'a3', 'b3']);
  });

  test('超出总量时返回空页', () {
    final page = mergeShowPages([
      [item('a1')],
    ], start: 10, count: 4);
    expect(page, isEmpty);
  });

  test('空榜单参与交织不影响顺序', () {
    final merged = mergeShowPages([
      <ShowItem>[],
      [item('b1'), item('b2')],
      <ShowItem>[],
    ], start: 0, count: 21);
    expect(merged.map((e) => e.id).toList(), ['b1', 'b2']);
  });

  group('封面字段解析（回归：动漫榜单海报全部空白）', () {
    test('pic 是对象时按 large 取，不能变成 "{large: ...}" 伪地址', () {
      final it = ShowItem.fromRecommendJson({
        'uri': 'douban://douban.com/tv/35284273',
        'title': '葬送的芙莉莲',
        'pic': {
          'large': 'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.webp',
          'normal': 'https://img3.doubanio.com/view/photo/s_ratio_poster/public/p1.webp',
        },
      });
      expect(it!.cover, startsWith('https://img3.doubanio.com/'));
      expect(it.cover, isNot(contains('{')));
    });

    test('cover_url 是对象时同样能解析', () {
      final it = ShowItem.fromRecommendJson({
        'uri': 'douban://douban.com/tv/1',
        'title': 'X',
        'cover_url': {'large': 'https://img1.doubanio.com/a.jpg'},
      });
      expect(it!.cover, 'https://img1.doubanio.com/a.jpg');
    });

    test('cover_url 字符串优先于 pic 对象', () {
      final it = ShowItem.fromRecommendJson({
        'uri': 'douban://douban.com/tv/1',
        'title': 'X',
        'cover_url': 'https://img2.doubanio.com/b.jpg',
        'pic': {'large': 'https://img2.doubanio.com/c.jpg'},
      });
      expect(it!.cover, 'https://img2.doubanio.com/b.jpg');
    });

    test('两者都缺时为空串而不是 "null"', () {
      final it = ShowItem.fromRecommendJson({
        'uri': 'douban://douban.com/tv/1',
        'title': 'X',
      });
      expect(it!.cover, '');
    });

    test('pickCoverUrl 忽略空白与非法类型', () {
      expect(ShowItem.pickCoverUrl('  '), isNull);
      expect(ShowItem.pickCoverUrl(42), isNull);
      expect(ShowItem.pickCoverUrl({'normal': ' n.jpg '}), 'n.jpg');
    });
  });

  group('类型（分类）定义', () {
    test('动漫类型必须带「动画」前缀，否则会混进真人剧', () {
      for (final g in kAnimeGenres.where((g) => !g.isAll)) {
        expect(g.tag, startsWith('动画,'), reason: '${g.label} 缺前缀');
      }
    });

    test('电视剧类型不带前缀，直接用类型名', () {
      for (final g in kTvGenres.where((g) => !g.isAll)) {
        expect(g.tag, g.label);
      }
    });

    test('每个大分类的类型表都以「全部」开头', () {
      for (final tab in HotTab.values) {
        final list = genresOf(tab);
        expect(list.first.isAll, isTrue, reason: '$tab 首项不是全部');
        expect(list.length, greaterThan(5));
      }
    });

    test('详情页类型名反查：动漫条目补 动画 前缀', () {
      expect(genreForLabel('科幻').tag, '科幻');
      expect(genreForLabel('科幻', anime: true).tag, '动画,科幻');
      expect(genreForLabel('武侠', anime: true).tag, '动画,武侠');
    });

    test('「国漫」走 multiTag，单标签过少的问题由多源交织兜住', () {
      final ch = kChannels[HotTab.anime]!.firstWhere((c) => c.label == '国漫');
      expect(ch.sourceKind, 'multiTag');
      expect(ch.sourceId.split('|').length, greaterThanOrEqualTo(2));
    });
  });
}
