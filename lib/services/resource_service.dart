import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_resource.dart';
import '../models/source_site.dart';
import 'api_client.dart';

/// 单个站点的搜索产出（成功给 items，失败给 error，互不干扰）
class SiteSearchResult {
  final SourceSite site;
  final List<MediaResource> items;
  final String? error;

  const SiteSearchResult({required this.site, this.items = const [], this.error});

  bool get ok => error == null;
  bool get isEmpty => items.isEmpty;

  @override
  String toString() => 'SiteSearchResult(${site.name}, ${items.length}条, err=$error)';
}

/// 采集站资源检索层：按片名到各站点搜索，并归一化 / 排序。
/// 不依赖 Flutter，可在纯 Dart 环境下运行（见 tool/source_check.dart）。
class ResourceService {
  static final ResourceService instance = ResourceService._();

  final HttpClient _http;

  ResourceService._()
      : _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 12)
          ..autoUncompress = true;

  /// 供测试注入自定义客户端
  ResourceService.withClient(this._http);

  /// 在单个站点搜索关键词，返回「完整资源」（含各线路全部集数的播放地址）
  Future<SiteSearchResult> searchSite(SourceSite site, String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return SiteSearchResult(site: site, error: '关键词为空');
    try {
      final json = await _getJson(site.buildSearchUri(kw));
      return SiteSearchResult(site: site, items: _parseList(json, site));
    } catch (e) {
      return SiteSearchResult(site: site, error: _friendly(e));
    }
  }

  /// 按 `ac=detail&ids=` 精确取一批资源（用于刷新某条的播放地址）
  Future<SiteSearchResult> fetchByIds(SourceSite site, List<String> ids) async {
    if (ids.isEmpty) return SiteSearchResult(site: site, error: '缺少资源 id');
    try {
      final json = await _getJson(site.buildDetailUri(ids.join(',')));
      final list = _parseList(json, site);
      if (list.isEmpty) {
        return SiteSearchResult(site: site, error: '站点未返回该资源');
      }
      return SiteSearchResult(site: site, items: list);
    } catch (e) {
      return SiteSearchResult(site: site, error: _friendly(e));
    }
  }

  /// 站点连通性自检（用例：站点设置页「测试」按钮）
  Future<String?> ping(SourceSite site) async {
    try {
      final json = await _getJson(site.buildSearchUri('测试', action: 'list'));
      final code = json['code'];
      if (code != null && code.toString() != '1') {
        final msg = json['msg']?.toString() ?? '';
        return '接口返回 code=$code${msg.isEmpty ? '' : '（$msg）'}';
      }
      if (json['list'] is! List) return '返回数据缺少 list 字段，可能不是 maccms 采集接口';
      return null;
    } catch (e) {
      return _friendly(e);
    }
  }

  /// 并发搜索全部启用站点，按「先返回先推送」的顺序流式产出结果。
  Stream<SiteSearchResult> searchAll(
      List<SourceSite> sites, String keyword) {
    final ctrl = StreamController<SiteSearchResult>();
    final targets = sites.where((s) => s.enabled).toList();
    if (targets.isEmpty) {
      ctrl.add(SiteSearchResult(
        site: const SourceSite(id: 'none', name: '未配置站点', api: ''),
        error: '尚未配置采集站，请先在「站点设置」中添加',
      ));
      ctrl.close();
      return ctrl.stream;
    }

    var remaining = targets.length;
    for (final site in targets) {
      searchSite(site, keyword).then((r) {
        if (!ctrl.isClosed) ctrl.add(r);
      }).catchError((Object e) {
        if (!ctrl.isClosed) {
          ctrl.add(SiteSearchResult(site: site, error: _friendly(e)));
        }
      }).whenComplete(() {
        remaining--;
        if (remaining == 0 && !ctrl.isClosed) ctrl.close();
      });
    }
    return ctrl.stream;
  }

  List<MediaResource> _parseList(Map<String, dynamic> json, SourceSite site) {
    final code = json['code'];
    if (code != null && code.toString() != '1') {
      final msg = json['msg']?.toString() ?? '';
      throw ApiException('站点返回 code=$code${msg.isEmpty ? '' : '：$msg'}');
    }
    final raw = json['list'];
    if (raw is! List) throw ApiException('站点返回数据格式异常（缺少 list）');
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) => MediaResource.fromMaccmsJson(
              e,
              siteId: site.id,
              siteName: site.name,
            ))
        .where((r) => r.playable && r.title.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final body = await _getText(uri);
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw ApiException('返回内容不是 JSON，请确认接口地址是 maccms 采集接口');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('返回 JSON 结构异常');
    }
    return decoded;
  }

  Future<String> _getText(Uri uri) async {
    final bytes = await _getBytes(uri);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<int>> _getBytes(Uri uri, {Map<String, String>? headers}) async {
    final req = await _http.getUrl(uri);
    headers?.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await resp.fold<List<int>>(
        <int>[], (a, b) => a..addAll(b));
    if (resp.statusCode != 200) {
      throw ApiException('站点返回 HTTP ${resp.statusCode}');
    }
    return bytes;
  }

  void close() => _http.close();
}

String _friendly(Object e) {
  if (e is ApiException) return e.message;
  if (e is TimeoutException) return '连接超时';
  if (e is SocketException) return '无法连接（域名解析或端口不通）';
  if (e is HandshakeException) return 'HTTPS 证书校验失败';
  if (e is HttpException) return '网络请求失败';
  return e.toString();
}

/// 把网络异常转成用户可读的中文提示（采集站发现页也复用）
String describeNetworkError(Object e) => _friendly(e);

/// 片名规范化：去掉《》、括号说明、季数后缀、空白与常见分隔符
String normalizeTitle(String s) {
  var t = s
      .replaceAll(RegExp(r'''[《》〈〉“”"'（）()【】\[\]]'''), '')
      .replaceAll(RegExp(r'(第[一二三四五六七八九十百\d]+季|season\s*\d+|s\d{1,2}\b)', caseSensitive: false), '')
      .replaceAll(RegExp(r'[\s·．.\-_/\\|,，、:：!！?？]'), '');
  return t.toLowerCase();
}

/// 资源与查询片名的匹配度（0 表示不相关）
double titleScore(String resourceTitle, String query) {
  final r = normalizeTitle(resourceTitle);
  final q = normalizeTitle(query);
  if (r.isEmpty || q.isEmpty) return 0;
  if (r == q) return 1;
  if (r.startsWith(q) || r.endsWith(q)) {
    return 0.75 + 0.25 * (q.length / r.length);
  }
  if (r.contains(q)) return 0.6 + 0.25 * (q.length / r.length);
  if (q.contains(r)) return 0.4 * (r.length / q.length);
  return 0;
}

/// 把多站结果按匹配度排序：同名词条优先，其次集数多、年份相符者优先。
List<MediaResource> rankResources(
  Iterable<MediaResource> list,
  String query, {
  String? year,
}) {
  final scored = <({MediaResource r, double s})>[];
  for (final r in list) {
    var s = titleScore(r.title, query);
    if (s <= 0) continue;
    // 年份相符（双方都有值）作为加权，避免把老版同名剧排前面
    final y = (year ?? '').trim();
    if (y.isNotEmpty && r.year.isNotEmpty) {
      if (r.year.contains(y) || y.contains(r.year)) {
        s += 0.15;
      } else {
        s -= 0.15;
      }
    }
    s += (r.episodeCount.clamp(0, 100)) * 0.0005;
    scored.add((r: r, s: s));
  }
  scored.sort((a, b) => b.s.compareTo(a.s));
  return scored.map((e) => e.r).toList();
}
