import 'dart:async';

import 'package:flutter/material.dart';

import '../services/source_discovery.dart';
import '../services/source_store.dart';

/// 自动搜索采集站：从远程清单或粘贴的一批地址里并发探测，
/// 列出可用站点，由用户勾选后批量导入。
class SourceDiscoveryPage extends StatefulWidget {
  const SourceDiscoveryPage({super.key});

  @override
  State<SourceDiscoveryPage> createState() => _SourceDiscoveryPageState();
}

class _SourceDiscoveryPageState extends State<SourceDiscoveryPage> {
  final TextEditingController _catalogCtrl = TextEditingController();
  final Map<String, ProbeResult> _results = {};
  final Set<String> _selected = {};
  final Set<String> _addedNow = {};

  StreamSubscription<ProbeResult>? _sub;
  Completer<void>? _probeDone;
  List<SourceCandidate> _candidates = const [];
  bool _fetching = false;
  bool _probing = false;
  int _planned = 0;
  String? _notice;

  String _key(SourceCandidate c) => SourceDiscovery.normalizeApi(c.api);

  @override
  void initState() {
    super.initState();
    sourceStore.load();
    _catalogCtrl.text = sourceStore.catalogUrl;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _completeProbe();
    _catalogCtrl.dispose();
    super.dispose();
  }

  void _completeProbe() {
    final d = _probeDone;
    if (d != null && !d.isCompleted) d.complete();
  }

  // ------------------------------------------------------------ 流程

  /// 「开始自动搜索」：拉清单 + 并发探测。
  /// [catalogs] 传值时用指定清单（「找 4K/高清源」走这条），不覆盖用户填的地址。
  Future<void> _autoSearch({List<String>? catalogs}) async {
    final url = _catalogCtrl.text.trim();
    if (catalogs == null) await sourceStore.setCatalogUrl(url);
    // 用户没填地址时走内置源，做到「点一下就能搜」
    final urls = catalogs ??
        (url.isEmpty ? kDefaultCatalogUrls : <String>[url]);
    setState(() {
      _fetching = true;
      _notice = null;
      _results.clear();
      _selected.clear();
    });
    final res = await SourceDiscovery.instance.fetchCatalogs(urls);
    if (!mounted) return;
    setState(() {
      _fetching = false;
      _candidates = res.candidates;
      _notice = res.warnings.isEmpty ? null : res.warnings.join('；');
    });
    if (res.candidates.isEmpty) return;
    await _probe(res.candidates);
  }

  /// 手动粘贴一批地址后探测
  Future<void> _pasteAndSearch() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴候选地址'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 10,
                minLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '每行一个接口地址，例如：\n'
                      'https://example.com/api.php/provide/vod/\n'
                      '站点B | https://b.com/api.php/provide/vod/\n'
                      '# 井号开头是注释\n'
                      '也支持粘贴 JSON 数组或 TVBox 风格的配置',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '会并发探测每个地址，探测结果由你勾选后再导入。',
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('开始探测')),
        ],
      ),
    );
    ctrl.dispose();
    final content = text?.trim() ?? '';
    if (content.isEmpty) return;

    final candidates = SourceDiscovery.parseCatalog(content);
    if (candidates.isEmpty) {
      setState(() => _notice = '没有从这段文本里解析出可用的接口地址');
      return;
    }
    setState(() {
      _candidates = candidates;
      _notice = null;
      _results.clear();
      _selected.clear();
    });
    await _probe(candidates);
  }

  Future<void> _probe(List<SourceCandidate> candidates) async {
    await _sub?.cancel();
    _completeProbe();
    setState(() {
      _probing = true;
      _planned = candidates.length;
      _notice = null;
    });
    final existing = sourceStore.normalizedApis;
    final done = Completer<void>();
    _probeDone = done;
    _sub = SourceDiscovery.instance
        .probeAll(candidates, existing: existing)
        .listen((r) {
      if (!mounted) return;
      setState(() {
        _results[_key(r.candidate)] = r;
        if (r.usable) _selected.add(_key(r.candidate));
      });
    }, onDone: _completeProbe, onError: (Object _) => _completeProbe());
    await done.future;
    if (mounted) setState(() => _probing = false);
  }

  Future<void> _addSelected() async {
    final picked = _candidates
        .where((c) =>
            _selected.contains(_key(c)) &&
            (_results[_key(c)]?.usable ?? false))
        .toList();
    if (picked.isEmpty) return;
    final added = await sourceStore.addAll(picked);
    if (!mounted) return;
    for (final c in picked) {
      _addedNow.add(_key(c));
      _selected.remove(_key(c));
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(added > 0 ? '已添加 $added 个站点' : '这些站点都已存在'),
    ));
  }

  // ------------------------------------------------------------ 视图

  List<ProbeResult> get _sortedResults {
    final list = _results.values.toList()
      ..sort((a, b) {
        final ua = _isUsable(a) ? 0 : 1;
        final ub = _isUsable(b) ? 0 : 1;
        if (ua != ub) return ua - ub;
        if (ua == 0) return a.milliseconds.compareTo(b.milliseconds);
        return a.candidate.name.compareTo(b.candidate.name);
      });
    return list;
  }

  bool _isUsable(ProbeResult r) =>
      r.usable || (r.ok && _addedNow.contains(_key(r.candidate)));

  bool _isAdded(ProbeResult r) =>
      r.alreadyAdded || _addedNow.contains(_key(r.candidate));

  int get _usableCount => _results.values.where(_isUsable).length;

  int get _selectedCount => _selected
      .where((k) => _results[k]?.usable ?? false)
      .length;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('自动搜索采集站'),
        actions: [
          if (_candidates.isNotEmpty && !_probing && !_fetching)
            IconButton(
              tooltip: '重新探测',
              onPressed: () => _probe(_candidates),
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          _catalogCard(scheme),
          const SizedBox(height: 12),
          if (_notice != null) _noticeBox(_notice!, scheme),
          if (_fetching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_results.isNotEmpty || _probing) _statusRow(scheme),
          const SizedBox(height: 4),
          if (_results.isEmpty && !_probing && !_fetching) _emptyHint(scheme),
          for (final r in _sortedResults) _resultTile(r, scheme),
        ],
      ),
      bottomNavigationBar: _selectedCount == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed: _addSelected,
                  icon: const Icon(Icons.add_rounded),
                  label: Text('添加所选 $_selectedCount 个站点'),
                ),
              ),
            ),
    );
  }

  Widget _catalogCard(ColorScheme scheme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.travel_explore_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                const Text('候选清单来源',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _catalogCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '远程清单地址（留空即用内置源）',
                hintText: '留空自动搜索，或填 https://…/sites.json',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '留空时会自动使用内置源：${kDefaultCatalogUrls.join('、')}',
              style: TextStyle(fontSize: 11, color: scheme.primary),
            ),
            const SizedBox(height: 2),
            Text(
              '自己填地址则只用它；支持纯文本（每行一个地址）与 JSON（数组、{"sites":[…]}、TVBox 风格配置）。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _fetching || _probing ? null : _autoSearch,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('开始自动搜索'),
                ),
                OutlinedButton.icon(
                  onPressed: _fetching || _probing ? null : _pasteAndSearch,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('粘贴地址列表'),
                ),
                OutlinedButton.icon(
                  onPressed: _fetching || _probing
                      ? null
                      : () => _autoSearch(catalogs: kHdCatalogUrls),
                  icon: const Icon(Icons.hd_rounded, size: 18),
                  label: const Text('找 4K/高清源'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _noticeBox(String text, ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12, height: 1.5, color: scheme.error)),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (_probing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.check_circle_outline_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            _probing
                ? '正在探测 ${_results.length}/$_planned …'
                : '探测完成：$_planned 个地址，$_usableCount 个可用',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
      child: Column(
        children: [
          Icon(Icons.travel_explore_rounded, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          const Text('不用填任何地址，点「开始自动搜索」就能搜'),
          const SizedBox(height: 6),
          Text(
            '应用会拉取内置清单源、并发探测每个采集接口，\n列出可用/不可用，再由你勾选决定添加哪些。\n'
            '\n想找更清晰的片源？点下面的「找 4K/高清源」再搜一轮。\n'
            '想换成自己的清单，把地址填到上面即可。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(ProbeResult r, ColorScheme scheme) {
    final added = _isAdded(r);
    final usable = _isUsable(r);
    final key = _key(r.candidate);
    final selectable = r.usable && !added;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: CheckboxListTile(
        dense: true,
        value: selectable && _selected.contains(key),
        onChanged: selectable
            ? (v) => setState(() {
                  if (v == true) {
                    _selected.add(key);
                  } else {
                    _selected.remove(key);
                  }
                })
            : null,
        controlAffinity: ListTileControlAffinity.leading,
        title: Row(
          children: [
            Flexible(
              child: Text(
                r.candidate.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 6),
            _chip(
              added ? '已添加' : (usable ? '可用' : '不可用'),
              added
                  ? scheme.outline
                  : (usable ? Colors.green : scheme.error),
            ),
            if (usable && !added)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('${r.milliseconds}ms',
                    style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.candidate.api,
                  maxLines: 2,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              if (usable && r.itemCount > 0)
                Text('站点自报约 ${r.itemCount} 条数据',
                    style: TextStyle(fontSize: 11, color: scheme.primary)),
              if (!usable && !added && r.error != null)
                Text(r.error!, style: TextStyle(fontSize: 11, color: scheme.error)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );
}
