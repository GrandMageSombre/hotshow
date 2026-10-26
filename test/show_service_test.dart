// 「全部」聚合流的纯函数部分（mergeShowPages）单测：不访问网络。
import 'package:flutter_test/flutter_test.dart';
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
}
