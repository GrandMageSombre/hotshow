import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/source_site.dart';
import 'source_discovery.dart';

/// 站点配置的本地持久化（Android 应用私有目录 / Windows 用户配置目录）。
/// 默认列表为空，采集接口地址由使用者自行添加，工程内不内置任何第三方站点。
class SourceStore extends ChangeNotifier {
  static const _kSites = 'source_sites';
  static const _kCatalog = 'source_catalog_url';

  final List<SourceSite> sites = [];

  /// 「自动搜索采集站」使用的远程清单地址（JSON 或纯文本），默认空
  String catalogUrl = '';

  bool _loaded = false;

  /// 已启用的站点（按配置顺序）
  List<SourceSite> get enabledSites => sites.where((s) => s.enabled).toList();

  /// 已配置站点的去重键集合，用于自动搜索时标记「已添加」
  Set<String> get normalizedApis =>
      sites.map((s) => SourceDiscovery.normalizeApi(s.api)).toSet();

  bool get isEmpty => sites.isEmpty;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    catalogUrl = sp.getString(_kCatalog) ?? '';
    sites
      ..clear()
      ..addAll((sp.getStringList(_kSites) ?? const [])
          .map((s) => jsonDecode(s))
          .whereType<Map<String, dynamic>>()
          .map(SourceSite.fromJson)
          .where((s) => s.api.isNotEmpty));
    notifyListeners();
  }

  Future<void> setCatalogUrl(String url) async {
    catalogUrl = url.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCatalog, catalogUrl);
    notifyListeners();
  }

  /// 批量导入（自动搜索勾选后调用），返回实际新增数量
  Future<int> addAll(List<SourceCandidate> candidates) async {
    final existing = normalizedApis;
    var added = 0;
    for (final c in candidates) {
      if (!SourceSite.isValidApi(c.api)) continue;
      if (!existing.add(SourceDiscovery.normalizeApi(c.api))) continue;
      sites.add(SourceSite(
        id: 'site_${DateTime.now().microsecondsSinceEpoch}_$added',
        name: c.name.trim().isEmpty
            ? Uri.parse(c.api).host
            : c.name.trim(),
        api: c.api.trim(),
      ));
      added++;
    }
    if (added > 0) await _persist();
    return added;
  }

  Future<void> _persist() async {
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
        _kSites, sites.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<SourceSite> add({
    required String name,
    required String api,
    String searchAction = 'detail',
  }) async {
    final site = SourceSite(
      id: 'site_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      api: api.trim(),
      searchAction: searchAction,
    );
    sites.add(site);
    await _persist();
    return site;
  }

  Future<void> update(SourceSite site) async {
    final i = sites.indexWhere((s) => s.id == site.id);
    if (i < 0) return;
    sites[i] = site;
    await _persist();
  }

  Future<void> remove(String id) async {
    sites.removeWhere((s) => s.id == id);
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = sites.indexWhere((s) => s.id == id);
    if (i < 0) return;
    sites[i] = sites[i].copyWith(enabled: enabled);
    await _persist();
  }
}

/// 全局单例，与 HistoryStore 保持一致的用法
final SourceStore sourceStore = SourceStore();
