import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/show_item.dart';

/// 本地历史记录：搜索关键词 + 浏览条目。
/// Android 存于应用私有目录，Windows 存于用户配置目录，双端一致。
class HistoryStore extends ChangeNotifier {
  static const _kSearch = 'history_search';
  static const _kView = 'history_view';
  static const int _maxSearch = 30;
  static const int _maxView = 100;

  final List<String> searchHistory = [];
  final List<ShowItem> viewHistory = [];

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    searchHistory
      ..clear()
      ..addAll(sp.getStringList(_kSearch) ?? const []);
    viewHistory
      ..clear()
      ..addAll((sp.getStringList(_kView) ?? const [])
          .map((s) => jsonDecode(s))
          .whereType<Map<String, dynamic>>()
          .map(ShowItem.fromJson)
          .toList());
    notifyListeners();
  }

  Future<void> addSearch(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    searchHistory
      ..remove(kw)
      ..insert(0, kw);
    if (searchHistory.length > _maxSearch) {
      searchHistory.removeRange(_maxSearch, searchHistory.length);
    }
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kSearch, searchHistory);
  }

  Future<void> removeSearch(String keyword) async {
    searchHistory.remove(keyword);
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kSearch, searchHistory);
  }

  Future<void> clearSearch() async {
    if (searchHistory.isEmpty) return;
    searchHistory.clear();
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kSearch, searchHistory);
  }

  Future<void> addView(ShowItem item) async {
    viewHistory
      ..remove(item)
      ..insert(0, item);
    if (viewHistory.length > _maxView) {
      viewHistory.removeRange(_maxView, viewHistory.length);
    }
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
        _kView, viewHistory.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> removeView(ShowItem item) async {
    viewHistory.remove(item);
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(
        _kView, viewHistory.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> clearView() async {
    if (viewHistory.isEmpty) return;
    viewHistory.clear();
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_kView, const []);
  }
}

final HistoryStore historyStore = HistoryStore();
