import 'package:flutter/material.dart';

import '../models/source_site.dart';
import '../services/resource_service.dart';
import '../services/source_store.dart';
import 'source_discovery_page.dart';

/// 采集站管理：添加 / 编辑 / 启停 / 删除 / 连通性测试。
///
/// 本工程不内置任何第三方站点，接口地址由使用者自行填写。
class SiteSettingsPage extends StatefulWidget {
  const SiteSettingsPage({super.key});

  @override
  State<SiteSettingsPage> createState() => _SiteSettingsPageState();
}

class _SiteSettingsPageState extends State<SiteSettingsPage> {
  final Set<String> _testing = {};

  @override
  void initState() {
    super.initState();
    sourceStore.load();
    sourceStore.addListener(_onChanged);
  }

  @override
  void dispose() {
    sourceStore.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _edit({SourceSite? site}) async {
    final result = await showDialog<_SiteFormResult>(
      context: context,
      builder: (_) => _SiteFormDialog(site: site),
    );
    if (result == null) return;
    if (site == null) {
      await sourceStore.add(
        name: result.name,
        api: result.api,
        searchAction: result.action,
      );
    } else {
      await sourceStore.update(site.copyWith(
        name: result.name,
        api: result.api,
        searchAction: result.action,
      ));
    }
  }

  Future<void> _test(SourceSite site) async {
    setState(() => _testing.add(site.id));
    final err = await ResourceService.instance.ping(site);
    if (!mounted) return;
    setState(() => _testing.remove(site.id));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err == null ? '「${site.name}」连接正常' : '「${site.name}」：$err'),
    ));
  }

  Future<void> _confirmDelete(SourceSite site) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除站点'),
        content: Text('确定删除「${site.name}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await sourceStore.remove(site.id);
  }

  Future<void> _openDiscovery() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SourceDiscoveryPage()),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sites = sourceStore.sites;
    return Scaffold(
      appBar: AppBar(
        title: const Text('采集站设置'),
        actions: [
          IconButton(
            tooltip: '自动搜索采集站',
            onPressed: _openDiscovery,
            icon: const Icon(Icons.travel_explore_rounded),
          ),
          IconButton(
            tooltip: '添加站点',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '填入影视采集接口地址（maccms / 苹果CMS 的 api.php/provide/vod 形式），'
                    '应用会按片名到各站点检索完整剧集列表并播放。\n'
                    '接口可用性、内容来源与版权均由使用者自行确认。',
                    style: TextStyle(
                        fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text('还没有采集站，点右上角「+」添加',
                    style: TextStyle(fontSize: 13)),
              ),
            )
          else
            for (final s in sites)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  leading: Switch(
                    value: s.enabled,
                    onChanged: (v) => sourceStore.setEnabled(s.id, v),
                  ),
                  title: Text(s.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${s.api}\n动作：ac=${s.searchAction}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_testing.contains(s.id))
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          tooltip: '测试连接',
                          icon: const Icon(Icons.network_check_rounded, size: 20),
                          onPressed: () => _test(s),
                        ),
                      IconButton(
                        tooltip: '编辑',
                        icon: const Icon(Icons.edit_rounded, size: 20),
                        onPressed: () => _edit(site: s),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline_rounded, size: 20),
                        onPressed: () => _confirmDelete(s),
                      ),
                    ],
                  ),
                  onTap: () => _edit(site: s),
                ),
              ),
        ],
      ),
    );
  }
}

class _SiteFormResult {
  final String name;
  final String api;
  final String action;
  const _SiteFormResult(this.name, this.api, this.action);
}

class _SiteFormDialog extends StatefulWidget {
  final SourceSite? site;
  const _SiteFormDialog({this.site});

  @override
  State<_SiteFormDialog> createState() => _SiteFormDialogState();
}

class _SiteFormDialogState extends State<_SiteFormDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.site?.name ?? '');
  late final TextEditingController _api =
      TextEditingController(text: widget.site?.api ?? '');
  late String _action = widget.site?.searchAction ?? 'detail';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final api = _api.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写站点名称');
      return;
    }
    if (!SourceSite.isValidApi(api)) {
      setState(() => _error = '请填写以 http:// 或 https:// 开头的接口地址');
      return;
    }
    Navigator.pop(context, _SiteFormResult(name, api, _action));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.site == null ? '添加采集站' : '编辑采集站'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例：站点 A',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _api,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '采集接口地址',
                hintText: 'https://example.com/api.php/provide/vod/',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _action,
              decoration: const InputDecoration(labelText: '列表动作 ac'),
              items: const [
                DropdownMenuItem(value: 'detail', child: Text('detail（推荐）')),
                DropdownMenuItem(value: 'list', child: Text('list')),
                DropdownMenuItem(value: 'videolist', child: Text('videolist')),
              ],
              onChanged: (v) => setState(() => _action = v ?? 'detail'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: TextStyle(
                        fontSize: 12, color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
