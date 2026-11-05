import 'package:flutter/material.dart';

import '../services/live_catalog.dart';
import '../widgets/common_views.dart';
import '../widgets/remote_image.dart';
import 'player_page.dart';

/// 电视直播：4 个分类（央视 / 地方 / 国外 / 体育）的精选台。
///
/// 频道目录是**内置**的（`assets/live_channels.json`），不是运行时从网上现拉——
/// 之前那版拉 7 份公开 m3u 合并，实测 2663 条里只有 24% 能播，用户点十个台
/// 有七八个转圈。现在目录里每个台都跑过「主列表 + 第一个分片都要拉得回来」，
/// 且保留了备用地址：主地址失效时在播放器里能直接切线路。
class LivePage extends StatefulWidget {
  /// 供测试注入（默认从 assets 读）
  final LiveCatalog? catalog;

  const LivePage({super.key, this.catalog});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> with SingleTickerProviderStateMixin {
  LiveCatalog? _catalog;
  Object? _error;
  bool _loading = true;

  TabController? _tab;
  String _keyword = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.catalog != null) {
      _install(widget.catalog!);
    } else {
      _load();
    }
  }

  void _install(LiveCatalog c) {
    _catalog = c;
    _loading = false;
    _tab?.dispose();
    // 第一个 Tab 是「全部」，方便跨分类搜台
    _tab = TabController(length: c.tabGroups.length, vsync: this);
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await LiveCatalog.load();
      if (!mounted) return;
      _install(c);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _tab?.dispose();
    _search.dispose();
    super.dispose();
  }

  void _play(LiveChannel c) {
    if (c.urls.isEmpty) {
      _toast('${c.name} 没有可用地址');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          resource: c.toResource(),
          resume: false,
          isLive: true,
          extraHeaders: c.playHeaders ?? const {},
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 当前关键词过滤后的某个分类
  List<LiveChannel> _filtered(LiveGroup g) => g.search(_keyword);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cat = _catalog;
    final tabs = cat?.tabGroups ?? const <LiveGroup>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('电视直播'),
        bottom: cat == null
            ? null
            : TabBar(
                controller: _tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final g in tabs)
                    Tab(
                      height: 42,
                      text: '${g.name} ${g.channels.length}',
                    ),
                ],
              ),
      ),
      body: _body(scheme, tabs),
    );
  }

  Widget _body(ColorScheme scheme, List<LiveGroup> tabs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ErrorRetry(error: _error, onRetry: _load);
    }
    return Column(
      children: [
        _searchBar(scheme),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              for (final g in tabs) _grid(scheme, g),
            ],
          ),
        ),
      ],
    );
  }

  Widget _searchBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _keyword = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜台名，如 CCTV5、湖南、NBA',
          hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
          prefixIcon: const Icon(Icons.search_rounded, size: 19),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 32),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 17),
                  onPressed: () {
                    _search.clear();
                    setState(() => _keyword = '');
                  },
                ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _grid(ColorScheme scheme, LiveGroup g) {
    final list = _filtered(g);
    if (list.isEmpty) {
      return EmptyHint(
        message: _keyword.trim().isEmpty
            ? '这个分类暂时没有台'
            : '「${_keyword.trim()}」没有匹配的台\n换个说法，比如 CCTV5、湖南、NBA',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 96,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _channelCard(scheme, list[i]),
    );
  }

  Widget _channelCard(ColorScheme scheme, LiveChannel c) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _play(c),
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: c.logo.isEmpty
                  ? _logoFallback(scheme, c.name)
                  : RemoteImage(
                      url: c.logo,
                      fit: BoxFit.contain,
                      // 卡片里只有 90×56 左右，按原图解码白吃流量
                      cacheWidth: 180,
                      placeholder: (_) => _logoFallback(scheme, c.name),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            c.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.2),
          ),
        ],
      ),
    );
  }

  Widget _logoFallback(ColorScheme scheme, String name) {
    return Center(
      child: Text(
        name.isEmpty ? '台' : name.substring(0, 1),
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.outline,
        ),
      ),
    );
  }
}
