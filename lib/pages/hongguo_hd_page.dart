import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 红果高清（720p）手机端播放页。
///
/// 原理：红果网页端对访客只给 360p，480p/720p 是 CENC 加密 DASH，密钥由网页播放器
/// 内部的 jsvmp VM 派生。手机上没有 Node/puppeteer，但有 **系统 WebView（Chromium）**——
/// 直接让站点自己的播放器在 WebView 里跑起来，它负责解密，我们只要：
///
/// 1. 等 rspack 运行时出现，塞一个假 chunk 拿到 `__webpack_require__`；
/// 2. 用 `req('wh').createEncryptedPlayer(config)` 直接起播（绕过页面 browserAllowed 门禁）；
/// 3. 把我们自己的播放器容器铺满全屏，把站点自带的播放器/广告暂停并隐藏。
///
/// 全程在手机上完成，不需要电脑。要求：系统 WebView 较新（Android 8+ 一般满足，
/// 需支持 WebAssembly + MediaSource，Android 10+ 更稳）。
///
/// 详细逆向过程见 `docs/红果高清探测.md` 第六、七节；
/// 桌面端命令行版见 `tool/hongguo_hd/decrypt.cjs`。
class HongguoHdPage extends StatefulWidget {
  const HongguoHdPage({
    super.key,
    required this.seriesId,
    required this.title,
    required this.vids,
    this.initialIndex = 0,
  });

  final String seriesId;
  final String title;

  /// 全部单集的 vid（详情页 `vid_list`，按顺序）
  final List<String> vids;
  final int initialIndex;

  @override
  State<HongguoHdPage> createState() => _HongguoHdPageState();
}

class _HongguoHdPageState extends State<HongguoHdPage> {
  static const String _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  WebViewController? _controller;
  late int _index;

  String _status = '正在打开红果…';
  bool _failed = false;
  bool _injected = false;
  Timer? _hintTimer;

  /// WebView 只在 Android / iOS 上有实现；桌面端用命令行工具（tool/hongguo_hd）。
  bool get _supported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.vids.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.vids.length - 1);
    if (!_supported) return;
    if (widget.vids.isEmpty) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUa)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel('HgHd', onMessageReceived: _onJsMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _injected = false),
          onPageFinished: (url) {
            // 只在真正的播放页注入：about:blank / 中间跳转会误触发
            if (!url.contains('/player/')) return;
            if (_injected) return;
            _injected = true;
            _inject();
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true) {
              _setStatus('网页加载失败：${e.description}', failed: true);
            }
          },
        ),
      );
    _controller = controller;

    // Android：允许无手势自动播放（要声音就得关掉这个限制）
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _load();
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    if (widget.vids.isEmpty) {
      _setStatus('这部剧没有可播放的集', failed: true);
      return;
    }
    setState(() {
      _status = '正在打开第 ${_index + 1} 集…';
      _failed = false;
    });
    final url =
        'https://hongguoduanju.com/player/${widget.seriesId}/${widget.vids[_index]}';
    _controller?.loadRequest(Uri.parse(url));
  }

  void _onJsMessage(JavaScriptMessage msg) {
    final text = msg.message;
    if (text == 'playing') {
      _setStatus('');
    } else if (text.startsWith('size:')) {
      // 已拿到真实分辨率，说明解密起播成功
      _setStatus('');
    } else if (text.startsWith('created:')) {
      _setStatus('正在解密高清（${text.substring(8)}）…');
    } else if (text == 'error:unsupported') {
      _setStatus(
        '当前系统 WebView 太旧，不支持高清解密。\n'
        '请在应用商店更新「Android System WebView」或 Chrome 后重试。',
        failed: true,
      );
    } else if (text.startsWith('error:')) {
      _setStatus('播放失败：${text.substring(6)}', failed: true);
    }
  }

  void _setStatus(String s, {bool failed = false}) {
    if (!mounted) return;
    if (_status == s && _failed == failed) return;
    setState(() {
      _status = s;
      _failed = failed;
    });
  }

  /// 注入：等运行时 → 拿 require → 直接调加密播放器铺满全屏
  Future<void> _inject() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript(_buildInjectJs());
    } catch (e) {
      _setStatus('注入失败：$e', failed: true);
      return;
    }
    // 兜底：15 秒还没起播就把「解密中」换成可点的提示，避免一直转圈
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || _failed || _status.isEmpty) return;
      _setStatus('还没出画面的话，点一下屏幕试试；仍不行就点「重试」');
    });
  }

  String _buildInjectJs() {
    // 用 jsonEncode 保证字符串安全；JS 里不再用 $ 避免和 Dart 插值冲突
    final series = jsonEncode(widget.seriesId);
    final item = jsonEncode(widget.vids[_index]);
    return '''
(async function(){
  try {
    if (window.__hgHdDone) { return; }
    window.__hgHdDone = 1;
    var post = function(s){ try { HgHd.postMessage(String(s)); } catch(e){} };
    post('inject:start');

    // 能力自检：老 WebView 可能缺 WebAssembly / MediaSource，直接给明确错误
    if (typeof WebAssembly === 'undefined' || !window.MediaSource) {
      post('error:unsupported'); return;
    }

    // 1) 等 rspack 运行时，并塞假 chunk 拿到 __webpack_require__
    var tries = 0;
    await new Promise(function(res, rej){
      (function tick(){
        try {
          if (!self.__req && self.rspackChunkhongguo && !window.__hgCapPushed) {
            window.__hgCapPushed = 1;
            self.rspackChunkhongguo.push([['__cap_' + Date.now()], {}, function(req){ self.__req = req; }]);
          }
          if (self.__req) {
            var wh = null;
            try { wh = self.__req('wh'); } catch(e){}
            if (wh && wh.createEncryptedPlayer) { return res(); }
          }
        } catch(e){}
        if (++tries > 300) { return rej(new Error('等运行时超时')); }
        setTimeout(tick, 100);
      })();
    });
    post('runtime:ok');

    // 2) 隐藏站点 UI，暂停站点自带播放器（避免抢声音）
    var st = document.createElement('style');
    st.textContent = 'html,body{background:#000!important;overflow:hidden!important;margin:0!important}'
      + ' body>*{display:none!important} #__hgWrap{display:block!important}';
    document.head.appendChild(st);
    var kill = function(){
      var vs = document.querySelectorAll('video,audio');
      for (var i=0;i<vs.length;i++){
        try { if (vs[i].closest('#__hgWrap')) continue; vs[i].pause(); vs[i].muted = true; } catch(e){}
      }
    };
    kill(); setInterval(kill, 500);

    // 3) 全屏容器
    var wrap = document.getElementById('__hgWrap');
    if (!wrap) {
      wrap = document.createElement('div');
      wrap.id = '__hgWrap';
      wrap.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;background:#000;z-index:2147483647';
      document.body.appendChild(wrap);
    }

    // 4) 取 720p play-info（裸域同源）
    var r = await fetch('/api/video/protected/play-info?aid=8662', {
      method: 'POST',
      headers: {'Content-Type':'application/json','X-Xs-From-Web':'1'},
      body: JSON.stringify({series_id: $series, item_id: $item, definition: '720p'})
    });
    var j = await r.json();
    if (!j || !j.play_info) { post('error:play-info ' + JSON.stringify(j).slice(0,100)); return; }
    var p = j.play_info, a = p.audio;

    var vlist = [{main_url:p.main_url, backup_url_1:p.backup_url, init_range:p.init_range,
      index_range:p.index_range, codec_type:p.codec_type, vwidth:Number(p.width),
      vheight:Number(p.height), bitrate:Number(p.bitrate), size:Number(p.size),
      definition:p.definition, kid:p.kid, encrypt:true, url_expire:Number(p.expires_at)}];
    // 音频列表必须嵌在 dynamic_video 里；codec_type 用 mp4a（接口误返 h264）
    var alist = [{main_url:a.main_url, backup_url_1:a.backup_url, init_range:a.init_range,
      index_range:a.index_range, codec_type:'mp4a', bitrate:Number(a.bitrate),
      size:Number(a.size), kid:a.kid, encrypt:true, url_expire:Number(a.expires_at)}];

    var wh = self.__req('wh');
    var config = {
      el: wrap, url: p.main_url, vid: p.vid, codecType: 'h264', duration: p.duration,
      expiresAt: Math.min(Number(p.expires_at), Number(a.expires_at)),
      autoplay: true, muted: false, playsinline: true, volume: 0.8,
      width: window.innerWidth, height: window.innerHeight,
      plugins: [wh.EncryptedDashPlayer], ignores: ['__xgVodLogger','error'],
      DASHPlugin: {
        vid: p.vid, playInfoType: 'TOP', secretKey: p.player_access_key,
        useEME: false, useUnionInfoDRM: false, defaultFormat: 'dash',
        defaultDefinition: '720p', useMSENotOpenDegrade: false, logMaxSize: 0,
        duration: p.duration,
        dashOpts: { duration: p.duration, dynamic_video: {
          dynamic_type: 'segment_base', video_duration: p.duration,
          dynamic_video_list: vlist, dynamic_audio_list: alist } }
      }
    };
    var pl = wh.createEncryptedPlayer(config, '');
    window.__hgPlayer = pl;
    if (pl && pl.on) {
      pl.on('error', function(e){ post('error:player ' + ((e && e.message) || e)); });
      pl.on('playing', function(){ post('playing'); });
    }
    post('created:' + p.width + 'x' + p.height);

    var n = 0;
    var t = setInterval(function(){
      var v = wrap.querySelector('video');
      if (v && v.videoWidth > 0) { post('size:' + v.videoWidth + 'x' + v.videoHeight); clearInterval(t); }
      if (++n > 120) clearInterval(t);
    }, 500);
  } catch (e) {
    try { HgHd.postMessage('error:js ' + (e && e.message ? e.message : e)); } catch(_){}
  }
})();
''';
  }

  Future<void> _pickEpisode() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF141414),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Text('选集', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('共 ${widget.vids.length} 集',
                        style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
              ),
              SizedBox(
                height: 240,
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 64,
                    mainAxisExtent: 44,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: widget.vids.length,
                  itemBuilder: (_, i) {
                    final on = i == _index;
                    return InkWell(
                      onTap: () => Navigator.pop(ctx, i),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: on ? Theme.of(context).colorScheme.primary : const Color(0xFF222222),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${i + 1}',
                            style: TextStyle(
                              fontSize: 13,
                              color: on ? Colors.black : Colors.white70,
                            )),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked == _index) return;
    setState(() => _index = picked);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return _unsupportedView(context);
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            onPressed: _pickEpisode,
            icon: const Icon(Icons.list_rounded, size: 18),
            label: Text('第${_index + 1}集'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (controller != null) WebViewWidget(controller: controller),
          if (_status.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_failed,
                child: ColoredBox(
                  color: _failed ? Colors.black87 : Colors.black54,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_failed)
                            const SizedBox(
                              width: 34, height: 34,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          if (!_failed) const SizedBox(height: 18),
                          Text(
                            _status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                          ),
                          if (_failed) ...[
                            const SizedBox(height: 18),
                            FilledButton.tonalIcon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('重试'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 桌面/网页端没有 WebView 实现时的说明页（那种环境用命令行工具）。
  Widget _unsupportedView(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.phone_android_rounded, size: 44),
              const SizedBox(height: 16),
              const Text(
                '手机端高清播放只在 Android / iOS 上可用。\n'
                '当前环境没有系统 WebView，无法在设备内解密。',
                textAlign: TextAlign.center,
                style: TextStyle(height: 1.6),
              ),
              const SizedBox(height: 12),
              Text(
                '桌面端请用：tool/hongguo_hd/decrypt.cjs',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
