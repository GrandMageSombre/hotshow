// PagedShowList 单测：分页、到底、错误态、以及「慢回包不覆盖新筛选」。
import 'package:flutter_test/flutter_test.dart';
import 'package:hotshow/models/show_item.dart';
import 'package:hotshow/services/paged_show_list.dart';

ShowItem item(String id) => ShowItem(id: id, title: id, cover: '');

void main() {
  test('满一页（=pageSize）视为还有更多，累计 items', () async {
    final list = PagedShowList(
      loader: (start) async => [for (var i = 0; i < 21; i++) item('a$start$i')],
    );
    await list.reset();
    expect(list.items, hasLength(21));
    expect(list.hasMore, isTrue);

    await list.loadMore();
    expect(list.items, hasLength(42));
    expect(list.loading, isFalse);
  });

  test('半页（<pageSize）视为到底，不再多打一次空请求', () async {
    var calls = 0;
    final list = PagedShowList(loader: (start) async {
      calls++;
      return [for (var i = 0; i < 12; i++) item('h$i')];
    });
    await list.reset();
    expect(list.hasMore, isFalse);
    await list.loadMore();
    expect(calls, 1);
  });

  test('空页判定到底，loadMore 不再请求', () async {
    var calls = 0;
    final list = PagedShowList(loader: (start) async {
      calls++;
      return [item('only')];
    });
    await list.reset();
    expect(list.hasMore, isFalse);
    await list.loadMore();
    expect(calls, 1);
  });

  test('错误写入 error 并停止翻页，reset 后可恢复', () async {
    var fail = true;
    final list = PagedShowList(loader: (start) async {
      if (fail) throw Exception('boom');
      return [for (var i = 0; i < 12; i++) item('x$i')];
    });
    await list.reset();
    expect(list.error, isNotNull);
    expect(list.hasMore, isFalse);

    fail = false;
    await list.reset();
    expect(list.error, isNull);
    expect(list.items, isNotEmpty);
  });

  test('reset 会清空旧数据并重新从 0 开始', () async {
    final starts = <int>[];
    final list = PagedShowList(loader: (start) async {
      starts.add(start);
      return [for (var i = 0; i < 21; i++) item('$start-$i')];
    });
    await list.reset();
    await list.loadMore();
    expect(starts, [0, 21]);

    await list.reset();
    expect(starts, [0, 21, 0]);
    expect(list.items, hasLength(21));
  });

  test('慢回包不会覆盖新筛选的结果', () async {
    var slow = true;
    final list = PagedShowList(loader: (start) async {
      if (slow) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return [item('old')];
      }
      return [item('new')];
    });
    final first = list.reset(); // 旧筛选请求在飞
    slow = false;
    await list.reset(); // 用户立刻换了筛选
    await first; // 旧请求这时才回来
    expect(list.items.map((e) => e.id), ['new']);
  });

  test('dispose 之后回调不再 notify', () async {
    final list = PagedShowList(loader: (start) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return [for (var i = 0; i < 12; i++) item('d$i')];
    });
    final future = list.reset();
    list.dispose();
    await future; // 不应抛 "used after being disposed"
    expect(list.items, isEmpty);
  });
}
