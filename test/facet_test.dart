// 多维筛选（类型/地区/年份）纯逻辑单测：tags 拼接、缓存键、年份表。
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/facet.dart';
import 'package:hotshow/models/genre.dart';

void main() {
  test('tags 按「类型 → 地区 → 年份」拼接', () {
    const sel = FilterSelection(
      genre: Genre('喜剧', '喜剧'),
      area: FacetOption('中国大陆', '中国大陆'),
      year: FacetOption('2024', '2024'),
    );
    expect(sel.tagList, ['喜剧', '中国大陆', '2024']);
    expect(sel.tags, '喜剧,中国大陆,2024');
    expect(sel.summary, '喜剧 · 中国大陆 · 2024');
  });

  test('未选维度不参与拼接', () {
    const onlyYear = FilterSelection(year: FacetOption('2024', '2024'));
    expect(onlyYear.tags, '2024');
    expect(onlyYear.summary, '2024');
    expect(onlyYear.isAll, isFalse);
  });

  test('全空才算「全部」（会回落到子榜单交织）', () {
    const empty = FilterSelection();
    expect(empty.isAll, isTrue);
    expect(empty.tags, '');
    expect(empty.summary, '');
  });

  test('缓存键区分任一维度', () {
    const a = FilterSelection(genre: Genre('喜剧', '喜剧'));
    final b = a.copyWith(year: const FacetOption('2024', '2024'));
    final c = a.copyWith(area: const FacetOption('美国', '美国'));
    expect(a.key, isNot(b.key));
    expect(a.key, isNot(c.key));
    expect(b.key, isNot(c.key));
    expect(a == b, isFalse);
    expect(a == const FilterSelection(genre: Genre('喜剧', '喜剧')), isTrue);
  });

  test('短剧/动漫前缀保留在组合里', () {
    const short = FilterSelection(
      genre: Genre('古装', '短剧,古装'),
      area: FacetOption('中国大陆', '中国大陆'),
    );
    expect(short.tags, '短剧,古装,中国大陆');

    const anime = FilterSelection(genre: Genre('热血', '动画,热血'));
    expect(anime.tags, '动画,热血');
  });

  test('年份表默认近十年且以「全部」开头', () {
    final years = buildYears(2026);
    expect(years.first.isAll, isTrue);
    expect(years.length, 13);
    expect(years[1].tag, '2026');
    expect(years.last.tag, '2015');
  });

  test('电影域类型表不带前缀，短剧/动漫带前缀', () {
    for (final g in kMovieGenres.where((g) => !g.isAll)) {
      expect(g.tag, g.label);
    }
    for (final g in kShortDramaGenres.where((g) => !g.isAll)) {
      expect(g.tag, startsWith('短剧,'));
    }
    for (final g in kAnimeGenres.where((g) => !g.isAll)) {
      expect(g.tag, startsWith('动画,'));
    }
  });
}
