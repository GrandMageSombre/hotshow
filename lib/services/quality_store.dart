import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'quality_service.dart';

/// 一部剧记住的清晰度偏好。
///
/// 只记**标签**（`auto` / `1080P` / …）+ 最近一次的**变体地址**：
/// - 标签用来在别的集上按名字找回同一档；
/// - 变体地址配 `masterUrl` 用，只对「同一集重看」有效（片源地址带签名，隔天会失效，
///   失效时播放页会退回线路默认地址并清掉这条记忆）。
class QualityPreference {
  final String label;
  final String masterUrl;
  final String? variantUrl;

  const QualityPreference({
    required this.label,
    this.masterUrl = '',
    this.variantUrl,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        if (masterUrl.isNotEmpty) 'masterUrl': masterUrl,
        if (variantUrl != null) 'variant': variantUrl,
      };

  static QualityPreference? fromJson(Object? raw) {
    // 老格式直接是字符串（只有标签），兼容一下
    if (raw is String && raw.isNotEmpty) return QualityPreference(label: raw);
    if (raw is Map) {
      final label = raw['label']?.toString() ?? '';
      if (label.isEmpty) return null;
      return QualityPreference(
        label: label,
        masterUrl: raw['masterUrl']?.toString() ?? '',
        variantUrl: raw['variant']?.toString(),
      );
    }
    return null;
  }
}

/// 每部剧记住上次选的清晰度（和「字幕记住」一个思路）。
///
/// 播放页的应用策略刻意保守：**只在不需要额外联网时**才用它——
/// 同一集重看（有变体地址）或码率表已被预热进缓存（能按标签解析出来）。
/// 其它情况按线路默认地址起播，不为了一次偏好多抓一次 master 拖慢起播。
class QualityStore extends ChangeNotifier {
  static const _kPrefs = 'quality_choice_by_show';

  final Map<String, QualityPreference> _byShow = {};

  bool _loaded = false;

  /// 仅供测试：清空内存状态（单例，用例之间会互相影响）
  @visibleForTesting
  void debugReset() {
    _byShow.clear();
    _loaded = false;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kPrefs);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (k is! String || k.isEmpty) return;
          final pref = QualityPreference.fromJson(v);
          if (pref != null) _byShow[k] = pref;
        });
      }
      notifyListeners();
    } catch (e) {
      debugPrint('QualityStore: 读取失败 $e');
    }
  }

  String? labelFor(String showKey) => _byShow[showKey]?.label;

  /// 该 master 地址上次用的变体地址（只对同一集有效）
  String? variantFor(String masterUrl) {
    if (masterUrl.isEmpty) return null;
    for (final p in _byShow.values) {
      if (p.masterUrl == masterUrl) return p.variantUrl;
    }
    return null;
  }

  /// 记住选择；[label] 传 null 表示忘掉这部剧的偏好
  Future<void> remember(
    String showKey,
    String? label, {
    String masterUrl = '',
    String? variantUrl,
  }) async {
    if (showKey.isEmpty) return;
    if (label == null || label.isEmpty) {
      if (_byShow.remove(showKey) == null) return;
    } else {
      final old = _byShow[showKey];
      if (old != null &&
          old.label == label &&
          old.masterUrl == masterUrl &&
          old.variantUrl == variantUrl) {
        return;
      }
      _byShow[showKey] = QualityPreference(
        label: label,
        masterUrl: masterUrl,
        variantUrl: variantUrl,
      );
    }
    notifyListeners();
    await _persist();
  }

  /// 变体地址失效（起播失败）时把这条记忆清掉，避免每次都先失败一次
  Future<void> forgetVariant(String masterUrl) async {
    var changed = false;
    for (final entry in _byShow.entries.toList()) {
      final p = entry.value;
      if (p.masterUrl == masterUrl && p.variantUrl != null) {
        _byShow[entry.key] = QualityPreference(
          label: p.label,
          masterUrl: p.masterUrl,
        );
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kPrefs,
        jsonEncode({
          for (final e in _byShow.entries) e.key: e.value.toJson(),
        }),
      );
    } catch (e) {
      debugPrint('QualityStore: 保存失败 $e');
    }
  }
}

/// 全局单例（与 offlineCache / subtitleStore 等同一范式）
final QualityStore qualityStore = QualityStore();

/// 在候选里找出与记忆标签对应的选项。
/// `auto` 只认「自动」那一项；其余按标签精确匹配（只认变体，不认线路）。
QualityOption? resolveRemembered(
  String? label,
  List<QualityOption> options,
) {
  if (label == null || label.isEmpty) return null;
  for (final o in options) {
    if (o.isGroup) continue;
    if (label == 'auto' && o.isAuto) return o;
    if (label != 'auto' && o.label == label) return o;
  }
  return null;
}
