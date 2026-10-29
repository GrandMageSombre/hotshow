import 'dart:async';

import 'package:flutter/material.dart';

import '../models/facet.dart';
import '../models/genre.dart';
import '../services/paged_show_list.dart';
import '../services/show_service.dart';
import '../widgets/facet_menu.dart';
import '../widgets/legal_notice.dart';
import '../widgets/genre_bar.dart';
import '../widgets/paged_show_grid.dart';

class HomePage extends StatefulWidget {
  final ShowService? service;
  final bool autoRefresh;
  const HomePage({super.key, this.service, this.autoRefresh = true});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab =
      TabController(length: HotTab.values.length, vsync: this);
  final List<GlobalKey<_HotListViewState>> _listKeys =
      HotTab.values.map((t) => GlobalKey<_HotListViewState>()).toList();

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _refreshCurrent() {
    _listKeys[_tab.index].currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('热剧速览'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: '使用声明',
            onPressed: () => LegalNotice.show(context),
            icon: const Icon(Icons.info_outline_rounded),
          ),
          IconButton(
            tooltip: '刷新榜单',
            onPressed: _refreshCurrent,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          tabs: [for (final t in HotTab.values) Tab(text: t.label)],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          for (var i = 0; i < HotTab.values.length; i++)
            _HotListView(
              key: _listKeys[i],
              tab: HotTab.values[i],
              isActive: () => mounted && _tab.index == i,
              service: widget.service,
              autoRefresh: widget.autoRefresh,
            ),
        ],
      ),
    );
  }
}

class _LoadedPage {
  final PagedShowList list;
  DateTime updatedAt = DateTime.now();
  _LoadedPage(this.list);
}

class _HotListView extends StatefulWidget {
  final HotTab tab;
  final bool Function() isActive;
  final ShowService? service;
  final bool autoRefresh;

  const _HotListView({
    super.key,
    required this.tab,
    required this.isActive,
    this.service,
    this.autoRefresh = true,
  });

  @override
  State<_HotListView> createState() => _HotListViewState();
}

class _HotListViewState extends State<_HotListView> {
  late final ShowService _service = widget.service ?? ShowService();
  final ScrollController _scroll = ScrollController();
  late final List<Genre> _genres = genresOf(widget.tab);
  late final List<FacetOption> _years = buildYears(DateTime.now().year);
  late SubChannel _channel = kChannels[widget.tab]!.first;
  FilterSelection _selection = const FilterSelection();

  /// 每种「榜单 / 筛选组合」缓存一份分页状态，切回来不用重新请求
  final Map<String, _LoadedPage> _cache = {};

  late PagedShowList _list = _listFor(_selection, _channel);
  Timer? _autoTimer;

  /// 上限：超过就丢掉最早缓存的（TabBarView 是常驻的，长期用会涨内存）
  static const int _maxCache = 12;

  String _cacheKeyOf(FilterSelection sel, SubChannel ch) =>
      sel.isAll ? 'ch:${ch.sourceId}' : 'f:${sel.key}';

  PagedShowList _listFor(FilterSelection sel, SubChannel ch) {
    final key = _cacheKeyOf(sel, ch);
    final cached = _cache[key];
    if (cached != null) return cached.list;
    final list = PagedShowList(loader: (start) {
      if (sel.isAll) {
        return _service.fetchHot(tab: widget.tab, channel: ch, start: start);
      }
      return _service.fetchFiltered(
        tab: widget.tab,
        selection: sel,
        start: start,
      );
    });
    _cache[key] = _LoadedPage(list);
    _trimCache(keepKey: key);
    // 新组合先拉第一页（不 await，UI 先转圈）
    list.reset();
    return list;
  }

  void _trimCache({required String keepKey}) {
    while (_cache.length > _maxCache) {
      final victim =
          _cache.keys.firstWhere((k) => k != keepKey, orElse: () => keepKey);
      if (victim == keepKey) return;
      _cache.remove(victim)?.list.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoRefresh) {
      // 每 10 分钟自动刷新当前可见页，保持「实时」
      _autoTimer = Timer.periodic(const Duration(minutes: 10), (_) {
        if (!widget.isActive()) return;
        final entry = _cache[_cacheKeyOf(_selection, _channel)];
        if (entry == null) return;
        if (DateTime.now().difference(entry.updatedAt).inMinutes < 5) return;
        entry.updatedAt = DateTime.now();
        entry.list.reset();
      });
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    for (final entry in _cache.values) {
      entry.list.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// 供首页 AppBar 刷新按钮调用
  void refresh() {
    final entry = _cache[_cacheKeyOf(_selection, _channel)];
    entry?.updatedAt = DateTime.now();
    (entry?.list ?? _list).reset();
  }

  void _apply(FilterSelection sel, {SubChannel? channel}) {
    final ch = channel ?? _channel;
    if (sel == _selection && ch == _channel) return;
    setState(() {
      _selection = sel;
      _channel = ch;
      _list = _listFor(sel, ch);
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _selectGenre(Genre g) => _apply(_selection.copyWith(genre: g));

  void _selectArea(FacetOption o) => _apply(_selection.copyWith(area: o));

  void _selectYear(FacetOption o) => _apply(_selection.copyWith(year: o));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final channels = kChannels[widget.tab]!;
    return Column(
      children: [
        if (_selection.isAll)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              children: [
                for (final c in channels)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c.label),
                      selected: c == _channel,
                      onSelected: (_) => _apply(_selection, channel: c),
                    ),
                  ),
              ],
            ),
          ),
        GenreBar(
          genres: _genres,
          selected: _selection.genre,
          onSelected: _selectGenre,
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              FacetMenu(
                label: '地区',
                options: kAreas,
                selected: _selection.area,
                onSelected: _selectArea,
              ),
              const SizedBox(width: 8),
              FacetMenu(
                label: '年份',
                options: _years,
                selected: _selection.year,
                onSelected: _selectYear,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _selection.isAll
                      ? '${_channel.label} · 全部类型'
                      // 筛选态会隐藏榜单行，这里带上前缀，避免丢掉「在看哪个榜」的上下文
                      : '正在看：${_selection.summary} · 来自「${_channel.label}」',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: PagedShowGrid(
            list: _list,
            controller: _scroll,
            // 走 refresh()：顺带更新 updatedAt，避免 10 分钟定时器刚下拉完又刷一次
            onRefresh: () async => refresh(),
            emptyMessage: _selection.isAll
                ? '榜单暂无数据'
                : '「${_selection.summary}」暂无内容，换个组合试试',
          ),
        ),
      ],
    );
  }
}
