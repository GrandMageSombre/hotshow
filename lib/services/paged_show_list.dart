import 'package:flutter/foundation.dart';

import '../models/show_item.dart';

/// 「筛选 + 分页」的状态机，供首页 / 搜索页 / 分类页共用。
///
/// 之前三个页面各自维护 `_items / _start / _hasMore / _loading / _error` 与
/// 「切筛选要重置」的样板，新增一个入口就得复制一遍。抽出来后：
/// - 页面只负责提供 `loader(start)`（决定用哪套筛选）；
/// - 切筛选调 [reset]，滚动到底调 [loadMore]；
/// - 请求代号 `_request` 保证「慢回包」不会覆盖新筛选的结果。
class PagedShowList extends ChangeNotifier {
  PagedShowList({required this.loader, this.pageSize = 21});

  /// 取一页数据：参数是起始下标
  final Future<List<ShowItem>> Function(int start) loader;

  /// 每页条数（接口 count）
  final int pageSize;

  final List<ShowItem> items = [];

  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  int _start = 0;
  int _request = 0;
  bool _disposed = false;

  bool get loading => _loading;
  bool get hasMore => _hasMore;
  Object? get error => _error;
  bool get isEmpty => items.isEmpty;

  /// 首次加载或「下拉开刷/换筛选」
  Future<void> reset() => _load(reset: true);

  /// 触底加载下一页；加载中、已到底或有错误时静默跳过
  Future<void> loadMore() {
    if (_loading || !_hasMore || _error != null || items.isEmpty) {
      return Future.value();
    }
    return _load();
  }

  /// 翻页失败后重试（列表已有内容时不给整页错误页，只补一个「重试」尾巴）
  Future<void> retryMore() {
    if (_disposed || _loading) return Future.value();
    _error = null;
    _hasMore = true;
    _notify();
    return _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_disposed) return;
    if (!reset && _loading) return;
    final req = ++_request;
    if (reset) {
      items.clear();
      _start = 0;
      _hasMore = true;
      _error = null;
    }
    _loading = true;
    _notify();
    try {
      final list = await loader(_start);
      if (_disposed || req != _request) return;
      items.addAll(list);
      _start += list.length;
      // 用 pageSize 判断而不是魔法数：接口偶尔返回半页（如 12 条）时
      // 若按 10 判会误判为「还有更多」，多打一次空请求
      _hasMore = list.length >= pageSize;
    } catch (e) {
      if (_disposed || req != _request) return;
      _error = e;
      _hasMore = false;
    } finally {
      if (!_disposed && req == _request) {
        _loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
