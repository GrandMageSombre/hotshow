import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 应用网络层异常，带用户可读的中文信息。
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

/// 底层 HTTP 客户端，封装豆瓣两种接口：
/// 1. frodo App 接口（需要 HMAC-SHA1 签名）
/// 2. m.douban.com rexxar Web 接口（需要 Referer）
class ApiClient {
  static const String _frodoKey = '0dad551ec0f84ed02907ff5c42e8ec70';
  static const String _frodoSecret = 'bf7dddc7c9cfe6f7';
  static const String _frodoUa =
      'api-client/1 com.douban.frodo/7.22.0.beta9(231) Android/23 '
      'product/Mate40 vendor/HUAWEI model/Mate40 brand/HUAWEI '
      'rom/android network/wifi platform/AndroidPad';
  static const String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static final ApiClient instance = ApiClient._();

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = true;

  ApiClient._();

  /// frodo 签名：HMAC-SHA1(secret, "GET&" + urlencode(path) + "&" + ts)，Base64
  String _sign(String path, String ts) {
    final msg = 'GET&${Uri.encodeComponent(path)}&$ts';
    final hmac = Hmac(sha1, utf8.encode(_frodoSecret));
    return base64.encode(hmac.convert(utf8.encode(msg)).bytes);
  }

  Future<dynamic> frodoGet(String path, [Map<String, String>? params]) async {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final query = <String, String>{...?params};
    query['apiKey'] = _frodoKey;
    query['_ts'] = ts;
    query['_sig'] = _sign(path, ts);
    query['os_rom'] = 'android';
    return _requestJson(
      Uri.https('frodo.douban.com', path, query),
      headers: {'User-Agent': _frodoUa, 'Accept': 'application/json'},
    );
  }

  Future<dynamic> rexxarGet(String path, [Map<String, String>? params]) async {
    return _requestJson(
      Uri.https('m.douban.com', '/rexxar/api/v2$path', params),
      headers: {'User-Agent': _browserUa, 'Referer': 'https://m.douban.com/tv/'},
    );
  }

  Future<dynamic> _requestJson(Uri uri, {Map<String, String>? headers}) async {
    dynamic body;
    int status = 0;
    try {
      final req = await _http.getUrl(uri);
      headers?.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      status = resp.statusCode;
      body = utf8.decode(await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b)));
    } on TimeoutException {
      throw ApiException('请求超时，请检查网络后重试');
    } on SocketException {
      throw ApiException('网络连接失败，请检查网络设置');
    } on HttpException {
      throw ApiException('网络请求失败，请稍后重试');
    }

    if (status != 200) {
      // 豆瓣异常响应通常也带 JSON 说明
      try {
        final j = jsonDecode(body);
        if (j is Map && j['msg'] != null) {
          throw ApiException('豆瓣接口异常：${j['msg']}', status);
        }
      } on FormatException {
        // fallthrough
      }
      throw ApiException('豆瓣接口异常（HTTP $status），请稍后重试', status);
    }

    try {
      return jsonDecode(body);
    } on FormatException {
      throw ApiException('数据解析失败，请稍后重试');
    }
  }

  void close() => _http.close();
}
