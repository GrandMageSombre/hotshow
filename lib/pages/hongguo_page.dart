import 'package:flutter/material.dart';

import '../models/media_resource.dart';
import '../services/hongguo_service.dart';
import '../widgets/common_views.dart';
import '../widgets/remote_image.dart';
import '../widgets/show_grid.dart';
import 'player_page.dart';
import 'web_grab_page.dart';

/// 红果短剧：官方网页版（hongguoduanju.com）的真人剧/漫剧/AI 剧列表 + 直接播放。
///
/// 网页版只有 360p（720p/1080p 均 404），这一点在页面顶部直接写清楚，
/// 免得用户以为是播放器没切清晰度。
class HongguoPage extends StatefulWidget {
  const HongguoPage({super.key});

  @override
  State<HongguoPage> createState() => _HongguoPageState();
}

class _HongguoPageState extends State<HongguoPage> {
  final HongguoService _service = HongguoService.instance;
  final ScrollController _scroll = ScrollController();
  final List<HongguoItem> _items = [];

  /// 当前榜单/分类：null 表示「热播榜」，否则是分类 path
  String? _channel;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  /// 每次切分类/重载 +1；回来的包如果不是当前代，直接丢弃。
  /// 否则「切到分类 B 时 A 的慢请求后到」会把 A 的结果拼到 B 列表后面，
  /// 并且把 `_loading` 卡在 true（历史上同类 bug 已有测试用例）。
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final left = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (left < 600) _loadMore();
  }

  Future<void> _reload() async {
    _epoch++;
    setState(() {
      _items.clear();
      _page = 1;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final myEpoch = _epoch;
    setState(() => _loading = true);
    try {
      final ch = _channel;
      final page = _page;
      // 榜单只有一页（HTML 卡片），分类才分页
      final batch = ch == null
          ? await _service.fetchHot()
          : await _service.fetchCategory(ch, page: page);
      if (!mounted || myEpoch != _epoch) return;
      setState(() {
        _items.addAll(batch.where((e) => !_items.any((o) => o.seriesId == e.seriesId)));
        _page = page + 1;
        _hasMore = ch != null && batch.length >= kHongguoPageSize;
        _loading = false;
        if (batch.isEmpty) _hasMore = false;
      });
    } catch (e) {
      if (!mounted || myEpoch != _epoch) return;
      setState(() {
        _loading = false;
        _error = _friendly(e);
        // 只停当页，不清 `_hasMore`：否则一次弱网抖动就再也翻不了页，
        // 用户只能退出重进。留一个「重试」入口更符合直觉。
      });
    }
  }

  void _switchChannel(String? ch) {
    if (ch == _channel) return;
    setState(() => _channel = ch);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _reload();
  }

  Future<void> _open(HongguoItem item) async {
    // 先把详情页的剧集表取出来；失败就直接提示，不跳空白播放器
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    MediaResource res;
    try {
      res = await _service.fetchDetail(item.seriesId, fallback: item);
    } catch (e) {
      if (mounted && route != null && route.isCurrent) navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('打开失败：${_friendly(e)}')));
      return;
    }
    // 用户可能已经用返回键把转圈弹窗关掉了；此时再 pop 会把本页也弹掉
    if (!mounted) return;
    if (route != null && route.isCurrent) navigator.pop();
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          resource: res,
          altTitles: [item.title],
        ),
      ),
    );
  }

  static String _friendly(Object e) {
    final s = e.toString();
    if (e is FormatException) return s.replaceFirst('FormatException: ', '');
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('红果短剧'),
        actions: [
          IconButton(
            tooltip: '输入网址抓取视频',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WebGrabPage()),
            ),
            icon: const Icon(Icons.travel_explore_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              children: [
                _chip('热播榜', null),
                for (final c in kHongguoChannels) _chip(c.label, c.path),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '来自红果网页版，免费无广告；网页只提供 360p（App 内同为 360p）',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _chip(String label, String? ch) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: _channel == ch,
          onSelected: (_) => _switchChannel(ch),
        ),
      );

  Widget _buildBody() {
    if (_items.isEmpty) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      if (_error != null) {
        return ErrorRetry(error: _error!, onRetry: _reload);
      }
      return EmptyHint(
        message: '「${_channel ?? '热播榜'}」暂无内容，换个分类试试',
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(ShowGridMetrics.horizontalPadding),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _tileExtent(context),
                mainAxisSpacing: ShowGridMetrics.mainAxisSpacing,
                crossAxisSpacing: ShowGridMetrics.spacing,
                childAspectRatio: ShowGridMetrics.posterAspectRatio / 1.45,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _HongguoTile(
                  item: _items[i],
                  onTap: () => _open(_items[i]),
                ),
                childCount: _items.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 28),
              child: Center(
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _error != null
                        // 列表已经有内容时翻页失败：就地给重试，不整页清空
                        ? TextButton.icon(
                            onPressed: () {
                              setState(() => _error = null);
                              _loadMore();
                            },
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text('加载失败，点这里重试'),
                          )
                        : Text(
                            _hasMore ? '' : '已经到底了',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 短剧封面是 9:16 竖屏，格子比竖版海报更方一些
  double _tileExtent(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (width / 3).clamp(110.0, 150.0);
  }
}

class _HongguoTile extends StatelessWidget {
  final HongguoItem item;
  final VoidCallback onTap;

  const _HongguoTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final cacheWidth = box.maxWidth.isFinite
                  ? (box.maxWidth * dpr).round()
                  : null;
              return Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: RemoteImage(
                        url: item.cover,
                        cacheWidth: cacheWidth,
                        placeholder: (_) => Container(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(Icons.theaters_outlined,
                              color: scheme.outlineVariant),
                        ),
                      ),
                    ),
                  ),
                  if (item.episodeCount > 0)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.68),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '全${item.episodeCount}集',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ),
                ],
              );
            }),
          ),
          const SizedBox(height: ShowGridMetrics.coverTextGap),
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: ShowGridMetrics.titleFontSize,
              height: ShowGridMetrics.lineHeightFactor,
            ),
          ),
          if (item.subtitle.isNotEmpty)
            Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: ShowGridMetrics.subtitleFontSize,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
