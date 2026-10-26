import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/subtitle.dart';
import '../remote_ua.dart';
import 'subtitle_exception.dart';

/// OpenSubtitles（opensubtitles.com）字幕源。
///
/// * **搜索**：`api.opensubtitles.com/api/v1/subtitles`。匿名可用，但按 IP 限流；
///   填了免费 API Key 后额度更高（Key 在字幕页里可填）。
/// * **下载**：优走旧站 `dl.opensubtitles.org/en/download/sub/{legacy_id}`，
///   这条通道不需要 Key，返回 zip；填了 Key 时先试官方 `/download` 接口。
///
/// 服务器会拒绝非常规 User-Agent（实测默认的 `Dart/3.x` 直接 403），
/// 所以所有请求都带浏览器 UA。
class OpenSubtitlesSource {
  static const String id = 'opensubtitles';
  static const String name = 'OpenSubtitles';

  static const String _apiHost = 'api.opensubtitles.com';
  static const String _legacyHost = 'dl.opensubtitles.org';

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;

  Map<String, String> _headers({String? apiKey}) => {
        'User-Agent': kBrowserUserAgent,
        'Accept': 'application/json',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        if (apiKey != null && apiKey.isNotEmpty) 'Api-Key': apiKey,
      };

  /// 搜索字幕。[query] 用片名（英文名命中率最高），[year] 可精确到年份。
  Future<List<SubtitleCandidate>> search({
    required String query,
    String? year,
    List<String> languages = const ['zh-cn', 'zh-tw', 'en'],
    String? apiKey,
    int page = 1,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final params = <String, String>{
      'query': keyword,
      'languages': languages.isEmpty ? 'zh-cn,en' : languages.join(','),
      'order_by': 'download_count',
      'page': '$page',
    };
    if (year != null && year.trim().isNotEmpty) {
      params['year'] = year.trim();
    }
    final uri = Uri.https(_apiHost, '/api/v1/subtitles', params);

    final res = await _request(uri, headers: _headers(apiKey: apiKey));
    if (res.status == 429) {
      throw SubtitleException('请求太频繁了，等 1 分钟再试');
    }
    if (res.status == 401) {
      throw SubtitleException(
        'OpenSubtitles API Key 无效，请检查字幕页里填的 Key',
        needsApiKey: true,
      );
    }
    if (res.status == 403) {
      throw SubtitleException(
        'OpenSubtitles 匿名额度已用尽或被限流：等一会儿再试，'
        '或在「本地与直链」里填入免费 API Key',
        needsApiKey: true,
      );
    }
    if (res.status == 406) return const [];
    if (res.status != 200) {
      throw SubtitleException('字幕搜索失败（HTTP ${res.status}）');
    }

    final decoded = jsonDecode(utf8.decode(res.body, allowMalformed: true));
    if (decoded is! Map) throw SubtitleException('字幕搜索返回了意外的数据');
    return parseSearchPayload(Map<String, dynamic>.from(decoded));
  }

  /// 解析 `/subtitles` 的响应体（抽出来便于离线单测）
  List<SubtitleCandidate> parseSearchPayload(Map<String, dynamic> json) {
    final list = json['data'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => _parseCandidate(Map<String, dynamic>.from(e)))
        .whereType<SubtitleCandidate>()
        .toList();
  }

  SubtitleCandidate? _parseCandidate(Map<String, dynamic> raw) {
    final attributes = raw['attributes'];
    if (attributes is! Map) return null;
    final a = Map<String, dynamic>.from(attributes);

    final files = a['files'];
    final file = files is List && files.isNotEmpty && files.first is Map
        ? Map<String, dynamic>.from(files.first as Map)
        : const <String, dynamic>{};

    final feature = a['feature_details'];
    final featureMap = feature is Map
        ? Map<String, dynamic>.from(feature)
        : const <String, dynamic>{};

    final fileName = (file['file_name'] ?? '').toString();
    final release = (a['release'] ?? '').toString().trim();
    final featureTitle = (featureMap['title'] ?? '').toString().trim();
    final title = release.isNotEmpty
        ? release
        : (featureTitle.isNotEmpty ? featureTitle : '未命名字幕');

    final id = (a['subtitle_id'] ?? '').toString();
    if (id.isEmpty) return null;

    return SubtitleCandidate(
      source: OpenSubtitlesSource.id,
      id: id,
      title: title,
      language: (a['language'] ?? '').toString(),
      format: _formatOf(fileName),
      downloads: _intOf(a['download_count']) ?? 0,
      hd: a['hd'] == true,
      year: _intOf(featureMap['year']),
      legacyId: _intOf(a['legacy_subtitle_id']),
      fileId: _intOf(file['file_id']),
      pageUrl: (a['url'] ?? '').toString(),
    );
  }

  /// 接口偶尔把数字写成字符串，统一转一次，避免一条脏数据让整包解析失败
  int? _intOf(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  String _formatOf(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.contains('.ass') || lower.contains('.ssa')) return 'ass';
    if (lower.contains('.vtt')) return 'vtt';
    return 'srt';
  }

  /// 下载字幕原始字节（可能是 zip / gzip / 纯文本，交由上层解包）。
  Future<List<int>> download(SubtitleCandidate candidate, {String? apiKey}) async {
    SubtitleException? keyError;
    if (apiKey != null && apiKey.isNotEmpty && candidate.fileId != null) {
      try {
        return await _downloadViaApi(candidate.fileId!, apiKey);
      } catch (e) {
        // 有 Key 也可能因为额度/失效失败，回落到免 Key 通道
        keyError = e is SubtitleException ? e : SubtitleException('$e');
      }
    }
    if (candidate.legacyId != null) {
      try {
        return await _downloadViaLegacy(candidate.legacyId!);
      } catch (e) {
        final legacyError = e is SubtitleException ? e : SubtitleException('$e');
        if (keyError != null) {
          throw SubtitleException(
            '${keyError.message}；免 Key 通道也失败：${legacyError.message}',
          );
        }
        throw legacyError;
      }
    }
    if (keyError != null) throw keyError;
    throw SubtitleException(
      '这条字幕没有免 Key 下载通道，请在「本地与直链」里填入 OpenSubtitles API Key 后重试',
    );
  }

  /// 官方接口：POST /download 拿临时直链（需要 API Key）
  Future<List<int>> _downloadViaApi(int fileId, String apiKey) async {
    final uri = Uri.https(_apiHost, '/api/v1/download');
    final body = utf8.encode(jsonEncode({'file_id': fileId}));
    final res = await _request(
      uri,
      method: 'POST',
      body: body,
      headers: {
        ..._headers(apiKey: apiKey),
        'Content-Type': 'application/json',
      },
    );
    if (res.status == 401 || res.status == 403) {
      throw SubtitleException(
        'OpenSubtitles API Key 无效或额度已用完',
        needsApiKey: true,
      );
    }
    if (res.status != 200) {
      throw SubtitleException('官方下载通道失败（HTTP ${res.status}）');
    }
    final decoded = jsonDecode(utf8.decode(res.body, allowMalformed: true));
    final link = decoded is Map ? (decoded['link'] ?? '').toString() : '';
    if (link.isEmpty) throw SubtitleException('OpenSubtitles 没有返回下载地址');
    final file = await _request(
      Uri.parse(link),
      headers: _headers(),
      timeout: const Duration(seconds: 60),
    );
    if (file.status != 200) {
      throw SubtitleException('字幕文件下载失败（HTTP ${file.status}）');
    }
    if (_looksLikeHtml(file)) {
      throw SubtitleException('字幕直链返回了网页，请稍后重试');
    }
    return file.body;
  }

  /// 免 Key 通道：旧站按 legacy id 直接给 zip
  Future<List<int>> _downloadViaLegacy(int legacyId) async {
    final uri =
        Uri.https(_legacyHost, '/en/download/sub/$legacyId');
    final res = await _request(
      uri,
      headers: {
        'User-Agent': kBrowserUserAgent,
        'Referer': 'https://www.opensubtitles.org/',
      },
      timeout: const Duration(seconds: 60),
    );
    if (res.status != 200) {
      throw SubtitleException('字幕下载失败（HTTP ${res.status}），请稍后再试');
    }
    if (_looksLikeHtml(res)) {
      throw SubtitleException('OpenSubtitles 拒绝了这次下载，请稍后再试或填写 API Key');
    }
    return res.body;
  }

  /// 出错时服务器可能返回 HTML 页面（首字节可能是空白或 BOM，得跳过再看）
  bool _looksLikeHtml(_Response res) {
    if (res.contentType.contains('html')) return true;
    for (final byte in res.body) {
      if (byte == 0x20 || byte == 0x0D || byte == 0x0A || byte == 0x09) continue;
      return byte == 0x3C; // '<'
    }
    return false;
  }

  Future<_Response> _request(
    Uri uri, {
    String method = 'GET',
    List<int>? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    HttpClientRequest? req;
    try {
      req = await _http.openUrl(method, uri);
      headers?.forEach(req.headers.set);
      if (body != null) req.add(body);
      final resp = await req.close().timeout(timeout);
      // 限制单次响应体积，避免异常大的文件把内存吃满
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) {
        a.addAll(b);
        if (a.length > _maxResponseBytes) {
          throw SubtitleException('字幕文件过大（超过 40MB），已中止下载');
        }
        return a;
      }).timeout(timeout);
      return _Response(
        resp.statusCode,
        bytes,
        resp.headers.contentType?.mimeType ?? '',
      );
    } on SubtitleException {
      req?.abort();
      rethrow;
    } on TimeoutException {
      req?.abort();
      throw SubtitleException('字幕服务响应超时，请检查网络后重试');
    } on SocketException {
      throw SubtitleException('连不上字幕服务，请检查网络或代理');
    } on HttpException {
      throw SubtitleException('字幕服务请求失败，请稍后重试');
    }
  }

  static const int _maxResponseBytes = 40 * 1024 * 1024;

  void close() => _http.close();
}

class _Response {
  final int status;
  final List<int> body;
  final String contentType;

  const _Response(this.status, this.body, [this.contentType = '']);
}
