import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/iptv_channel.dart';
import '../models/media_resource.dart';
import '../services/iptv_service.dart';
import '../widgets/common_views.dart';
import '../widgets/remote_image.dart';
import 'player_page.dart';

/// 电视直播：把 GitHub 上公开的 IPTV m3u 列表拉下来当频道表用。
///
/// 直播和点播是两套东西：这里不做搜索聚合、不做离线缓存，只负责
/// 「选源 → 选分组 → 点台播放」。频道地址全是第三方公开源，
/// 能不能播取决于源本身，所以每个源都标了实测可播率。
class LivePage extends StatefulWidget {
  /// 供测试注入（默认用单例）
  final IptvService? service;

  const LivePage({super.key, this.service});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  late final IptvService _service = widget.service ?? IptvService.instance;

  String _sourceId = kIptvSources.first.id;
  IptvPlaylist? _playlist;
  Object? _error;
  bool _loading = false;

  /// 代次：切源/刷新后旧请求的回包直接丢掉
  int _epoch = 0;

  String? _group;
  bool _hdOnly = false;
  String _keyword = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 上次看的是哪个源，下次进来接着用（个人自用，这个比「永远回第一个」顺）
    unawaited(_restoreLastSource());
  }

  static const String _kLastSource = 'iptv_last_source';

  Future<void> _restoreLastSource() async {
    String? saved;
    try {
      final sp = await SharedPreferences.getInstance();
      saved = sp.getString(_kLastSource);
    } catch (_) {
      // 读不到就用默认源，不值得为这个挡住页面
    }
    if (!mounted) return;
    final valid = saved == kIptvAllSources ||
        (saved != null && IptvService.sourceOf(saved) != null);
    await _load(sourceId: valid ? saved : null);
  }

  Future<void> _rememberSource(String id) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLastSource, id);
    } catch (_) {
      // 记不住只是下次回到第一个源，不影响本次使用
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false, String? sourceId}) async {
    final target = sourceId ?? _sourceId;
    // 切源失败时要能退回去，先把现场存下来
    final prevSource = _sourceId;
    final prevPlaylist = _playlist;
    final prevGroup = _group;
    final myEpoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
      _sourceId = target;
      _group = null;
      _playlist = null;
    });
    try {
      final p = await _service.load(target, force: force);
      if (!mounted || myEpoch != _epoch) return;
      setState(() {
        _playlist = p;
        _loading = false;
        _visibleKey = '';
      });
      unawaited(_rememberSource(target));
    } catch (e) {
      if (!mounted || myEpoch != _epoch) return;
      setState(() {
        _error = e;
        _loading = false;
        // 新源没拉到就退回去，别把用户正在看的列表清空
        _sourceId = prevSource;
        _playlist = prevPlaylist;
        _group = prevGroup;
      });
    }
  }

  /// 当前生效的频道列表（分组 → 高清 → 搜索依次过滤）
  ///
  /// 结果是带签名的缓存：只有一个过滤条件变了才重算。
  /// 合并模式有 2700 条，每敲一个字都全量重跑会明显卡输入。
  String _visibleKey = '';
  List<IptvChannel> _visibleList = const [];

  List<IptvChannel> get _visible {
    final key = '${identityHashCode(_playlist)}|$_group|$_hdOnly|$_keyword';
    if (key == _visibleKey) return _visibleList;
    _visibleKey = key;
    _visibleList = _computeVisible();
    return _visibleList;
  }

  List<IptvChannel> _computeVisible() {
    final base = _playlist?.filterGroup(_group) ?? const IptvPlaylist();
    var list = base.channels;
    if (_hdOnly) list = list.where((c) => c.isHd).toList();
    final k = _keyword.trim().toLowerCase();
    if (k.isNotEmpty) {
      list = list
          .where((c) =>
              c.name.toLowerCase().contains(k) ||
              c.group.toLowerCase().contains(k))
          .toList();
    }
    return list;
  }

  void _play(IptvChannel c) {
    if (!c.playable) {
      _toast('${c.name} 是组播地址，手机网络播不了');
      return;
    }
    final resource = MediaResource(
      siteId: _kLiveSiteId,
      siteName: '电视直播',
      vodId: c.url,
      title: c.name,
      cover: c.logo,
      remarks: '直播',
      typeName: c.group,
      intro: '直播地址：${c.url}',
      groups: [
        PlayGroup(
          name: c.group.isEmpty ? '直播' : c.group,
          episodes: [Episode(name: c.name, url: c.url)],
        ),
      ],
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          resource: resource,
          resume: false,
          isLive: true,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('电视直播'),
        actions: [
          IconButton(
            tooltip: _hdOnly ? '显示全部频道' : '只看高清',
            onPressed: () => setState(() => _hdOnly = !_hdOnly),
            icon: Icon(_hdOnly
                ? Icons.hd_rounded
                : Icons.hd_outlined),
          ),
          IconButton(
            tooltip: '刷新列表',
            onPressed: _loading ? null : () => _load(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _sourceBar(scheme),
          _searchBar(scheme),
          if (_playlist != null && _playlist!.groups.isNotEmpty)
            _groupBar(scheme),
          Expanded(child: _body(scheme)),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 源选择

  Widget _sourceBar(ColorScheme scheme) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _sourceChip(
            scheme,
            id: kIptvAllSources,
            label: '全部合并',
            sub: '${kIptvSources.fold<int>(0, (a, s) => a + s.channels)} 条',
            tip: '六份列表并起来、按台名去重。频道最多，但排序按源的可播率来',
          ),
          for (final s in kIptvSources)
            _sourceChip(
              scheme,
              id: s.id,
              label: s.name,
              // 「~」是刻意留的：这是抽样估出来的可播率，不是保证
              sub: '${s.channels}台 · ~${s.health}%',
              tip: '${s.note}\n可播率是抽样 40 个频道实测的估计值',
            ),
        ],
      ),
    );
  }

  Widget _sourceChip(
    ColorScheme scheme, {
    required String id,
    required String label,
    required String sub,
    String? tip,
  }) {
    final on = id == _sourceId;
    final body = Padding(
      padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: id == _sourceId ? null : () => _load(sourceId: id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: on ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                  color: on ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                sub,
                style: TextStyle(
                  fontSize: 10.5,
                  color: on
                      ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
                      : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 源说明（含「死链多」这类提醒）平时不占地方，长按能看到
    return tip == null ? body : Tooltip(message: tip, child: body);
  }

  // --------------------------------------------------------------- 搜索

  Widget _searchBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: TextField(
        controller: _search,
        onChanged: (v) => setState(() => _keyword = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜频道，如 CCTV5、湖南卫视',
          hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
          prefixIcon: const Icon(Icons.search_rounded, size: 19),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 32),
          suffixIcon: _keyword.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 17),
                  onPressed: () {
                    _search.clear();
                    setState(() => _keyword = '');
                  },
                ),
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- 分组

  Widget _groupBar(ColorScheme scheme) {
    final groups = _playlist!.groups;
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _groupChip(scheme, null, '全部'),
          for (final g in groups) _groupChip(scheme, g, g),
        ],
      ),
    );
  }

  Widget _groupChip(ColorScheme scheme, String? group, String label) {
    final on = _group == group;
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: on,
        onSelected: (_) => setState(() => _group = group),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        side: BorderSide(
          color: on ? Colors.transparent : scheme.outlineVariant,
        ),
        backgroundColor: scheme.surface,
      ),
    );
  }

  // --------------------------------------------------------------- 列表

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorRetry(error: _error, onRetry: () => _load(force: true));
    }
    final list = _visible;
    if (list.isEmpty) {
      return EmptyHint(message: _emptyMessage);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
          child: Row(
            children: [
              Text(
                '${list.length} 个频道',
                style: TextStyle(fontSize: 11.5, color: scheme.outline),
              ),
              const Spacer(),
              if (_sourceId == kIptvAllSources)
                Text(
                  '已按频道名去重',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) => _channelTile(scheme, list[i]),
          ),
        ),
      ],
    );
  }

  /// 空列表时按「到底是哪个条件把结果滤空了」给不同的提示，
  /// 免得在明明没搜东西的时候劝用户「换个关键词」。
  String get _emptyMessage {
    if (_keyword.trim().isNotEmpty) {
      return '没有叫「${_keyword.trim()}」的频道\n换个说法试试，比如 CCTV5、湖南';
    }
    if (_hdOnly) {
      return '这个源里没有标着高清的频道\n关掉右上角的「只看高清」再看看';
    }
    return '这个源的列表是空的（可能刚好在更新）\n换一个源试试';
  }

  Widget _channelTile(ColorScheme scheme, IptvChannel c) {
    final dead = !c.playable;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 42,
        height: 32,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: c.logo.isEmpty
              ? _logoFallback(scheme, c.name)
              : RemoteImage(
                  url: c.logo,
                  fit: BoxFit.contain,
                  // 台标显示只有 42×32，按原图解码会白读几百 KB
                  cacheWidth: 84,
                  placeholder: (_) => _logoFallback(scheme, c.name),
                ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: dead ? scheme.outline : null,
              ),
            ),
          ),
          if (c.is4K) _badge(scheme, '4K', const Color(0xFFE5455C)),
          if (!c.is4K && c.isHd) _badge(scheme, 'HD', scheme.primary),
        ],
      ),
      subtitle: c.group.isEmpty
          ? null
          : Text(
              c.group,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.outline),
            ),
      trailing: Icon(
        dead ? Icons.block_rounded : Icons.play_circle_outline_rounded,
        size: 21,
        color: dead ? scheme.outlineVariant : scheme.primary,
      ),
      onTap: () => _play(c),
    );
  }

  Widget _logoFallback(ColorScheme scheme, String name) {
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '台' : name.substring(0, 1),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: scheme.outline,
        ),
      ),
    );
  }

  Widget _badge(ColorScheme scheme, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 直播源在站点体系里的 id
const String _kLiveSiteId = 'iptv';
