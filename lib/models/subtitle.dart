/// 字幕相关的数据模型：在线搜索结果 + 已落盘到本地的字幕文件。
library;

/// 语言代码 → 中文标签（OpenSubtitles 用 `zh-cn` / `zh-tw` / `pt-br` 这类写法）
String subtitleLanguageLabel(String code) {
  final c = code.trim().toLowerCase().replaceAll('_', '-');
  if (c.isEmpty) return '未知';
  if (c.startsWith('zh')) {
    if (c.contains('tw') || c.contains('hant') || c.contains('hk')) return '繁体';
    return '简体';
  }
  const names = {
    'en': '英文',
    'ja': '日文',
    'ko': '韩文',
    'fr': '法文',
    'de': '德文',
    'es': '西班牙文',
    'ru': '俄文',
    'it': '意大利文',
    'pt': '葡萄牙文',
    'th': '泰文',
    'vi': '越南文',
    'ar': '阿拉伯文',
  };
  final base = c.split('-').first;
  return names[base] ?? c.toUpperCase();
}

/// 字幕语言筛选项：value 会拼进 OpenSubtitles 的 `languages` 参数
class SubtitleLanguageOption {
  final String value;
  final String label;

  const SubtitleLanguageOption(this.value, this.label);

  static const options = [
    SubtitleLanguageOption('zh-cn', '简体'),
    SubtitleLanguageOption('zh-tw', '繁体'),
    SubtitleLanguageOption('en', '英文'),
    SubtitleLanguageOption('ja', '日文'),
    SubtitleLanguageOption('ko', '韩文'),
  ];
}

/// 一条在线字幕搜索结果
class SubtitleCandidate {
  /// 来源标识，目前只有 `opensubtitles`
  final String source;
  final String id;

  /// 发布名（通常带片源版本，如 `Show.2023.1080p.WEB-DL.chs`）
  final String title;
  final String language;

  /// 字幕格式：srt / ass / vtt …
  final String format;
  final int downloads;
  final bool hd;
  final int? year;

  /// OpenSubtitles 旧站 ID：免 Key 的 `dl.opensubtitles.org` 下载靠它
  final int? legacyId;

  /// OpenSubtitles 新 API 的 file_id：填了 API Key 时走官方下载接口
  final int? fileId;
  final String pageUrl;

  const SubtitleCandidate({
    required this.source,
    required this.id,
    required this.title,
    required this.language,
    this.format = 'srt',
    this.downloads = 0,
    this.hd = false,
    this.year,
    this.legacyId,
    this.fileId,
    this.pageUrl = '',
  });

  String get languageLabel => subtitleLanguageLabel(language);

  /// 是否具备「不填 API Key 也能下载」的通道
  bool get freeDownloadable => legacyId != null;
}

/// 已保存到本机的字幕。
///
/// [basePath] 是下载后统一转成 UTF-8 的原文件，[path] 是实际交给播放器的文件：
/// 调整时间轴时不会改动原文件，而是从 [basePath] 生成一份带偏移的副本，
/// 因此反复微调不会累积误差。
class SubtitleFile {
  final String showKey;
  final String basePath;
  final String path;
  final String label;
  final String language;
  final String source;
  final int delayMs;
  final int addedAt;

  const SubtitleFile({
    required this.showKey,
    required this.basePath,
    required this.path,
    required this.label,
    required this.language,
    required this.source,
    this.delayMs = 0,
    this.addedAt = 0,
  });

  String get languageLabel => subtitleLanguageLabel(language);

  bool get hasDelay => delayMs != 0;

  String get delayText {
    if (delayMs == 0) return '无偏移';
    final seconds = (delayMs / 1000).toStringAsFixed(1);
    return delayMs > 0 ? '+${seconds}s' : '${seconds}s';
  }

  SubtitleFile copyWith({
    String? path,
    String? label,
    String? language,
    int? delayMs,
  }) =>
      SubtitleFile(
        showKey: showKey,
        basePath: basePath,
        path: path ?? this.path,
        label: label ?? this.label,
        language: language ?? this.language,
        source: source,
        delayMs: delayMs ?? this.delayMs,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'showKey': showKey,
        'basePath': basePath,
        'path': path,
        'label': label,
        'language': language,
        'source': source,
        'delayMs': delayMs,
        'addedAt': addedAt,
      };

  factory SubtitleFile.fromJson(Map<String, dynamic> j) => SubtitleFile(
        showKey: j['showKey']?.toString() ?? '',
        basePath: j['basePath']?.toString() ?? '',
        path: j['path']?.toString() ?? '',
        label: j['label']?.toString() ?? '',
        language: j['language']?.toString() ?? '',
        source: j['source']?.toString() ?? '',
        delayMs: (j['delayMs'] as num?)?.toInt() ?? 0,
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
      );
}
