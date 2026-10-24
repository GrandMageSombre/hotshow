import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 某个影视资源的播放进度（用于「继续播放」）
class PlaybackRecord {
  /// 资源唯一键：`siteId#vodId`
  final String key;
  final int groupIndex;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final String title;
  final String episodeName;
  final int updatedAt;

  const PlaybackRecord({
    required this.key,
    required this.groupIndex,
    required this.episodeIndex,
    required this.positionMs,
    this.durationMs = 0,
    this.title = '',
    this.episodeName = '',
    required this.updatedAt,
  });

  bool get hasProgress => positionMs > 5000;

  /// 是否已基本看完（剩余不足 3% 时不再提示续播）
  bool get finished =>
      durationMs > 0 && positionMs > durationMs - durationMs * 0.03;

  String get positionText {
    final d = Duration(milliseconds: positionMs);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'groupIndex': groupIndex,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'title': title,
        'episodeName': episodeName,
        'updatedAt': updatedAt,
      };

  factory PlaybackRecord.fromJson(Map<String, dynamic> j) => PlaybackRecord(
        key: j['key']?.toString() ?? '',
        groupIndex: (j['groupIndex'] as num?)?.toInt() ?? 0,
        episodeIndex: (j['episodeIndex'] as num?)?.toInt() ?? 0,
        positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        title: j['title']?.toString() ?? '',
        episodeName: j['episodeName']?.toString() ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 播放进度持久化（本地）。
class PlaybackStore extends ChangeNotifier {
  static const _kRecords = 'playback_records';
  static const _maxRecords = 200;

  final Map<String, PlaybackRecord> _records = {};
  bool _loaded = false;

  List<PlaybackRecord> get records => _records.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  PlaybackRecord? of(String key) => _records[key];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    for (final s in sp.getStringList(_kRecords) ?? const <String>[]) {
      try {
        final r = PlaybackRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
        if (r.key.isNotEmpty) _records[r.key] = r;
      } catch (_) {
        // 忽略损坏记录
      }
    }
    notifyListeners();
  }

  Future<void> save(PlaybackRecord record) async {
    if (record.key.isEmpty) return;
    _records[record.key] = record;
    if (_records.length > _maxRecords) {
      final sorted = records;
      for (final r in sorted.skip(_maxRecords)) {
        _records.remove(r.key);
      }
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
      _kRecords,
      _records.values.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }

  Future<void> remove(String key) async {
    _records.remove(key);
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
      _kRecords,
      _records.values.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }
}

final playbackStore = PlaybackStore();
