import 'dart:async';

import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../services/show_service.dart';
import '../widgets/common_views.dart';
import '../widgets/show_card.dart';
import '../widgets/show_grid.dart';

class HomePage extends StatefulWidget {
  final ShowService? service;
  final bool autoRefresh;
  const HomePage({super.key, this.service, this.autoRefresh = true});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: HotTab.values.length, vsync: this);
  final List<GlobalKey<_HotListViewState>> _listKeys =
      HotTab.values.map((t) => GlobalKey<_HotListViewState>()).toList();

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _refreshCurrent() {
    final i = _tab.index;
    _listKeys[i].currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('热剧速览'),
        centerTitle: false,
        actions: [
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

class _ChannelData {
  List<ShowItem> items = [];
  bool loading = false;
  Object? error;
  int start = 0;
  bool hasMore = true;
  DateTime updatedAt = DateTime.now();
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
  final Map<String, _ChannelData> _cache = {};
  late SubChannel _channel = kChannels[widget.tab]!.first;
  Timer? _autoTimer;

  _ChannelData get _data =>
      _cache.putIfAbsent(_channel.sourceId, () => _ChannelData());

  @override
  void initState() {
    super.initState();
    _load(force: true);
    _scroll.addListener(_onScroll);
    if (widget.autoRefresh) {
      // 每 10 分钟自动刷新当前可见榜单，保持“实时”
      _autoTimer = Timer.periodic(const Duration(minutes: 10), (_) {
        if (widget.isActive() &&
            DateTime.now().difference(_data.updatedAt).inMinutes >= 5) {
          _load(force: true);
        }
      });
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  /// 供首页 AppBar 刷新按钮调用
  void refresh() => _load(force: true);

  Future<void> _load({bool force = false}) async {
    final d = _data;
    if (d.loading) return;
    setState(() {
      d
        ..loading = true
        ..error = null;
      if (force) {
        d
          ..items = []
          ..start = 0
          ..hasMore = true;
      }
    });
    try {
      final list = await _service.fetchHot(
        tab: widget.tab,
        channel: _channel,
        start: d.start,
      );
      if (!mounted) return;
      setState(() {
        d
          ..loading = false
          ..items = force ? list : [...d.items, ...list]
          ..start = d.start + list.length
          ..hasMore = list.length >= 10
          ..updatedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        d
          ..loading = false
          ..error = e
          ..hasMore = false;
      });
    }
  }

  void _loadMore() {
    final d = _data;
    if (d.loading || !d.hasMore || d.error != null || d.items.isEmpty) return;
    _load();
  }

  void _switchChannel(SubChannel c) {
    if (c == _channel) return;
    setState(() => _channel = c);
    final d = _data;
    if (d.items.isEmpty && d.error == null && !d.loading) {
      _load(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            children: [
              for (final c in kChannels[widget.tab]!)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c.label),
                    selected: c == _channel,
                    onSelected: (_) => _switchChannel(c),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => _load(force: true),
            child: _buildBody(d),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(_ChannelData d) {
    if (d.error != null && d.items.isEmpty) {
      return ErrorRetry(error: d.error, onRetry: () => _load(force: true));
    }
    if (d.items.isEmpty && d.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!d.loading && d.items.isEmpty) {
      return const EmptyHint(message: '榜单暂无数据');
    }
    return LayoutBuilder(builder: (context, box) {
      final metrics = ShowGridMetrics.resolve(
        availableWidth:
            box.maxWidth - ShowGridMetrics.horizontalPadding * 2,
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
        itemCount: d.items.length + 1,
        itemBuilder: (context, i) {
          if (i >= d.items.length) {
            return ListTail(hasMore: d.hasMore || d.loading);
          }
          return ShowCard(item: d.items[i]);
        },
      );
    });
  }
}
