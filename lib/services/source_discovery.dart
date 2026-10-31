import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/source_site.dart';
import 'api_client.dart';
import 'remote_ua.dart';
import 'resource_service.dart';

/// 一个待探测的候选采集站
class SourceCandidate {
  final String name;
  final String api;

  const SourceCandidate({required this.name, required this.api});

  Map<String, dynamic> toJson() => {'name': name, 'api': api};

  @override
  String toString() => 'SourceCandidate($name, $api)';
}

/// 清单解析结果
class CatalogParseResult {
  final List<SourceCandidate> candidates;
  final List<String> warnings;

  const CatalogParseResult({this.candidates = const [], this.warnings = const []});
}

/// 单个候选站点的探测结果
class ProbeResult {
  final SourceCandidate candidate;

  /// 接口可用（能返回 maccms 结构的列表数据）
  final bool ok;
  final int milliseconds;

  /// 站点自报的数据量（total）
  final int itemCount;
  final String? error;

  /// 该站点已在应用里配置过
  final bool alreadyAdded;

  const ProbeResult({
    required this.candidate,
    this.ok = false,
    this.milliseconds = 0,
    this.itemCount = 0,
    this.error,
    this.alreadyAdded = false,
  });

  bool get usable => ok && !alreadyAdded;
}

/// 内置的公开候选清单源（第三方公开分发的 TVBox / 采集站配置）。
///
/// 应用只对它们做「拉取 + 解析 + 探测」，工程里不写死任何具体影视站点；
/// 想换成自己的清单，在「自动搜索采集站」页面填上地址即可覆盖内置源。
const List<String> kDefaultCatalogUrls = [
  // 走 jsDelivr，国内一般可直连
  'https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json',
];

/// 「高清/4K 向」的公开清单（TVBox 生态里流传的 4K 配置）。
///
/// 这些地址连通性因网络而异，所以**不当成默认源**，只在用户主动点「找 4K/高清源」时试；
/// 拉不到就跳过，能拉到的仍然走同一套「并发探测 + 手动勾选」流程，不会盲加。
const List<String> kHdCatalogUrls = [
  'https://cdn.jsdelivr.net/gh/keluo8824-cell/tvbox@main/4k.json',
  'https://cdn.jsdelivr.net/gh/gaotianliuyun/gao@master/0821.json',
];


/// 采集站自动发现：解析候选清单（远程 JSON / 纯文本 / 手动粘贴），
/// 并发探测可用性，供用户勾选后导入。
class SourceDiscovery {
  static final SourceDiscovery instance = SourceDiscovery._();

  final HttpClient _http;

  SourceDiscovery._()
      : _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..autoUncompress = true;

  /// 供测试注入独立客户端
  SourceDiscovery.withClient(this._http);

  // ------------------------------------------------------------ 清单解析

  /// 拉取远程清单并解析。支持：
  /// - 纯文本：每行一个接口地址，可写 `站点名 | 地址`，`#` 开头为注释
  /// - JSON 数组：`["https://…/api.php/provide/vod"]` 或 `[{"name":…,"api":…}]`
  /// - JSON 对象：`{"sites":[…]}` / `{"list":[…]}` 等（含 TVBox 风格配置，
  ///   会从 `ext` 里的 `site` 字段还原出 maccms 接口地址）
  Future<CatalogParseResult> fetchCatalog(String url) async {
    final trimmed = url.trim();
    if (!SourceSite.isValidApi(trimmed)) {
      return const CatalogParseResult(warnings: ['清单地址不合法（需 http:// 或 https:// 开头）']);
    }
    try {
      final body = await _getText(Uri.parse(trimmed));
      final candidates = parseCatalog(body);
      if (candidates.isEmpty) {
        return const CatalogParseResult(warnings: ['清单里没有解析出可用的采集接口地址']);
      }
      return CatalogParseResult(candidates: candidates);
    } catch (e) {
      return CatalogParseResult(warnings: [describeNetworkError(e)]);
    }
  }

  /// 依次拉取多个清单源并合并去重；只要有一个源成功就返回结果。
  /// 用于「内置源 + 用户自定义地址」的降级尝试。
  Future<CatalogParseResult> fetchCatalogs(List<String> urls) async {
    final merged = <SourceCandidate>[];
    final warnings = <String>[];
    for (final url in urls) {
      final res = await fetchCatalog(url);
      if (res.candidates.isNotEmpty) {
        merged.addAll(res.candidates);
      } else {
        warnings.addAll(res.warnings.map((w) => '$url：$w'));
      }
    }
    if (merged.isEmpty) {
      return CatalogParseResult(
        warnings: warnings.isEmpty
            ? const ['没有从清单里解析出可用的采集接口地址']
            : warnings,
      );
    }
    return CatalogParseResult(candidates: mergeCandidates(merged));
  }

  /// 多份清单合并时去重
  static List<SourceCandidate> mergeCandidates(List<SourceCandidate> input) =>
      _dedupe(input);

  /// 从文本里解析候选站点（远程清单与手动粘贴共用）
  static List<SourceCandidate> parseCatalog(String content) {
    final text = content.trim();
    if (text.isEmpty) return const [];

    try {
      final decoded = jsonDecode(text);
      final out = <SourceCandidate>[];
      _collectFromJson(decoded, out);
      if (out.isNotEmpty) return _dedupe(out);
    } catch (_) {
      // 不是 JSON，按纯文本继续
    }

    final out = <SourceCandidate>[];
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final c = _parseLine(line);
      if (c != null) out.add(c);
    }
    return _dedupe(out);
  }

  static void _collectFromJson(Object? node, List<SourceCandidate> out) {
    if (node is String) {
      final c = _candidateFromUrl(node, null);
      if (c != null) out.add(c);
      return;
    }
    if (node is List) {
      for (final e in node) {
        _collectFromJson(e, out);
      }
      return;
    }
    if (node is! Map) return;

    // 常见承载站点列表的字段
    for (final key in const ['sites', 'list', 'data', 'catalogs', 'apis', 'items', 'resources']) {
      final v = node[key];
      if (v is List) _collectFromJson(v, out);
    }

    // 节点自身也可能是一条站点记录
    final api = _firstString(node, const ['api', 'url', 'site', 'host', 'baseUrl', 'endpoint']);
    if (api.isNotEmpty) {
      final resolved = _resolveApi(api, node);
      if (resolved != null) {
        final name = _firstString(node, const ['name', 'title', 'label', 'key']);
        final c = _candidateFromUrl(resolved, name);
        if (c != null) out.add(c);
      }
    }
  }

  /// `api` 可能不是地址（TVBox 配置里是 `csp_XXX` 之类的类型名），
  /// 此时到 `ext` 里找真正的站点地址；`ext` 也可能直接就是一个站点 URL。
  static String? _resolveApi(String api, Map<dynamic, dynamic> node) {
    if (api.startsWith('http://') || api.startsWith('https://')) {
      // drpy / JS 脚本源不是采集接口，带上只会污染探测结果
      final path = Uri.tryParse(api)?.path.toLowerCase() ?? '';
      if (path.endsWith('.js')) return null;
      return _toMaccmsApi(api);
    }

    final extRaw = node['ext'];
    Map<dynamic, dynamic>? ext;
    String? extUrl;
    if (extRaw is Map) {
      ext = extRaw;
    } else if (extRaw is String && extRaw.trim().isNotEmpty) {
      final s = extRaw.trim();
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          ext = decoded;
        } else {
          extUrl = s;
        }
      } on FormatException {
        // ext 本身就是站点地址（TVBox 里很常见）
        extUrl = s;
      }
    }

    if (ext != null) {
      final site = _firstString(ext, const [
        'site',
        'siteUrl',
        'host',
        'baseUrl',
        'url',
        'api',
        'domain',
        'homepage',
      ]);
      if (site.isNotEmpty) return _toMaccmsApi(site);
      return null;
    }
    if (extUrl != null) {
      final isSiteUrl = extUrl.startsWith('http://') ||
          extUrl.startsWith('https://') ||
          _looksLikeHost(extUrl);
      if (isSiteUrl) return _toMaccmsApi(extUrl);
    }
    return null;
  }

  /// 把裸域名 / 站点根 / 带 `at/xml` 的地址，统一成 maccms 的 JSON 采集接口地址
  static String _toMaccmsApi(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return s;

    var path = u.path;
    // maccms 的 `/at/xml` 后缀表示返回 XML，去掉它走默认的 JSON
    path = path.replaceAll(RegExp(r'/at/xml/?$'), '');
    if (!path.contains('api.php')) {
      path = '${path.replaceAll(RegExp(r'/+$'), '')}/api.php/provide/vod';
    }
    // 统一去掉末尾斜杠，避免同一站点因写法不同在列表里出现两条
    path = path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) path = '/';
    // 保留原有 query（部分站点把令牌写在地址里）
    return u.replace(path: path).toString();
  }

  static String _firstString(Map<dynamic, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  /// 单行解析：`https://…`、`站点名 | https://…`、`站点名,https://…`
  static SourceCandidate? _parseLine(String line) {
    var s = line;
    final hash = s.indexOf(' #');
    if (hash > 0) s = s.substring(0, hash).trim();

    for (final sep in const ['|', '\t', '，']) {
      if (s.contains(sep)) {
        final parts = s.split(sep);
        final c = _candidateFromUrl(parts.sublist(1).join(sep).trim(), parts.first);
        if (c != null) return c;
      }
    }

    final m = RegExp(r'^([^,]+),\s*(https?://\S+)$').firstMatch(s);
    if (m != null) {
      final c = _candidateFromUrl(m.group(2)!, m.group(1));
      if (c != null) return c;
    }

    return _candidateFromUrl(s, null);
  }

  static SourceCandidate? _candidateFromUrl(String url, String? name) {
    var s = url.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      // 纯文本清单里常直接写裸域名，补上协议；不像域名的内容直接丢弃
      if (!_looksLikeHost(s)) return null;
      s = 'https://$s';
    }
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;

    // 只给了站点根（没有具体路径）时按 maccms 约定补全
    if (uri.path.isEmpty || uri.path == '/') {
      s = '${uri.scheme}://${uri.authority}/api.php/provide/vod/';
    }

    final label = (name ?? '').trim();
    return SourceCandidate(
      name: label.isNotEmpty
          ? label
          : uri.host.replaceFirst(RegExp(r'^www\.'), ''),
      api: s,
    );
  }

  /// 形如 `host.tld[:port][/path]` 才算域名，避免把说明文字当成站点
  static final RegExp _hostPattern = RegExp(
    r'^[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?'
    r'(\.[A-Za-z0-9]([A-Za-z0-9\-]*[A-Za-z0-9])?)+'
    r'(:\d{1,5})?(/\S*)?$',
  );

  static bool _looksLikeHost(String s) => _hostPattern.hasMatch(s);

  /// 站点去重键：忽略协议、查询串与末尾斜杠；默认端口（80/443）视为等同，
  /// 但显式写出的非默认端口要保留，否则 `127.0.0.1:8080` 与 `127.0.0.1:9090` 会被当成同一站。
  static String normalizeApi(String api) {
    final u = Uri.tryParse(api.trim());
    if (u == null || u.host.isEmpty) return api.trim().toLowerCase();
    final path = u.path.replaceAll(RegExp(r'/+$'), '');
    final isDefaultPort = (u.scheme == 'http' && u.port == 80) ||
        (u.scheme == 'https' && u.port == 443) ||
        (u.scheme.isEmpty && u.port == 0);
    final port = (u.hasPort && !isDefaultPort) ? ':${u.port}' : '';
    return '${u.host.toLowerCase()}$port$path';
  }

  static List<SourceCandidate> _dedupe(List<SourceCandidate> input) {
    final seen = <String>{};
    final out = <SourceCandidate>[];
    for (final c in input) {
      if (seen.add(normalizeApi(c.api))) out.add(c);
    }
    return out;
  }

  // ------------------------------------------------------------ 探测

  /// 探测单个候选站点
  Future<ProbeResult> probe(
    SourceCandidate candidate, {
    Set<String> existing = const {},
  }) async {
    if (existing.contains(normalizeApi(candidate.api))) {
      return ProbeResult(candidate: candidate, alreadyAdded: true, error: '已在站点列表中');
    }
    final sw = Stopwatch()..start();
    final site =
        SourceSite(id: 'probe', name: candidate.name, api: candidate.api);
    try {
      final json = await _getJson(
        site.buildQueryUri(action: 'list', extra: const {'pagesize': '1'}),
      );
      sw.stop();
      final code = json['code'];
      if (code != null && code.toString() != '1') {
        final msg = json['msg']?.toString() ?? '';
        return ProbeResult(
          candidate: candidate,
          milliseconds: sw.elapsedMilliseconds,
          error: '接口返回 code=$code${msg.isEmpty ? '' : '（$msg）'}',
        );
      }
      final list = json['list'];
      if (list is! List) {
        return ProbeResult(
          candidate: candidate,
          milliseconds: sw.elapsedMilliseconds,
          error: '不是 maccms 采集接口（缺少 list 字段）',
        );
      }
      final total =
          int.tryParse(json['total']?.toString() ?? '') ?? list.length;
      return ProbeResult(
        candidate: candidate,
        ok: true,
        milliseconds: sw.elapsedMilliseconds,
        itemCount: total,
      );
    } catch (e) {
      sw.stop();
      return ProbeResult(
        candidate: candidate,
        milliseconds: sw.elapsedMilliseconds,
        error: describeNetworkError(e),
      );
    }
  }

  /// 并发探测整份候选清单，按「先出结果先推送」流式返回
  Stream<ProbeResult> probeAll(
    List<SourceCandidate> candidates, {
    Set<String> existing = const {},
    int concurrency = 8,
  }) {
    final ctrl = StreamController<ProbeResult>();
    var cursor = 0;
    var running = 0;

    void dispatch() {
      if (ctrl.isClosed) return;
      while (running < concurrency && cursor < candidates.length) {
        final c = candidates[cursor++];
        running++;
        probe(c, existing: existing).then((r) {
          if (!ctrl.isClosed) ctrl.add(r);
        }).catchError((Object e) {
          if (!ctrl.isClosed) {
            ctrl.add(ProbeResult(
              candidate: c,
              error: describeNetworkError(e),
            ));
          }
        }).whenComplete(() {
          running--;
          if (cursor >= candidates.length && running == 0) {
            if (!ctrl.isClosed) ctrl.close();
          } else {
            dispatch();
          }
        });
      }
      if (candidates.isEmpty && !ctrl.isClosed) ctrl.close();
    }

    ctrl.onListen = dispatch;
    return ctrl.stream;
  }

  // ------------------------------------------------------------ HTTP

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final body = await _getText(uri);
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw ApiException('返回内容不是 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException('返回 JSON 结构异常');
    }
    return decoded;
  }

  Future<String> _getText(Uri uri) async {
    final req = await _http.getUrl(uri);
    req.headers.set('User-Agent', kBrowserUserAgent);
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (resp.statusCode != 200) {
      throw ApiException('HTTP ${resp.statusCode}');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void close() => _http.close();
}
