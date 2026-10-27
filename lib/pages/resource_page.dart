import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_resource.dart';
import '../models/show_item.dart';
import '../services/offline_cache.dart';
import '../services/playback_store.dart';
import '../services/resource_service.dart';
import '../services/source_store.dart';
import '../widgets/common_views.dart';
import '../widgets/remote_image.dart';
import 'player_page.dart';
import 'site_settings_page.dart';
import 'source_discovery_page.dart';

/// 资源检索页：拿豆瓣的片名到各采集站检索「完整资源」（全部线路 / 全部集数），
/// 选中后进入播放页。
class ResourcePage extends StatefulWidget {
  final ShowItem item;
  final String? year;

  /// 豆瓣别名，作为字幕搜索的片名候选
  final List<String> altTitles;

  const ResourcePage({
    super.key,
    required this.item,
    this.year,
    this.altTitles = const [],
  });

  @override
  State<ResourcePage> createState() => _ResourcePageState();
}

class _ResourcePageState extends State<ResourcePage> {
  final Map<String, SiteSearchResult> _bySite = {};
  StreamSubscription<SiteSearchResult>? _sub;
  late String _keyword = widget.item.title;
  bool _loading = false;
  int _siteCount = 0;

  /// 采集站资源类型筛选（空串 = 全部）
  String _typeFilter = '';

  /// 排序结果缓存：站点结果每来一批就失效一次，避免每个 build 重排全量
  List<MediaResource>? _rankedCache;

  @override
  void initState() {
    super.initState();
    _siteCount = sourceStore.enabledSites.length;
    offlineCache.addListener(_onCacheChanged);
    _search();
  }

  @override
  void dispose() {
    _sub?.cancel();
    offlineCache.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    setState(() => _rankedCache = null);
  }

  void _search() {
    _sub?.cancel();
    final sites = sourceStore.enabledSites;
    setState(() {
      _bySite.clear();
      _rankedCache = null;
      _loading = sites.isNotEmpty;
      _siteCount = sites.length;
      _typeFilter = '';
    });
    _sub = ResourceService.instance.searchAll(sites, _keyword).listen((r) {
      if (!mounted) return;
      setState(() {
        _bySite[r.site.id] = r;
        _rankedCache = null;
      });
    });
  }

  /// 全部命中资源，按片名匹配度排序（带缓存）
  List<MediaResource> get _ranked => _rankedCache ??= rankResources(
        _bySite.values.expand((r) => r.items),
        _keyword,
        year: widget.year,
      );

  /// 采集站返回的资源类型（去重、稳定顺序），用于类型筛选条
  List<String> _typesOf(List<MediaResource> all) {
    final seen = <String>[];
    for (final r in all) {
      final t = r.typeName.trim();
      if (t.isNotEmpty && !seen.contains(t)) seen.add(t);
    }
    return seen;
  }

  int get _okSites => _bySite.values.where((r) => r.ok).length;

  List<SiteSearchResult> get _failures =>
      _bySite.values.where((r) => !r.ok).toList();

  Future<void> _editKeyword() async {
    final ctrl = TextEditingController(text: _keyword);
    final kw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('检索关键词'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '站点里的片名可能与豆瓣略有不同',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('重新检索')),
        ],
      ),
    );
    ctrl.dispose();
    final v = kw?.trim() ?? '';
    if (v.isEmpty || v == _keyword) return;
    setState(() => _keyword = v);
    _search();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SiteSettingsPage()),
    );
    if (!mounted) return;
    setState(() => _siteCount = sourceStore.enabledSites.length);
    if (_siteCount > 0 && _bySite.isEmpty) _search();
  }

  Future<void> _openDiscovery() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceDiscoveryPage()),
    );
    if (!mounted) return;
    final before = _siteCount;
    setState(() => _siteCount = sourceStore.enabledSites.length);
    if (_siteCount != before) _search();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '修改检索关键词',
            onPressed: _editKeyword,
            icon: const Icon(Icons.manage_search_rounded),
          ),
          IconButton(
            tooltip: '采集站设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.dns_rounded),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (sourceStore.sites.isEmpty) {
      return _NeedSites(onSettings: _openSettings, onDiscovery: _openDiscovery);
    }

    // 排序只做一次：_ranked 内部是排序+去重，反复调用在资源多时会有可感开销
    final all = _ranked;
    final list = _typeFilter.isEmpty
        ? all
        : all.where((r) => r.typeName.trim() == _typeFilter).toList();
    final failures = _failures;
    final types = _typesOf(all);

    return RefreshIndicator(
      onRefresh: () async => _search(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _statusBar(failures),
          if (types.length > 1) _typeBar(types),
          if (list.isEmpty && _loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: EmptyHint(
                message: all.isEmpty
                    ? '各站点都没有找到「$_keyword」的资源\n可试试右上角换个关键词'
                    : '「$_typeFilter」类型下没有资源，可切回全部',
              ),
            )
          else
            for (final r in list) _resourceCard(r),
        ],
      ),
    );
  }

  /// 按采集站返回的 type_name 做二级筛选（动作片 / 喜剧片 / 动漫 …）
  Widget _typeBar(List<String> types) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 38,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Icon(Icons.category_outlined,
                        size: 15, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text('类型',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            for (final t in ['', ...types])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(t.isEmpty ? '全部' : t),
                  selected: _typeFilter == t,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelStyle: const TextStyle(fontSize: 12),
                  onSelected: (_) => setState(() => _typeFilter = t),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusBar(List<SiteSearchResult> failures) {
    final scheme = Theme.of(context).colorScheme;
    final done = _bySite.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(Icons.check_circle_outline_rounded,
                    size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                _loading
                    ? '已检索 $done/$_siteCount 个站点…'
                    : '已检索 $_siteCount 个站点，$_okSites 个有结果',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              Text('关键词：$_keyword',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          if (failures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                failures.map((f) => '${f.site.name}：${f.error}').join('；'),
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resourceCard(MediaResource r) {
    final scheme = Theme.of(context).colorScheme;
    final group = r.defaultGroup;
    final record = playbackStore.of(r.key);
    final cachedCount = offlineCache.countFor(r.siteId, r.vodId);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: group == null
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlayerPage(
                      resource: r,
                      altTitles: widget.altTitles,
                    ),
                  ),
                ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 76,
                  height: 106,
                  child: RemoteImage(
                    url: r.cover,
                    cacheWidth:
                        (76 * MediaQuery.devicePixelRatioOf(context)).round(),
                    placeholder: (_) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: const Icon(Icons.movie_outlined),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _tag(r.siteName, scheme.primary),
                        if (r.remarks.isNotEmpty) _tag(r.remarks, scheme.tertiary),
                        if (r.year.isNotEmpty) _tag(r.year, scheme.outline),
                        if (r.typeName.isNotEmpty)
                          _tag(r.typeName, scheme.outline),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${r.groups.length} 条线路 · 共 ${r.episodeCount} 集'
                      '${r.area.isEmpty ? '' : ' · ${r.area}'}'
                      '${cachedCount > 0 ? ' · 已缓存 $cachedCount 集' : ''}',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                    if (record != null && !record.finished)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '上次看到 ${record.episodeName} ${record.positionText}',
                          style: TextStyle(fontSize: 11, color: scheme.primary),
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.play_circle_fill_rounded, size: 30),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );
}

class _NeedSites extends StatelessWidget {
  final Future<void> Function() onSettings;
  final Future<void> Function() onDiscovery;
  const _NeedSites({required this.onSettings, required this.onDiscovery});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_rounded,
                size: 46, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 14),
            const Text('还没有配置采集站', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(
              '本应用不内置任何影视站点。可以让它自动搜索一批候选接口，\n或手动填一个 maccms 采集接口地址。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onDiscovery,
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('自动搜索采集站'),
                ),
                OutlinedButton.icon(
                  onPressed: onSettings,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('手动添加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
