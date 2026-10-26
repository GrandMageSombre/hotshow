import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/subtitle.dart';
import '../services/subtitle/subtitle_exception.dart';
import '../services/subtitle_message.dart';
import '../services/subtitle_service.dart';
import '../services/subtitle_store.dart';

/// 在线字幕工具：搜索 OpenSubtitles → 下载并自动挂到当前播放 →
/// 也支持直链导入、管理本剧已下载的字幕。
///
/// 关闭时通过 `Navigator.pop(context, SubtitleFile?)` 把选中项返回给播放页。
class SubtitlePage extends StatefulWidget {
  /// 剧集唯一键（采集站 `siteId#vodId`），用于分目录存放与记住选择
  final String showKey;
  final String showTitle;
  final String? year;

  /// 豆瓣别名（常含英文名），用于提高 OpenSubtitles 命中率
  final List<String> altTitles;

  const SubtitlePage({
    super.key,
    required this.showKey,
    required this.showTitle,
    this.year,
    this.altTitles = const [],
  });

  @override
  State<SubtitlePage> createState() => _SubtitlePageState();
}

class _SubtitlePageState extends State<SubtitlePage>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _keyword =
      TextEditingController(text: _initialKeyword);
  final TextEditingController _url = TextEditingController();
  late final TextEditingController _apiKey =
      TextEditingController(text: subtitleStore.apiKey);
  late final TabController _tabs = TabController(length: 2, vsync: this);

  late final List<String> _suggestions = _buildSuggestions();
  late final Set<String> _languages = subtitleStore.languages
      .where((l) => SubtitleLanguageOption.options.any((o) => o.value == l))
      .toSet();
  late List<SubtitleFile> _localFiles =
      subtitleStore.existingFilesFor(widget.showKey);
  SubtitleFile? _current;

  List<SubtitleCandidate> _items = const [];
  bool _loading = false;
  String? _error;
  bool _needsKey = false;
  String? _busyId;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _current = subtitleStore.selectedFor(widget.showKey);
    if (_languages.isEmpty) {
      _languages.addAll(const ['zh-cn', 'zh-tw', 'en']);
    }
    subtitleStore.addListener(_onStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  @override
  void dispose() {
    subtitleStore.removeListener(_onStoreChanged);
    _tabs.dispose();
    _keyword.dispose();
    _url.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {
      _localFiles = subtitleStore.existingFilesFor(widget.showKey);
      _current = subtitleStore.selectedFor(widget.showKey);
    });
  }

  /// 首次搜索用的关键词：优先含拉丁字母的别名。
  /// OpenSubtitles 的中文片名命中率低，匿名额度又有限，先用英文名更划算。
  String get _initialKeyword {
    final latin = RegExp(r'[A-Za-z]{2,}');
    for (final s in _suggestions) {
      if (latin.hasMatch(s)) return s;
    }
    return _suggestions.first;
  }

  /// 片名候选：豆瓣主标题 + 别名（别名里往往有英文名，OpenSubtitles 更认这个）
  List<String> _buildSuggestions() {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in [widget.showTitle, ...widget.altTitles]) {
      final title = raw.trim();
      if (title.isEmpty) continue;
      // 豆瓣别名常写成「中文名 / 英文名 / 日文名」的合集
      for (final part in title.split(RegExp(r'\s*/\s*'))) {
        final t = part.trim();
        if (t.length < 2) continue;
        if (seen.add(t.toLowerCase())) result.add(t);
      }
    }
    if (result.isEmpty) result.add(widget.showTitle);
    return result.take(5).toList();
  }

  /// 每次搜索自增；慢请求回来时若已不是最新一次，就直接丢弃
  int _searchSeq = 0;

  Future<void> _search({String? keyword, bool force = false}) async {
    final query = (keyword ?? _keyword.text).trim();
    if (query.isEmpty) return;
    if (!mounted) return;
    if (keyword != null) _keyword.text = keyword;
    FocusScope.of(context).unfocus();
    final seq = ++_searchSeq;
    setState(() {
      _loading = true;
      _error = null;
      _needsKey = false;
      _items = const [];
    });
    try {
      final list = await subtitleService.search(
        query: query,
        year: widget.year,
        languages: _languages.toList(),
        force: force,
      );
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _error = subtitleErrorMessage(e);
        _needsKey = e is SubtitleException && e.needsApiKey;
        _loading = false;
      });
    }
  }

  Future<void> _use(SubtitleCandidate candidate) async {
    if (_busyId != null) return;
    setState(() => _busyId = candidate.id);
    try {
      final file = await subtitleService.downloadAndSave(
        candidate: candidate,
        showKey: widget.showKey,
      );
      if (!mounted) return;
      Navigator.pop(context, file);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      _toast(subtitleErrorMessage(e));
    }
  }

  Future<void> _importFromUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      _toast('先粘贴字幕直链');
      return;
    }
    setState(() => _importing = true);
    try {
      final file = await subtitleService.importFromUrl(
        url: url,
        showKey: widget.showKey,
      );
      if (!mounted) return;
      Navigator.pop(context, file);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      _toast(subtitleErrorMessage(e));
    }
  }

  Future<void> _selectLocal(SubtitleFile file) async {
    await subtitleStore.select(widget.showKey, file);
    if (!mounted) return;
    Navigator.pop(context, file);
  }

  Future<void> _deleteLocal(SubtitleFile file) async {
    final inUse = _current?.path == file.path;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除字幕'),
        content: Text(
          inUse
              ? '「${file.label}」是本剧当前正在使用的字幕，删除后画面会关闭字幕。'
              : '确定删除「${file.label}」吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await subtitleStore.removeFile(file);
    if (!mounted) return;
    _toast('已删除这条字幕');
  }

  Future<void> _saveApiKey() async {
    await subtitleStore.setApiKey(_apiKey.text);
    if (!mounted) return;
    _toast(subtitleStore.apiKey.isEmpty ? '已清空 API Key（走匿名通道）' : '已保存 API Key');
  }

  Future<void> _openKeyPage() async {
    final uri = Uri.parse('https://www.opensubtitles.com/en/consumers');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast('无法打开浏览器');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('字幕'),
            Text(
              widget.showTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 跟随主题：浅色模式下白色副标题会看不见
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '在线搜索'),
            Tab(text: '本地与直链'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildSearchTab(),
          _buildLocalTab(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 在线搜索

  Widget _buildSearchTab() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _keyword,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '片名 / 英文名，例如 Frieren',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                tooltip: '搜索',
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: _search,
              ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_suggestions.length > 1)
          // 不固定高度：大字号机型上 ActionChip 会超 38dp 被裁
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final s in _suggestions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(s, style: const TextStyle(fontSize: 11)),
                      onPressed: () => _search(keyword: s),
                    ),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 6,
              children: [
                for (final option in SubtitleLanguageOption.options)
                  FilterChip(
                    label: Text(option.label,
                        style: const TextStyle(fontSize: 11)),
                    selected: _languages.contains(option.value),
                    onSelected: (on) {
                      setState(() {
                        if (on) {
                          _languages.add(option.value);
                        } else if (_languages.length > 1) {
                          _languages.remove(option.value);
                        }
                      });
                      subtitleStore.setLanguages(_languages.toList());
                    },
                  ),
              ],
            ),
          ),
        ),
        Expanded(child: _buildSearchBody()),
        _sourceHint(),
      ],
    );
  }

  Widget _buildSearchBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      final needsKey = _needsKey;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.tonal(
                    onPressed: () => _search(force: true),
                    child: const Text('重试'),
                  ),
                  if (needsKey)
                    OutlinedButton.icon(
                      onPressed: () => _tabs.animateTo(1),
                      icon: const Icon(Icons.vpn_key_rounded, size: 16),
                      label: const Text('填入 API Key'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '没有搜到字幕\n换成英文名、或用「本地与直链」导入字幕文件',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: _items.length,
      itemBuilder: (context, i) => _candidateTile(_items[i]),
    );
  }

  Widget _candidateTile(SubtitleCandidate c) {
    final busy = _busyId == c.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: busy ? null : () => _use(c),
        title: Text(
          c.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, height: 1.35),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _pill(c.languageLabel, Theme.of(context).colorScheme.primary),
              if (c.year != null) _pill('${c.year}', Colors.blueGrey),
              if (c.hd) _pill('HD', Colors.teal),
              _pill('${_downloadsText(c.downloads)} 次下载', Colors.blueGrey),
              if (!c.freeDownloadable)
                _pill('需 API Key', Theme.of(context).colorScheme.error),
            ],
          ),
        ),
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : IconButton(
                tooltip: '下载并使用',
                icon: const Icon(Icons.download_rounded),
                onPressed: () => _use(c),
              ),
      ),
    );
  }

  Widget _sourceHint() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Text(
        '字幕来自 OpenSubtitles。匿名可搜索，但下载有频率限制；'
        '需要更多额度可在「本地与直链」里填写免费 API Key。',
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }

  // -------------------------------------------------------- 本地与直链

  Widget _buildLocalTab() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        if (_localFiles.isNotEmpty) ...[
          _sectionTitle(Icons.folder_open_rounded, '本剧字幕（${_localFiles.length}）'),
          const SizedBox(height: 6),
          for (final f in _localFiles)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                onTap: () => _selectLocal(f),
                leading: Icon(
                  _current?.path == f.path
                      ? Icons.check_circle_rounded
                      : Icons.subtitles_outlined,
                  color: _current?.path == f.path ? scheme.primary : null,
                ),
                title: Text(f.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  [
                    f.languageLabel,
                    if (f.hasDelay) '延迟 ${f.delayText}',
                    f.source == 'url' ? '直链导入' : 'OpenSubtitles',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: () => _deleteLocal(f),
                ),
              ),
            ),
          const SizedBox(height: 12),
        ],
        _sectionTitle(Icons.link_rounded, '从直链导入'),
        const SizedBox(height: 6),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'https://…/xxx.srt（也支持 .ass / .vtt / .zip / .gz）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '字幕站给出的文件直链可以直接粘进来，下载后会自动转成 UTF-8。',
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _importing ? null : _importFromUrl,
                      child: _importing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('导入'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle(Icons.vpn_key_rounded, 'OpenSubtitles API Key（可选）'),
        const SizedBox(height: 6),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _apiKey,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '留空则使用匿名通道',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: _openKeyPage,
                      child: const Text('去申请免费 Key'),
                    ),
                    const Spacer(),
                    FilledButton.tonal(
                      onPressed: _saveApiKey,
                      child: const Text('保存'),
                    ),
                  ],
                ),
                Text(
                  '填了 Key 会走高额度通道，下载也更稳定；Key 只保存在本机。',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '提示：内置字幕源只有 OpenSubtitles。国内字幕站多为压缩包且防盗链，'
          '本应用不内置抓取；需要时把直链粘到上面导入即可。字幕版权归原作者所有。',
          style: TextStyle(
              fontSize: 11, height: 1.6, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _sectionTitle(IconData icon, String title) => Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      );

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );

  String _downloadsText(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }
}
