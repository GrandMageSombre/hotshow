import 'dart:async';

import 'package:flutter/material.dart';

import '../models/facet.dart';
import '../models/genre.dart';
import '../services/history_store.dart';
import '../services/paged_show_list.dart';
import '../services/show_service.dart';
import '../widgets/common_views.dart';
import '../widgets/genre_bar.dart';
import '../widgets/paged_show_grid.dart';

class SearchPage extends StatefulWidget {
  final String? initialQuery;
  final ShowService? service;
  const SearchPage({super.key, this.initialQuery, this.service});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final ShowService _service = widget.service ?? ShowService();
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  String _lastQuery = '';

  /// 关键词搜索的分页状态（loader 读 [_lastQuery]）
  late final PagedShowList _searchList =
      PagedShowList(loader: (start) => _service.search(_lastQuery, start: start));

  /// 非空表示当前是「按类型浏览」，用独立的分页状态
  Genre? _genre;
  PagedShowList? _genreList;

  @override
  void initState() {
    super.initState();
    historyStore.load();
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      _controller.text = widget.initialQuery!;
      // 等首帧渲染完再执行搜索
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    _searchList.dispose();
    _genreList?.dispose();
    super.dispose();
  }

  void _exitGenre() {
    final old = _genreList;
    if (old == null) return;
    setState(() {
      _genre = null;
      _genreList = null;
    });
    old.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      _lastQuery = '';
      _searchList.reset(); // 空关键词 → loader 返回空，等于清空
      if (_genre != null) _exitGenre();
      return;
    }
    // 一旦开始输入关键词，就退出「按类型浏览」
    if (_genre != null) _exitGenre();
    _debounce = Timer(const Duration(milliseconds: 600), _search);
  }

  void _submit() {
    _debounce?.cancel();
    _search(record: true);
  }

  /// 点类型条：切到按类型浏览模式
  void _selectGenre(Genre g) {
    _debounce?.cancel();
    _controller.clear();
    _focus.unfocus();
    if (g.isAll) {
      _lastQuery = '';
      _exitGenre();
      return;
    }
    final list = PagedShowList(
      loader: (start) => _service.fetchFiltered(
        tab: HotTab.tv,
        selection: FilterSelection.genreOnly(g),
        start: start,
      ),
    );
    list.reset();
    final old = _genreList;
    setState(() {
      _genre = g;
      _genreList = list;
      _lastQuery = '';
    });
    old?.dispose();
  }

  Future<void> _search({bool record = false}) async {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;
    _lastQuery = kw;
    if (record) historyStore.addSearch(kw);
    if (_genre != null) _exitGenre();
    await _searchList.reset();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final browsing = _genreList != null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: widget.initialQuery == null,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submit(),
            onChanged: _onChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索电视剧 / 电影 / 短剧 / 动漫…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                        _focus.requestFocus();
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          GenreBar(
            genres: kSearchGenres,
            selected: _genre ?? kGenreAll,
            onSelected: _selectGenre,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          ),
          if (_genre != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.filter_alt_outlined,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    '正在按「${_genre!.label}」浏览 · 输入关键词可退出',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: browsing
                ? PagedShowGrid(
                    key: const ValueKey('genre-browse'),
                    list: _genreList!,
                    onRefresh: () async => _genreList!.reset(),
                    emptyMessage: '「${_genre!.label}」暂无内容，换个类型试试',
                  )
                : (_lastQuery.isEmpty
                    ? _buildSearchHistory()
                    : PagedShowGrid(
                        key: const ValueKey('keyword-search'),
                        list: _searchList,
                        onRefresh: () async => _searchList.reset(),
                        emptyMessage: '没有找到「$_lastQuery」相关的内容',
                      )),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHistory() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (historyStore.searchHistory.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyHint(message: '输入片名开始搜索，例如「庆余年」「芙莉莲」'),
          )
        else ...[
          Row(
            children: [
              const Icon(Icons.history_rounded, size: 18),
              const SizedBox(width: 6),
              const Text('搜索历史', style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(
                onPressed: historyStore.clearSearch,
                child: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kw in historyStore.searchHistory)
                InputChip(
                  label: Text(kw),
                  onPressed: () {
                    _controller.text = kw;
                    _submit();
                  },
                  onDeleted: () => historyStore.removeSearch(kw),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
