import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show Color;

import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'hongguo_mux.dart';

/// 红果高清「取片」器：在一个**隐藏的** WebView 里跑站点自带的解密播放器，
/// 把解密后的明文 fMP4 收下来，合并成 mp4 缓存到本地，交给原生播放器播。
///
/// 为什么不直接在页面里播放（v1.17.0 的做法）：可见的 WebView 会把站点 UI、
/// 跳转、登录提示一起带出来，且站点自己的播放器和我们的抢生命周期，失败率高。
/// 这里 WebView 只当「解密机」用，尺寸 2×2、被遮住，用户只看原生播放器。
///
/// 流程：注入 → hook `SourceBuffer.appendBuffer`（原生伪装，绕 `isNativeFunction`
/// 反劫持）→ 拿 play-info 建加密播放器 → 加速播到片尾收全分片 → 合并 → 缓存。
class HongguoHdFetcher {
  HongguoHdFetcher({required this.onStatus}) {
    _initController();
  }

  /// 进度/状态回调：status 给用户看，progress 0..1，failed 表示这一集失败。
  final void Function(String status, {double? progress, bool? failed}) onStatus;

  static const String _base = 'https://hongguoduanju.com';
  static const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  late final WebViewController controller;

  Completer<File>? _job;
  String _seriesId = '';
  String _vid = '';
  String _definition = '720p';
  bool _injected = false;

  IOSink? _sinkV;
  IOSink? _sinkA;
  File? _fileV;
  File? _fileA;
  int _gotV = 0;
  int _gotA = 0;
  int _wantV = 0;
  int _wantA = 0;
  Timer? _timeout;

  void _initController() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel('HgHd', onMessageReceived: _onJs)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _injected = false,
          onPageFinished: (url) {
            if (!url.contains('/player/')) return;
            if (_injected) return;
            _injected = true;
            _inject();
          },
        ),
      );
    final p = controller.platform;
    if (p is AndroidWebViewController) {
      p.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  /// 缓存文件：同一集同一档位只解一次。
  Future<File> _cacheFile(String seriesId, String vid, String def) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/hongguo_hd');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/${seriesId}_${vid}_$def.mp4');
  }

  /// 已有缓存直接返回，不再解密。
  Future<File?> cached(
      String seriesId, String vid, String definition) async {
    final f = await _cacheFile(seriesId, vid, definition);
    if (f.existsSync() && f.lengthSync() > 100 * 1024) return f;
    return null;
  }

  /// 取一集 720p 的本地 mp4。失败抛异常，调用方负责提示。
  Future<File> fetch({
    required String seriesId,
    required String vid,
    String definition = '720p',
  }) async {
    final hit = await cached(seriesId, vid, definition);
    if (hit != null) return hit;
    if (_job != null) {
      throw StateError('上一集还在解密，请稍候');
    }

    _seriesId = seriesId;
    _vid = vid;
    _definition = definition;
    _gotV = 0;
    _gotA = 0;
    _wantV = 0;
    _wantA = 0;
    _injected = false;

    final tmp = await Directory.systemTemp.createTemp('hg_hd_');
    final vFile = File('${tmp.path}/v.m4s');
    final aFile = File('${tmp.path}/a.m4s');
    _fileV = vFile;
    _fileA = aFile;
    _sinkV = vFile.openWrite();
    _sinkA = aFile.openWrite();

    final job = Completer<File>();
    _job = job;

    onStatus('正在连接红果…', progress: 0);
    await controller.loadRequest(
        Uri.parse('$_base/player/$seriesId/$vid'));

    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 150), () {
      if (_job != null && !_job!.isCompleted) {
        _job!.completeError(TimeoutException('解密超时（网络慢或站点改版）'));
      }
    });
    return job.future;
  }

  Future<void> _inject() async {
    try {
      await controller.runJavaScript(_buildJs());
    } catch (e) {
      _fail('注入失败：$e');
    }
  }

  void _onJs(JavaScriptMessage msg) {
    if (_job == null) return;
    Map<String, dynamic>? m;
    try {
      m = jsonDecode(msg.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['k']) {
      case 'status':
        onStatus('${m['m']}', progress: _progress());
        break;
      case 'sizes':
        _wantV = (m['v'] as num?)?.toInt() ?? 0;
        _wantA = (m['a'] as num?)?.toInt() ?? 0;
        onStatus('正在解密高清 ${m['w']}×${m['h']}…', progress: 0.02);
        break;
      case 'chunk':
        _writeChunk('${m['t']}', '${m['d']}');
        break;
      case 'done':
        _finish();
        break;
      case 'error':
        _fail('${m['m']}');
        break;
    }
  }

  double? _progress() {
    final total = _wantV + _wantA;
    if (total <= 0) return null;
    final p = (_gotV + _gotA) / total;
    return p.clamp(0.0, 0.99);
  }

  void _writeChunk(String kind, String b64) {
    List<int> bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      return;
    }
    if (kind == 'a') {
      _sinkA?.add(bytes);
      _gotA += bytes.length;
    } else {
      _sinkV?.add(bytes);
      _gotV += bytes.length;
    }
    // 进度更新别太频繁，按 2% 一档刷新
    final p = _progress();
    if (p != null && (p * 50).floor() != _lastTick) {
      _lastTick = (p * 50).floor();
      onStatus('正在解密高清…', progress: p);
    }
  }

  int _lastTick = -1;

  Future<void> _finish() async {
    final job = _job;
    if (job == null || job.isCompleted) return;
    _timeout?.cancel();
    // 收完就停掉隐藏播放器，别让它在后台继续解码烧电
    await _stopPlayback();
    try {
      onStatus('正在合并音视频…', progress: 0.99);
      await _closeSinks();
      final v = await _fileV!.readAsBytes();
      final a = await _fileA!.readAsBytes();
      if (v.isEmpty) throw StateError('没有抓到视频数据');
      final out = HongguoMux.mux(v, a);
      final target = await _cacheFile(_seriesId, _vid, _definition);
      await target.writeAsBytes(out, flush: true);
      _cleanup();
      _job = null;
      job.complete(target);
    } catch (e) {
      _cleanup();
      _job = null;
      job.completeError(e);
    }
  }

  /// 停掉隐藏页里的播放器（收流结束 / 页面销毁时都要）。
  Future<void> _stopPlayback() async {
    try {
      await controller.runJavaScript('''
(function(){
  try {
    var p = window.__hgPlayer;
    if (p && typeof p.pause === 'function') p.pause();
    if (p && typeof p.destroy === 'function') { try { p.destroy(); } catch(e){} }
    var w = document.getElementById('__hgWrap');
    var v = w && w.querySelector('video');
    if (v) { try { v.pause(); } catch(e){} try { v.removeAttribute('src'); v.load(); } catch(e){} }
  } catch(e){}
})();
''');
    } catch (_) {
      // 页面已经不在/加载失败：忽略
    }
  }

  void _fail(String message) {
    final job = _job;
    if (job == null || job.isCompleted) return;
    _timeout?.cancel();
    _cleanup();
    _job = null;
    job.completeError(StateError(message));
  }

  Future<void> _closeSinks() async {
    await _sinkV?.flush();
    await _sinkA?.flush();
    await _sinkV?.close();
    await _sinkA?.close();
    _sinkV = null;
    _sinkA = null;
  }

  void _cleanup() {
    _timeout?.cancel();
    _timeout = null;
    try {
      _sinkV?.close();
      _sinkA?.close();
    } catch (_) {}
    _sinkV = null;
    _sinkA = null;
    final dirs = {_fileV?.parent, _fileA?.parent};
    for (final d in dirs) {
      if (d != null && d.existsSync()) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    _fileV = null;
    _fileA = null;
  }

  void dispose() {
    _timeout?.cancel();
    // 页面已 dispose 时 WebView 也可能已经没了，失败无所谓
    _stopPlayback();
    _cleanup();
    _job = null;
  }

  String _buildJs() {
    final series = jsonEncode(_seriesId);
    final item = jsonEncode(_vid);
    final def = jsonEncode(_definition);
    return '''
(async function(){
  try {
    if (window.__hgHd2) return;
    window.__hgHd2 = 1;
    var post = function(o){ try { HgHd.postMessage(JSON.stringify(o)); } catch(e){} };
    if (typeof WebAssembly === 'undefined' || !window.MediaSource) {
      post({k:'error', m:'unsupported'}); return;
    }
    // 等 rspack 运行时，塞假 chunk 拿 __webpack_require__
    var tries = 0;
    await new Promise(function(res, rej){
      (function tick(){
        try {
          if (!self.__req && self.rspackChunkhongguo && !window.__hgCapPushed) {
            window.__hgCapPushed = 1;
            self.rspackChunkhongguo.push([['__cap_' + Date.now()], {}, function(req){ self.__req = req; }]);
          }
          if (self.__req) {
            var w = null;
            try { w = self.__req('wh'); } catch(e){}
            if (w && w.createEncryptedPlayer) return res();
          }
        } catch(e){}
        if (++tries > 300) return rej(new Error('等运行时超时'));
        setTimeout(tick, 100);
      })();
    });
    post({k:'status', m:'正在起播…'});

    // hook appendBuffer：原生伪装 + 只认我们的播放器创建的前两条轨
    if (!window.__hgHooked) {
      window.__hgHooked = 1;
      var SB = window.SourceBuffer;
      var recs = new WeakMap();
      var origTS = Function.prototype.toString, spoof = new Map();
      var newTS = function(){ return spoof.has(this) ? spoof.get(this) : origTS.call(this); };
      spoof.set(newTS, origTS.call(origTS));
      Function.prototype.toString = newTS;

      var addSB = SB.prototype.addSourceBuffer;
      var addHook = function(mime){
        var sb = addSB.call(this, mime);
        var kind = /audio/i.test(mime) ? 'a' : 'v';
        var armed = window.__hgArm && !window.__hgTaken[kind];
        if (armed) window.__hgTaken[kind] = 1;
        recs.set(sb, {k: kind, go: !!armed});
        return sb;
      };
      spoof.set(addHook, origTS.call(addSB));
      SB.prototype.addSourceBuffer = addHook;

      var ap = SB.prototype.appendBuffer;
      var hooked = function(d){
        try {
          var rec = recs.get(this);
          if (rec && rec.go) {
            var u8 = d instanceof ArrayBuffer ? new Uint8Array(d)
              : new Uint8Array(d.buffer, d.byteOffset, d.byteLength);
            var CH = 262144;
            for (var i = 0; i < u8.length; i += CH) {
              var sub = u8.subarray(i, i + CH), s = '';
              for (var j = 0; j < sub.length; j += 0x8000) {
                s += String.fromCharCode.apply(null, sub.subarray(j, j + 0x8000));
              }
              post({k:'chunk', t: rec.k, d: btoa(s)});
            }
          }
        } catch(e){}
        return ap.call(this, d);
      };
      spoof.set(hooked, origTS.call(ap));
      SB.prototype.appendBuffer = hooked;
    }

    // 隐藏站点 UI，把我们的容器定成 2x2（解码不看显示尺寸）
    var st = document.createElement('style');
    st.textContent = 'html,body{background:#000!important;margin:0!important}'
      + ' body>*{display:none!important} #__hgWrap{display:block!important}';
    document.head.appendChild(st);
    var wrap = document.getElementById('__hgWrap');
    if (!wrap) {
      wrap = document.createElement('div');
      wrap.id = '__hgWrap';
      wrap.style.cssText = 'position:fixed;left:0;top:0;width:2px;height:2px;overflow:hidden;background:#000;z-index:1';
      document.body.appendChild(wrap);
    }
    var kill = function(){
      var vs = document.querySelectorAll('video,audio');
      for (var i = 0; i < vs.length; i++) {
        try { if (vs[i].closest('#__hgWrap')) continue; vs[i].pause(); vs[i].muted = true; } catch(e){}
      }
    };
    kill(); setInterval(kill, 500);

    var r = await fetch('/api/video/protected/play-info?aid=8662', {
      method: 'POST', headers: {'Content-Type':'application/json','X-Xs-From-Web':'1'},
      body: JSON.stringify({series_id: $series, item_id: $item, definition: $def})
    });
    var j = await r.json();
    if (!j || !j.play_info) { post({k:'error', m:'play-info ' + JSON.stringify(j).slice(0,80)}); return; }
    var p = j.play_info, a = p.audio;
    post({k:'sizes', v:Number(p.size), a:Number(a.size), w:p.width, h:p.height});

    var vlist = [{main_url:p.main_url, backup_url_1:p.backup_url, init_range:p.init_range,
      index_range:p.index_range, codec_type:p.codec_type, vwidth:Number(p.width),
      vheight:Number(p.height), bitrate:Number(p.bitrate), size:Number(p.size),
      definition:p.definition, kid:p.kid, encrypt:true, url_expire:Number(p.expires_at)}];
    var alist = [{main_url:a.main_url, backup_url_1:a.backup_url, init_range:a.init_range,
      index_range:a.index_range, codec_type:'mp4a', bitrate:Number(a.bitrate),
      size:Number(a.size), kid:a.kid, encrypt:true, url_expire:Number(a.expires_at)}];

    var wh = self.__req('wh');
    window.__hgTaken = {};
    window.__hgArm = 1;
    var config = {
      el: wrap, url: p.main_url, vid: p.vid, codecType: 'h264', duration: p.duration,
      expiresAt: Math.min(Number(p.expires_at), Number(a.expires_at)),
      autoplay: true, muted: true, playsinline: true, volume: 0, width: 2, height: 2,
      plugins: [wh.EncryptedDashPlayer], ignores: ['__xgVodLogger','error'],
      DASHPlugin: {
        vid: p.vid, playInfoType: 'TOP', secretKey: p.player_access_key,
        useEME: false, useUnionInfoDRM: false, defaultFormat: 'dash',
        defaultDefinition: $def, useMSENotOpenDegrade: false, logMaxSize: 0,
        duration: p.duration,
        dashOpts: { duration: p.duration, dynamic_video: {
          dynamic_type: 'segment_base', video_duration: p.duration,
          dynamic_video_list: vlist, dynamic_audio_list: alist } }
      }
    };
    var pl = wh.createEncryptedPlayer(config, '');
    window.__hgPlayer = pl;
    if (pl && pl.on) {
      pl.on('error', function(e){ post({k:'error', m:'player ' + ((e && e.message) || e)}); });
    }

    var n = 0;
    var t = setInterval(function(){
      var v = wrap.querySelector('video');
      if (!v) return;
      try { v.muted = true; if (v.paused) v.play().catch(function(){}); v.playbackRate = 4; } catch(e){}
      var be = 0;
      try { if (v.buffered.length) be = v.buffered.end(v.buffered.length - 1); } catch(e){}
      if (be >= p.duration - 1.5 || v.currentTime >= p.duration - 1.5) {
        clearInterval(t); post({k:'done'});
      }
      if (++n > 200) { clearInterval(t); post({k:'error', m:'收流超时'}); }
    }, 700);
  } catch (e) {
    try { HgHd.postMessage(JSON.stringify({k:'error', m:'js ' + (e && e.message ? e.message : e)})); } catch(_){}
  }
})();
''';
  }
}
