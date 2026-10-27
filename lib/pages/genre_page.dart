import 'package:flutter/material.dart';

import '../models/genre.dart';
import '../models/show_item.dart';
import '../services/show_service.dart';
import '../widgets/common_views.dart';
import '../widgets/genre_bar.dart';
import '../widgets/show_card.dart';
import '../widgets/show_grid.dart';

/// 单个「类型」的浏览页：详情页点类型标签、分类入口都跳这里。
/// 顶部保留同一套类型条，方便横向换类型继续看。
class GenrePage extends StatefulWidget {
  final HotTab tab;
  final Genre genre;
  final ShowService? service;

  const GenrePage({
    super.key,
    required this.tab,
    required this.genre,
    this.service,
  });

  @override
  State<GenrePage> createState() => _GenrePageState();
}

class _GenrePageState extends State<GenrePage> {
  late final ShowService _service = widget.service ?? ShowService();
  late final List<Genre> _genres = () {
    final base = genresOf(widget.tab);
    // 详情页可能传来表里没有的类型，补到第二位保证能被选中高亮
    if (base.contains(widget.genre)) return base;
    return [base.first, widget.genre, ...base.skip(1)];
  }();
  late Genre _genre = widget.genre;
  final ScrollController _scroll = ScrollController();
  final List<ShowItem> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  int _start = 0;

  /// 请求代号：切类型时自增，作废在途请求的回调，
  /// 否则「切换后立刻返回」会把旧类型的数据写进新类型的列表。
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(force: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _load();
  }

  Future<void> _load({bool force = false}) async {
    if (!force && (_loading || !_hasMore)) return;
    final req = ++_request;
    final start = force ? 0 : _start;
    setState(() {
      _loading = true;
      if (force) {
        _error = null;
        _items.clear();
        _start = 0;
        _hasMore = true;
      }
    });
    final genre = _genre;
    try {
      final list = await _service.fetchByGenre(
        tab: widget.tab,
        genre: genre,
        start: start,
      );
      if (!mounted || req != _request) return;
      setState(() {
        _items.addAll(list);
        _start = start + list.length;
        _hasMore = list.length >= 10;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || req != _request) return;
      setState(() {
        _error = e;
        _loading = false;
        _hasMore = false;
      });
    }
  }

  void _switchGenre(Genre g) {
    if (g == _genre) return;
    setState(() => _genre = g);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_genre.isAll ? '${widget.tab.label}·全部' : _genre.label),
      ),
      body: Column(
        children: [
          GenreBar(
            genres: _genres,
            selected: _genre,
            onSelected: _switchGenre,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _load(force: true),
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null && _items.isEmpty) {
      return ErrorRetry(error: _error, onRetry: () => _load(force: true));
    }
    if (_items.isEmpty) {
      return _loading
          ? const Center(child: CircularProgressIndicator())
          : const EmptyHint(message: '这个类型暂无内容');
    }
    return LayoutBuilder(builder: (context, box) {
      final metrics = ShowGridMetrics.resolve(
        availableWidth: box.maxWidth - ShowGridMetrics.horizontalPadding * 2,
        textScaler: MediaQuery.textScalerOf(context),
      );
      return GridView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          ShowGridMetrics.horizontalPadding,
          4,
          ShowGridMetrics.horizontalPadding,
          12,
        ),
        gridDelegate: metrics.delegate(),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return ListTail(hasMore: _hasMore || _loading);
          }
          return ShowCard(item: _items[i]);
        },
      );
    });
  }
}
