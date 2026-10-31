import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_resource.dart';
import '../models/subtitle.dart';
import '../services/offline_cache.dart';
import '../services/brightness_strategy.dart';
import '../services/playback_store.dart';
import '../services/player_gestures.dart' show GestureConfig;
import '../services/quality_service.dart';
import '../services/quality_store.dart';
import '../services/remote_ua.dart';
import '../services/subtitle_message.dart';
import '../services/subtitle_service.dart';
import '../services/subtitle_store.dart';
import '../widgets/player_gesture_layer.dart';
import 'subtitle_page.dart';

/// 播放页：media_kit（libmpv）播放 m3u8，支持选集、线路切换、倍速、
/// 自动连播、播放进度记忆、离线缓存与在线字幕。
class PlayerPage extends StatefulWidget {
  final MediaResource resource;

  /// 是否沿用上次播放进度（从资源列表进入时为 true，手动选集时为 false）
  final bool resume;

  /// 豆瓣别名（含英文名），字幕搜索时作为片名候选
  final List<String> altTitles;

  const PlayerPage({
    super.key,
    required this.resource,
    this.resume = true,
    this.altTitles = const [],
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _ua = kBrowserUserAgent;
  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  late final StreamSubscription<bool> _completedSub;
  late final StreamSubscription<String> _errorSub;
  Timer? _progressTimer;

  int _groupIndex = 0;
  int _episodeIndex = 0;
  Duration? _pendingSeek;
  double _rate = 1.0;
  bool _autoNext = true;
  bool _isLocal = false;
  bool _opening = true;
  String? _error;

  /// 当前挂载的外部字幕（每部剧记住上次选择）
  SubtitleFile? _subtitle;

  /// 字幕模式：外挂 / 视频内嵌 / 关闭。
  /// 之前用一个 bool 同时表示「关闭」和「内嵌」，换集时会连内嵌字幕一起关掉。
  _SubtitleMode _subtitleMode = _SubtitleMode.external;

  /// 每次打开媒体自增，用于丢弃被后续 open 取代的旧流程
  int _openEpoch = 0;
  bool _pendingSubtitleApply = false;

  /// 字幕选择版本号：挂载过程中又发生变更时用它补挂最新一条
  int _subtitleRev = 0;

  // ------------------------------------------------------- 手势 / 清晰度

  /// 音量 0..100（media_kit 的取值域），初值取播放器实际音量
  final ValueNotifier<double> _volume = ValueNotifier<double>(100);

  /// 亮度策略：现在是「画面遮罩」实现，换系统亮度只需换一个实现类
  final BrightnessStrategy _brightness = OverlayBrightnessStrategy();

  /// m3u8 master 里探测到的码率变体（单码率或探测失败时为空）
  List<QualityOption> _variants = const [];
  int _qualityEpoch = 0;

  /// 用户手选的变体地址；null = 用线路原始地址（「自动」交给播放器自适应）
  String? _variantUrl;

  /// 本次实际在播的变体地址（可能是记忆应用来的）；null = 线路原始地址
  String? _activeVariantUrl;

  /// 等首帧的兜底计时器（dispose 要能取消）
  Timer? _probeTimer;

  /// 播放器参数只设一次；`_openCurrent` 先 await 它，避免 open 抢在设参之前
  late final Future<void> _tuneFuture;

  // 整条线路批量缓存
  int _batchDone = 0;
  int _batchTotal = 0;
  bool _batchAbort = false;

  MediaResource get _r => widget.resource;

  PlayGroup? get _group => _r.groupAt(_groupIndex);

  Episode? get _episode {
    final g = _group;
    if (g == null) return null;
    return (_episodeIndex >= 0 && _episodeIndex < g.episodes.length)
        ? g.episodes[_episodeIndex]
        : null;
  }

  OfflineCache get _cache => offlineCache;

  @override
  void initState() {
    super.initState();
    _groupIndex = _resolveInitialGroup();
    _episodeIndex = _resolveInitialEpisode();
    _applyResumeRecord();
    _subtitle = subtitleStore.selectedFor(_r.key);
    _volume.value = _player.state.volume.clamp(0.0, 100.0);
    _tuneFuture = _tunePlayer();

    _completedSub = _player.stream.completed.listen(_onCompleted);
    _errorSub = _player.stream.error.listen((e) {
      if (mounted) setState(() => _error = e);
    });
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _cache.addListener(_onCacheTick);
    subtitleStore.addListener(_onSubtitleStoreChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openCurrent();
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _completedSub.cancel();
    _errorSub.cancel();
    _cache.removeListener(_onCacheTick);
    subtitleStore.removeListener(_onSubtitleStoreChanged);
    _probeTimer?.cancel();
    _volume.dispose();
    _brightness.dispose();
    _saveProgress();
    _player.dispose();
    super.dispose();
  }

  /// 字幕配置是异步加载的：加载完成后如果发现本剧有记住的字幕，补挂上去。
  ///
  /// 只有「换了另一条字幕 / 字幕被删」才需要重挂轨道；单纯调时间轴由
  /// mpv 的 `sub-delay` 生效，重挂会多出一条 `sub-add` 轨道并闪一下。
  void _onSubtitleStoreChanged() {
    if (!mounted) return;
    final selected = subtitleStore.selectedFor(_r.key);
    final previous = _subtitle;
    final pathChanged = selected?.path != previous?.path;
    final delayChanged = selected?.delayMs != previous?.delayMs;
    if (!pathChanged && !delayChanged) return;

    setState(() {
      _subtitle = selected;
      _subtitleRev++;
      if (pathChanged) {
        if (selected == null && previous != null) {
          // 当前字幕被删掉了：关掉轨道，别让旧字幕继续挂在画面上。
          // 但用户主动选的「内嵌/关闭」要保持，不被这条通知覆盖。
          if (_subtitleMode == _SubtitleMode.external) {
            _subtitleMode = _SubtitleMode.off;
          }
        } else if (selected != null && _subtitleMode == _SubtitleMode.off) {
          _subtitleMode = _SubtitleMode.external;
        }
      }
    });
    if (!pathChanged) return;
    if (_opening) {
      _pendingSubtitleApply = true;
    } else {
      _applySubtitle();
    }
  }

  void _onCacheTick() {
    if (mounted) setState(() {});
  }

  int _resolveInitialGroup() {
    final d = _r.defaultGroup;
    if (d == null) return 0;
    return _r.groups.indexOf(d);
  }

  int _resolveInitialEpisode() => 0;

  /// 若存在上次进度且未看完，则沿用上次的线路 / 集 / 位置
  void _applyResumeRecord() {
    if (!widget.resume) return;
    final rec = playbackStore.of(_r.key);
    if (rec == null || rec.finished || !rec.hasProgress) return;
    final g = _r.groupAt(rec.groupIndex);
    if (g == null || rec.episodeIndex >= g.episodes.length) return;
    _groupIndex = rec.groupIndex;
    _episodeIndex = rec.episodeIndex;
    _pendingSeek = Duration(milliseconds: rec.positionMs);
  }

  Map<String, String> _headersFor(String url) {
    final u = Uri.tryParse(url);
    return {
      'User-Agent': _ua,
      if (u != null && u.hasAuthority)
        'Referer': '${u.scheme}://${u.authority}/',
    };
  }

  String _cacheKeyFor(int group, int episode) =>
      cacheKeyOf(_r.siteId, _r.vodId, group, episode);

  Future<void> _openCurrent({Duration? seekTo, bool allowVariantFallback = true}) async {
    final ep = _episode;
    if (ep == null) {
      ++_openEpoch; // 作废可能还在跑的旧流程
      setState(() {
        _opening = false;
        _error = '该线路没有可播放的剧集';
      });
      return;
    }
    // 参数必须在 open 之前生效，否则这集的提速设置会漏掉
    await _tuneFuture;
    await qualityStore.load();
    final epoch = ++_openEpoch;
    final cached = _cache.byKey(_cacheKeyFor(_groupIndex, _episodeIndex));
    final variant = _variantUrl ?? _rememberedVariantFor(ep.url);
    // 手选/记忆了具体清晰度就走网络：本地缓存是整集固定码率，不能拿来顶替
    final useLocal = variant == null &&
        cached != null &&
        File(cached.localFile).existsSync();
    final playUrl = variant ?? ep.url;
    final uri = useLocal ? Uri.file(cached.localFile).toString() : playUrl;

    setState(() {
      _opening = true;
      _error = null;
      _isLocal = useLocal;
      _activeVariantUrl = useLocal ? null : variant;
    });
    try {
      await _player.open(
        Media(uri, httpHeaders: useLocal ? null : _headersFor(playUrl)),
        play: true,
      );
      // 已被更新的打开请求（连点选集/自动连播）取代，别再往下挂字幕
      if (epoch != _openEpoch) return;
      final target = seekTo ?? _pendingSeek;
      _pendingSeek = null;
      if (target != null && target > const Duration(seconds: 3)) {
        await _player.seek(target);
      }
      // 1.0 是默认值，省掉一次命令往返（对起播速度有一点点影响）
      if (_rate != 1.0) await _player.setRate(_rate);
      // 换集/换线路后 libmpv 会清空外部字幕，需重新挂载
      await _applySubtitle();
      // 清晰度探测等首帧出来再做：起播阶段抢带宽会明显变慢
      if (!useLocal) unawaited(_probeAfterFirstFrame(ep.url, epoch));
    } catch (e) {
      if (!mounted || epoch != _openEpoch) return;
      // 记忆/手选的变体地址可能已经失效（片源带签名，隔天就变）：
      // 清掉这条记忆，退回线路默认地址再试一次，别让人卡在「播放失败」
      if (allowVariantFallback && _activeVariantUrl != null) {
        await qualityStore.forgetVariant(ep.url);
        _variantUrl = null;
        _activeVariantUrl = null;
        return _openCurrent(seekTo: seekTo, allowVariantFallback: false);
      }
      setState(() => _error = '$e');
    } finally {
      if (mounted && epoch == _openEpoch) {
        setState(() => _opening = false);
        // 挂字幕期间可能又收到新的选择，用版本号兜住这一小段窗口
        if (_pendingSubtitleApply) {
          _pendingSubtitleApply = false;
          await _applySubtitle();
        }
      }
    }
  }

  /// 按当前模式挂字幕：外挂文件 / 视频内嵌 / 关闭
  Future<void> _applySubtitle() async {
    final file = _subtitle;
    final rev = _subtitleRev;
    try {
      switch (_subtitleMode) {
        case _SubtitleMode.off:
          await _setSubtitleDelay(0);
          await _player.setSubtitleTrack(SubtitleTrack.no());
          return;
        case _SubtitleMode.embedded:
          // 内嵌字幕不带外挂字幕的偏移
          await _setSubtitleDelay(0);
          await _player.setSubtitleTrack(SubtitleTrack.auto());
          return;
        case _SubtitleMode.external:
          if (file == null) {
            await _player.setSubtitleTrack(SubtitleTrack.no());
            return;
          }
          if (!File(file.path).existsSync()) {
            // 文件被清理了：关掉旧轨道，别让已经载入内存的字幕继续显示
            if (mounted) {
              setState(() {
                _subtitle = null;
                _subtitleMode = _SubtitleMode.off;
              });
            }
            await _setSubtitleDelay(0);
            await _player.setSubtitleTrack(SubtitleTrack.no());
            return;
          }
          await _player.setSubtitleTrack(
            SubtitleTrack.uri(
              Uri.file(file.path).toString(),
              title: file.label,
              language: file.language,
            ),
          );
          // 偏移优先用 mpv 的 sub-delay；文件里已经烘进偏移的别再叠加
          await _setSubtitleDelay(
            file.path == file.basePath ? file.delayMs : 0,
          );
          // 挂载过程中又换了字幕，补挂一次最新的
          if (rev != _subtitleRev && mounted) {
            await _applySubtitle();
          }
      }
    } catch (e) {
      _toast('字幕加载失败：${subtitleErrorMessage(e)}');
    }
  }

  /// 实时字幕偏移（秒）。libmpv 的 `sub-delay` 属性，不重写文件。
  Future<bool> _setSubtitleDelay(int ms) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return false;
    try {
      await platform.command(
        ['set', 'sub-delay', (ms / 1000).toStringAsFixed(3)],
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _openSubtitleMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: _subtitleSheet,
    );
    if (!mounted || action == null) return;
    if (action == 'search') {
      await _pickSubtitle();
      return;
    }
    if (action == 'embedded') {
      setState(() {
        _subtitleMode = _SubtitleMode.embedded;
        _subtitleRev++;
      });
      await _applySubtitle();
      _toast('已切换到视频内嵌字幕');
      return;
    }
    if (action == 'off') {
      setState(() {
        _subtitleMode = _SubtitleMode.off;
        _subtitleRev++;
      });
      await _applySubtitle();
      _toast('已关闭字幕');
      return;
    }
  }
  Future<void> _pickSubtitle() async {
    final picked = await Navigator.push<SubtitleFile>(
      context,
      MaterialPageRoute(
        builder: (_) => SubtitlePage(
          showKey: _r.key,
          showTitle: _r.title,
          year: _r.year.trim().isEmpty ? null : _r.year,
          altTitles: widget.altTitles,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    // store.select 已经触发过监听并挂载，这里只补「同一条重选」的情况
    if (_subtitle?.path == picked.path &&
        _subtitleMode == _SubtitleMode.external) {
      _toast('字幕已加载：${picked.label}');
      return;
    }
    setState(() {
      _subtitle = picked;
      _subtitleMode = _SubtitleMode.external;
      _subtitleRev++;
    });
    await _applySubtitle();
    _toast('字幕已加载：${picked.label}');
  }

  /// 微调时间轴：优先用 mpv `sub-delay` 实时生效；
  /// 播放器不支持时退化成「重写文件 + 重挂」（bakeDelay）。
  Future<void> _shiftSubtitle(int deltaMs, {bool silent = false}) async {
    final file = _subtitle;
    if (file == null) return;
    final next = (file.delayMs + deltaMs).clamp(-60000, 60000).toInt();
    try {
      if (!await _setSubtitleDelay(next)) {
        final baked = await subtitleService.bakeDelay(file, next);
        if (!mounted) return;
        // bakeDelay → replaceFile 会同步触发监听，监听已经重挂过就先不重复挂
        final alreadyApplied = _subtitle?.path == baked.path;
        setState(() {
          _subtitle = baked;
          _subtitleMode = _SubtitleMode.external;
          _subtitleRev++;
        });
        if (!alreadyApplied) await _applySubtitle();
        if (!silent) _toast('字幕延迟 ${baked.delayText}');
        return;
      }
      final updated = await subtitleService.updateDelay(file, next);
      if (!mounted) return;
      setState(() {
        _subtitle = updated;
        _subtitleMode = _SubtitleMode.external;
        _subtitleRev++;
      });
      if (!silent) _toast('字幕延迟 ${updated.delayText}');
    } catch (e) {
      _toast(subtitleErrorMessage(e));
    }
  }

  Widget _subtitleSheet(BuildContext ctx) {
    // 时间轴在原面板内原地生效，不关面板、不重新打开
    return StatefulBuilder(builder: (ctx, setSheetState) {
      final scheme = Theme.of(ctx).colorScheme;
      final file = _subtitle;
      final active = file != null && _subtitleMode == _SubtitleMode.external;
      Future<void> shift(int delta) async {
        await _shiftSubtitle(delta, silent: true);
        if (mounted) setSheetState(() {});
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Row(
                children: [
                  const Text('字幕',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (active)
                    Text(
                      '${file.languageLabel} · ${file.hasDelay ? '延迟 ${file.delayText}' : '已加载'}',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(
                active ? Icons.subtitles_rounded : Icons.subtitles_outlined,
                color: active ? scheme.primary : null,
              ),
              title: Text(
                file?.label ?? '未加载外部字幕',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                switch (_subtitleMode) {
                  _SubtitleMode.off => '已关闭字幕',
                  _SubtitleMode.embedded => '使用视频内嵌字幕',
                  _SubtitleMode.external =>
                    file == null ? '还没有选择字幕' : '字幕会记住，换集自动重挂',
                },
                style: const TextStyle(fontSize: 11),
              ),
            ),
            if (active)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => shift(-500),
                        child: const Text('提前 0.5s'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => shift(500),
                        child: const Text('延后 0.5s'),
                      ),
                    ),
                    if (file.hasDelay) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '恢复默认',
                        onPressed: () => shift(-file.delayMs),
                        icon: const Icon(Icons.restart_alt_rounded),
                      ),
                    ],
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.travel_explore_rounded),
              title: const Text('在线获取字幕'),
              subtitle: const Text('搜索 OpenSubtitles / 粘贴直链导入',
                  style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'search'),
            ),
            ListTile(
              leading: const Icon(Icons.closed_caption_outlined),
              title: const Text('使用视频内嵌字幕'),
              onTap: () => Navigator.pop(ctx, 'embedded'),
            ),
            ListTile(
              leading: const Icon(Icons.subtitles_off_rounded),
              title: const Text('关闭字幕'),
              onTap: () => Navigator.pop(ctx, 'off'),
            ),
            const SizedBox(height: 6),
          ],
        ),
      );
    });
  }

  Future<void> _switchEpisode(int index, {int? group, Duration? seekTo}) async {
    // 先按「当前集 + 当前播放位置」落一次进度，再切索引；
    // 否则旧集的位置会被记到新集上，下次续播直接跳到片尾。
    await _saveProgress();
    if (!mounted) return;
    if (group != null && group != _groupIndex) {
      final len = _r.groupAt(group)?.length ?? 1;
      setState(() {
        _groupIndex = group;
        _episodeIndex = index.clamp(0, len - 1).toInt();
      });
    } else {
      setState(() => _episodeIndex = index);
    }
    // 换集/换线路后回到该线路的默认清晰度（记忆命中时 _openCurrent 会重新填）
    _variantUrl = null;
    _activeVariantUrl = null;
    _variants = const [];
    await _openCurrent(seekTo: seekTo);
  }

  Future<void> _onCompleted(bool completed) async {
    if (!completed || !_autoNext) return;
    final g = _group;
    if (g == null || _episodeIndex + 1 >= g.episodes.length) return;
    await _switchEpisode(_episodeIndex + 1);
  }

  Future<void> _saveProgress() async {
    final ep = _episode;
    if (ep == null) return;
    final pos = _player.state.position;
    final dur = _player.state.duration;
    if (pos.inMilliseconds <= 0) return;
    await playbackStore.save(PlaybackRecord(
      key: _r.key,
      groupIndex: _groupIndex,
      episodeIndex: _episodeIndex,
      positionMs: pos.inMilliseconds,
      durationMs: dur.inMilliseconds,
      title: _r.title,
      episodeName: ep.name,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  // ------------------------------------------------------- 手势与清晰度

  /// 起播提速：只动「起播时机」相关的三个参数。
  ///
  /// - `cache-secs` / `demuxer-readahead-secs`：默认 10 秒，降到 6 秒——
  ///   不用先攒够 10 秒数据才出画；
  /// - `network-timeout`：默认 60 秒，降到 10 秒——死链不用干等一分钟。
  ///
  /// 刻意**不降** `demuxer-max-bytes`（默认 150MiB+）：那会让拖动和片尾重新缓冲变慢，
  /// 是拿后面的卡顿换前面的一点启动时间，不划算；
  /// 也刻意**不碰** `hls-bitrate`：清晰度仍由播放器按带宽自适应，不降档。
  Future<void> _tunePlayer() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    const options = {
      'cache-secs': '6',
      'demuxer-readahead-secs': '6',
      'network-timeout': '10',
    };
    for (final e in options.entries) {
      try {
        await platform.command(['set', e.key, e.value]);
      } catch (_) {
        // 不同平台的 mpv 版本不一定认全部属性，认不出的跳过
      }
    }
  }

  void _applyVolume(double v) {
    if (!mounted) return;
    _volume.value = v;
    _player.setVolume(v);
  }

  void _applyBrightness(double v) => _brightness.set(v);

  /// 等首帧出来再探测：起播阶段每多一条请求都在抢带宽。
  /// 最多等 3 秒（起播失败时也要把清晰度菜单探出来）。
  Future<void> _probeAfterFirstFrame(String url, int epoch) async {
    final done = Completer<void>();
    final sub = _player.stream.position.listen((p) {
      if (p > Duration.zero && !done.isCompleted) done.complete();
    });
    _probeTimer?.cancel();
    _probeTimer = Timer(const Duration(seconds: 3), () {
      if (!done.isCompleted) done.complete();
    });
    try {
      await done.future;
    } finally {
      await sub.cancel();
      _probeTimer?.cancel();
    }
    if (!mounted || epoch != _openEpoch) return;
    await _probeQualities(url);
    if (!mounted || epoch != _openEpoch) return;
    _prefetchNextProbe();
  }

  /// 读一次 m3u8，把 master playlist 里的码率变体列出来。
  /// 失败/单码率都只是「没有更多清晰度可选」，不影响播放。
  Future<void> _probeQualities(String url) async {
    final epoch = ++_qualityEpoch;
    final found = await qualityService.probe(url, headers: _headersFor(url));
    if (!mounted || epoch != _qualityEpoch) return;
    setState(() => _variants = found);
  }

  /// 起播时能零成本拿到的「记忆清晰度」地址：
  /// - 同一集重看 → 上次存下来的变体地址直接可用；
  /// - 换集但码率表已被上一集预热进缓存 → 按记忆的标签解析出这一集的同档位。
  /// 都不命中就返回 null，按线路默认地址起播——**绝不为了偏好加一次联网**，
  /// 那等于把起播拖慢，和「记住清晰度」的初衷相反。
  String? _rememberedVariantFor(String masterUrl) {
    final saved = qualityStore.variantFor(masterUrl);
    if (saved != null) return saved;
    final cached = qualityService.cachedOptions(
      masterUrl,
      headers: _headersFor(masterUrl),
    );
    if (cached == null) return null;
    final resolved = resolveRemembered(qualityStore.labelFor(_r.key), cached);
    if (resolved == null || resolved.isAuto) return null;
    return resolved.url;
  }

  /// 预热下一集的清晰度表：切集时菜单秒开，记忆的清晰度也能立刻生效
  void _prefetchNextProbe() {
    final g = _group;
    if (g == null) return;
    final next = _episodeIndex + 1;
    if (next >= g.episodes.length) return;
    final url = g.episodes[next].url;
    unawaited(qualityService.probe(url, headers: _headersFor(url)));
  }

  /// 可切换的清晰度：m3u8 变体优先，其次是「线路名里带清晰度字样」的其它线路
  List<QualityOption> get _qualityOptions {
    final groups = groupQualityOptions(_r.groups);
    if (_variants.isEmpty) return groups;
    return [..._variants, ...groups];
  }

  /// 当前选中项 id：'auto' / 变体地址 / 'g:线路下标'
  String get _currentQualityId {
    final active = _variantUrl ?? _activeVariantUrl;
    if (active != null) return active;
    if (_variants.isNotEmpty) return 'auto';
    if (qualityRankOfName(_group?.name ?? '') > 0) return 'g:$_groupIndex';
    return '';
  }

  String get _qualityLabel {
    final id = _currentQualityId;
    if (id.isEmpty) return '清晰度';
    for (final o in _qualityOptions) {
      if (o.id == id) return o.label;
    }
    return '清晰度';
  }

  Future<void> _switchQuality(QualityOption option) async {
    if (option.id == _currentQualityId) return;
    if (option.isGroup) {
      if (option.groupIndex == _groupIndex) return;
      // 换线路但保持当前播放位置，观感上才是「换了个清晰度」而不是「重看」
      final pos = _player.state.position;
      await _switchEpisode(_episodeIndex, group: option.groupIndex, seekTo: pos);
      _toast('已切换到「${option.label}」线路');
      return;
    }
    final pos = _player.state.position;
    setState(() => _variantUrl = option.isAuto ? null : option.url);
    await _openCurrent(seekTo: pos);
    // 记住这部剧的选择：标签用来在别的集上找回同档，变体地址只对同一集有效
    unawaited(qualityStore.remember(
      _r.key,
      option.isAuto ? 'auto' : option.label,
      masterUrl: _episode?.url ?? '',
      variantUrl: option.isAuto ? null : option.url,
    ));
    _toast(option.isAuto ? '清晰度：自动适应' : '已切换到 ${option.label}');
  }

  Future<void> _openQualitySheet() async {
    final options = _qualityOptions;
    if (options.isEmpty) {
      _toast('当前片源没有可切换的清晰度');
      return;
    }
    final current = _currentQualityId;
    final remembered = qualityStore.labelFor(_r.key);
    final picked = await showModalBottomSheet<QualityOption>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Row(
                  children: [
                    const Text('清晰度',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(
                      '共 ${options.length} 个',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              for (final o in options)
                ListTile(
                  leading: Icon(
                    o.id == current
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: o.id == current ? scheme.primary : null,
                  ),
                  title: Row(
                    children: [
                      Text(o.label, style: const TextStyle(fontSize: 14)),
                      if (o.label == remembered && !o.isGroup) ...[
                        const SizedBox(width: 6),
                        Text(
                          '上次选的',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: o.detail.isEmpty
                      ? null
                      : Text(o.detail, style: const TextStyle(fontSize: 11)),
                  onTap: () => Navigator.pop(ctx, o),
                ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    await _switchQuality(picked);
  }

  // ---------------------------------------------------------------- 缓存

  Future<void> _cacheCurrentEpisode() async {
    final ep = _episode;
    if (ep == null) return;
    final key = _cacheKeyFor(_groupIndex, _episodeIndex);
    if (_cache.byKey(key) != null) {
      _toast('该集已缓存');
      return;
    }
    _toast('开始缓存「${ep.name}」');
    // 缓存用户当前正在看的那个清晰度，而不是线路默认地址
    final url = _activeVariantUrl ?? ep.url;
    try {
      await _cache.download(
        key: key,
        title: _r.title,
        episodeName: ep.name,
        m3u8Url: url,
        headers: _headersFor(url),
      );
      _toast('「${ep.name}」缓存完成，可在离线状态播放');
    } on OfflineCacheException catch (e) {
      _toast('缓存失败：${e.message}');
    }
  }

  Future<void> _cacheWholeGroup() async {
    final g = _group;
    if (g == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('缓存整条线路'),
        content: Text(
            '将顺序缓存「${g.name}」线路共 ${g.episodes.length} 集到本地，'
            '耗时与占用的存储空间取决于片源大小。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _batchAbort = false;
      _batchDone = 0;
      _batchTotal = g.episodes.length;
    });
    for (var i = 0; i < g.episodes.length; i++) {
      if (_batchAbort || !mounted) break;
      final key = _cacheKeyFor(_groupIndex, i);
      if (_cache.byKey(key) != null) {
        setState(() => _batchDone = i + 1);
        continue;
      }
      try {
        await _cache.download(
          key: key,
          title: _r.title,
          episodeName: g.episodes[i].name,
          m3u8Url: g.episodes[i].url,
          headers: _headersFor(g.episodes[i].url),
        );
      } on OfflineCacheException catch (e) {
        _toast('第 ${i + 1} 集缓存失败：${e.message}');
      }
      if (mounted) setState(() => _batchDone = i + 1);
    }
    final aborted = _batchAbort;
    if (mounted) {
      setState(() {
        _batchTotal = 0;
        _batchDone = 0;
      });
    }
    _toast(aborted ? '已停止批量缓存' : '整条线路缓存完成');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ));
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_r.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            Text(
              '${_episode?.name ?? ''} · ${_r.siteName} · ${_group?.name ?? ''}'
              '${_isLocal ? ' · 本地' : ''}'
              '${_subtitleMode == _SubtitleMode.external && _subtitle != null ? ' · 字幕' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: switch (_subtitleMode) {
              _SubtitleMode.off => '字幕：已关闭',
              _SubtitleMode.embedded => '字幕：视频内嵌',
              _SubtitleMode.external =>
                _subtitle == null ? '字幕：未加载' : '字幕：${_subtitle!.label}',
            },
            onPressed: _openSubtitleMenu,
            icon: Icon(
              _subtitleMode == _SubtitleMode.off
                  ? Icons.subtitles_off_rounded
                  : Icons.subtitles_rounded,
              color: _subtitleMode == _SubtitleMode.external && _subtitle != null
                  ? Colors.amberAccent
                  : null,
            ),
          ),
          IconButton(
            tooltip: _autoNext ? '关闭自动连播' : '开启自动连播',
            onPressed: () => setState(() => _autoNext = !_autoNext),
            icon: Icon(_autoNext
                ? Icons.playlist_play_rounded
                : Icons.playlist_remove_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) {
              switch (v) {
                case 'replay':
                  _openCurrent(seekTo: Duration.zero);
                case 'cache':
                  _cacheCurrentEpisode();
                case 'cache_all':
                  _cacheWholeGroup();
                case 'clear':
                  _cache.remove(_cacheKeyFor(_groupIndex, _episodeIndex));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'replay', child: Text('从头播放')),
              PopupMenuItem(value: 'cache', child: Text('缓存当前集')),
              PopupMenuItem(value: 'cache_all', child: Text('缓存整条线路')),
              PopupMenuItem(value: 'clear', child: Text('清除本集缓存')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _wrapControls()),
                if (_opening)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        ),
                      ),
                    ),
                  ),
                if (_error != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Material(
                      color: Colors.red.shade900,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          '播放失败：$_error',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  /// 用 media_kit 自带的 AdaptiveVideoControls（进度条/手势/全屏），
  /// 并按平台定制底部按钮栏，额外挂上「选集 / 缓存 / 倍速」。
  Widget _wrapControls() {
    final video = Video(
      controller: _controller,
      // 每次 build 传新闭包，使自定义按钮能跟随页面状态（倍速、缓存进度）刷新
      controls: _controlsOverlay,
      fit: BoxFit.contain,
    );
    final desktop = _isDesktop;
    final bar = <Widget>[
      if (desktop)
        const MaterialDesktopPositionIndicator()
      else
        const MaterialPositionIndicator(),
      const Spacer(),
      _barButton(desktop, Icons.video_library_outlined, _openEpisodesSheet, '选集'),
      _cacheBarButton(desktop),
      _qualityButton(),
      _rateButton(desktop),
      if (desktop)
        const MaterialDesktopFullscreenButton()
      else
        const MaterialFullscreenButton(),
    ];

    if (desktop) {
      return MaterialDesktopVideoControlsTheme(
        normal: MaterialDesktopVideoControlsThemeData(
          topButtonBar: const [],
          bottomButtonBar: bar,
          visibleOnMount: true,
          modifyVolumeOnScroll: true,
        ),
        fullscreen: MaterialDesktopVideoControlsThemeData(
          topButtonBar: const [],
          bottomButtonBar: bar,
        ),
        child: video,
      );
    }
    return MaterialVideoControlsTheme(
      normal: MaterialVideoControlsThemeData(
        topButtonBar: const [],
        bottomButtonBar: bar,
        visibleOnMount: true,
        seekOnDoubleTap: true,
        speedUpOnLongPress: true,
        speedUpFactor: 2.0,
      ),
      fullscreen: MaterialVideoControlsThemeData(
        topButtonBar: const [],
        bottomButtonBar: bar,
      ),
      child: video,
    );
  }

  /// 视频之上的叠加层，自下而上：亮度遮罩 → 原生控件 → 手势层。
  /// 遮罩压在控件下面，调暗画面时按钮和进度条仍然清晰可辨。
  Widget _controlsOverlay(VideoState state) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 亮度层：由策略实现（现在是画面遮罩；换系统亮度只需换实现）
        _brightness.buildOverlay(context),
        AdaptiveVideoControls(state),
        PlayerGestureLayer(
          volume: _volume,
          brightness: _brightness.listenable,
          readPosition: () => _player.state.position,
          readDuration: () => _player.state.duration,
          onVolumeChanged: _applyVolume,
          onBrightnessChanged: _applyBrightness,
          onSeek: (t) {
            // 手势松手可能正好撞上页面关闭（player 已 dispose），先挡一道
            if (mounted) _player.seek(t);
          },
          config: _isDesktop ? GestureConfig.comfortable : const GestureConfig(),
          enabled: !_opening,
        ),
      ],
    );
  }

  bool get _isDesktop {
    final p = defaultTargetPlatform;
    return p == TargetPlatform.windows ||
        p == TargetPlatform.linux ||
        p == TargetPlatform.macOS;
  }

  Widget _barButton(
      bool desktop, IconData icon, VoidCallback onPressed, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: desktop
          ? MaterialDesktopCustomButton(
              icon: Icon(icon), onPressed: onPressed)
          : MaterialCustomButton(icon: Icon(icon), onPressed: onPressed),
    );
  }

  Widget _rateButton(bool desktop) {
    return PopupMenuButton<double>(
      tooltip: '倍速',
      initialValue: _rate,
      onSelected: (v) {
        setState(() => _rate = v);
        _player.setRate(v);
      },
      itemBuilder: (_) => [
        for (final r in _rates)
          PopupMenuItem(value: r, child: Text('${r}x')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          '${_rate}x',
          style: const TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  /// 清晰度入口：只有真的探测到多个清晰度时才出现，避免一排没用的按钮
  Widget _qualityButton() {
    if (_qualityOptions.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: '清晰度',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _openQualitySheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hd_rounded, size: 16, color: Colors.white),
              const SizedBox(width: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 56),
                child: Text(
                  _qualityLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cacheBarButton(bool desktop) {
    final key = _cacheKeyFor(_groupIndex, _episodeIndex);
    final cached = _cache.byKey(key);
    final progress = _cache.progressOf(key);
    if (progress != null) {
      return Tooltip(
        message: progress.text,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress.total == 0 ? null : progress.ratio,
                  strokeWidth: 2.2,
                  color: Colors.white,
                ),
                Text(
                  '${(progress.ratio * 100).toInt()}',
                  style: const TextStyle(fontSize: 8, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _barButton(
      desktop,
      cached != null
          ? Icons.download_done_rounded
          : Icons.download_outlined,
      cached != null
          ? () => _toast('本集已缓存到本地')
          : _cacheCurrentEpisode,
      cached != null ? '已缓存本集' : '缓存本集',
    );
  }

  Widget _bottomBar() {
    final scheme = Colors.white;
    return Container(
      color: Colors.black,
      padding: EdgeInsets.fromLTRB(16, 10, 12, 10 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _episode?.name ?? '—',
                  style: TextStyle(
                      color: scheme, fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_r.siteName} · ${_group?.name ?? ''} · '
                  '${_group?.length ?? 0} 集'
                  '${_isLocal ? ' · 本地缓存' : ''}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
          if (_batchTotal > 0)
            Text('缓存中 $_batchDone/$_batchTotal',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
          IconButton(
            tooltip: '选集',
            onPressed: _openEpisodesSheet,
            icon: const Icon(Icons.list_rounded),
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  Future<void> _openEpisodesSheet() async {
    final g = _group;
    if (g == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _EpisodeSheet(
        resource: _r,
        groupIndex: _groupIndex,
        episodeIndex: _episodeIndex,
        onPick: (group, episode) {
          Navigator.pop(context);
          _switchEpisode(episode, group: group);
        },
      ),
    );
  }
}

/// 字幕模式：外挂文件 / 视频内嵌 / 关闭
enum _SubtitleMode { external, embedded, off }

/// 选集面板：线路切换 + 分集网格
class _EpisodeSheet extends StatefulWidget {
  final MediaResource resource;
  final int groupIndex;
  final int episodeIndex;
  final void Function(int groupIndex, int episodeIndex) onPick;

  const _EpisodeSheet({
    required this.resource,
    required this.groupIndex,
    required this.episodeIndex,
    required this.onPick,
  });

  @override
  State<_EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<_EpisodeSheet> {
  late int _g = widget.groupIndex;

  @override
  void initState() {
    super.initState();
    offlineCache.addListener(_tick);
  }

  @override
  void dispose() {
    offlineCache.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = widget.resource.groups;
    final episodes = groups[_g].episodes;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Text('选集',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('共 ${episodes.length} 集',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (groups.length > 1) ...[
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (var i = 0; i < groups.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('${groups[i].name}（${groups[i].length}）'),
                        selected: i == _g,
                        onSelected: (_) => setState(() => _g = i),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Flexible(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 108,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: episodes.length,
              itemBuilder: (context, i) {
                final active = _g == widget.groupIndex && i == widget.episodeIndex;
                final cached = offlineCache.byKey(
                  cacheKeyOf(
                      widget.resource.siteId, widget.resource.vodId, _g, i),
                );
                return InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.onPick(_g, i),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: active
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? scheme.primary : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            episodes[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  active ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (cached != null)
                          const Padding(
                            padding: EdgeInsets.only(left: 3),
                            child: Icon(Icons.offline_pin_rounded,
                                size: 12, color: Colors.green),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
