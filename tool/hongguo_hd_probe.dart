import 'dart:convert';
import 'dart:io';

/// 红果短剧高清（480p/720p）play-info 探测。
///
/// 关键发现（2026-11-05 实测）：受保护播放接口只在**裸域**
/// `hongguoduanju.com` 上对访客匿名开放；`www.hongguoduanju.com` 一律 405。
/// 之前 docs/红果高清探测.md 用 www 探测，误判为「接口锁死」。
///
/// 用法：
///   dart run tool/hongguo_hd_probe.dart [series_id] [item_id]
/// 不传 item_id 时自动抓详情页取第 1 集 vid。
///
/// 返回的 480p/720p 是 CENC-AES-CTR 加密 DASH（kid + player_access_key），
/// 内容密钥由网页播放器的 jsvmp VM（transformUnionKey，RSA-KEK + AES-GCM
/// 解包）派生，离线解密需进一步逆向该 VM。本工具只负责取元数据与地址。
Future<void> main(List<String> args) async {
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  const base = 'https://hongguoduanju.com'; // 裸域！www 会 405
  final seriesId = args.isNotEmpty ? args[0] : '7701935931787316286';
  var itemId = args.length > 1 ? args[1] : '';

  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  Future<String> post(String path, Map<String, dynamic> body) async {
    final req = await http.postUrl(Uri.parse('$base$path?aid=8662'));
    req.headers
      ..set('User-Agent', ua)
      ..set('Content-Type', 'application/json')
      ..set('X-Xs-From-Web', '1')
      ..set('Accept', 'application/json, text/plain, */*')
      ..set('Referer', '$base/player/$seriesId/$itemId')
      ..set('Origin', base);
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    final text = await resp.transform(utf8.decoder).join();
    return '${resp.statusCode}\t$text';
  }

  // 自动取第 1 集 vid
  if (itemId.isEmpty) {
    final req = await http.getUrl(Uri.parse('$base/detail?series_id=$seriesId'));
    req.headers.set('User-Agent', ua);
    final resp = await req.close();
    final html = await resp.transform(utf8.decoder).join();
    final m = RegExp(r'"vid_list"\s*:\s*\[\s*"(\d+)"').firstMatch(html);
    itemId = m?.group(1) ?? '';
    stdout.writeln('series=$seriesId  auto vid=$itemId');
  }
  if (itemId.isEmpty) {
    stderr.writeln('无法取得 vid，请手动传入 item_id');
    exit(1);
  }

  for (final def in ['360p', '480p', '720p', '1080p']) {
    final raw = await post(
        '/api/video/protected/play-info', {'series_id': seriesId, 'item_id': itemId, 'definition': def});
    final tab = raw.indexOf('\t');
    final status = raw.substring(0, tab);
    final body = raw.substring(tab + 1);
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {}
    final p = j?['play_info'];
    if (p is Map) {
      stdout.writeln('[$status] $def: ${p['width']}x${p['height']} '
          '${p['bitrate']}bps fmt=${p['format']} codec=${p['codec_type']}');
      stdout.writeln('        kid=${p['kid']}');
      stdout.writeln('        ak=${p['player_access_key']}');
      stdout.writeln('        init=${p['init_range']} index=${p['index_range']} '
          'first_moof=${p['first_moof_range']} expires=${p['expires_at']}');
      stdout.writeln('        video=${p['main_url']}');
    } else {
      stdout.writeln('[$status] $def: ${body.length > 120 ? body.substring(0, 120) : body}');
    }
  }
  http.close();
}
