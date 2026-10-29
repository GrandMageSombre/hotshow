import 'package:flutter/material.dart';

import '../models/facet.dart';
import '../models/genre.dart';
import '../services/paged_show_list.dart';
import '../services/show_service.dart';
import '../widgets/facet_menu.dart';
import '../widgets/genre_bar.dart';
import '../widgets/paged_show_grid.dart';

/// 单个「类型」的浏览页：详情页点类型标签、搜索结果都能跳这里。
/// 页内可继续横切类型，并按地区/年份进一步收窄。
class GenrePage extends StatefulWidget {
  final HotTab tab;
  final Genre genre;
  final ShowService? service;

  const GenrePage({
    super.key,
    required this.tab,
    required this.genre,
    this.service,
  });

  @override
  State<GenrePage> createState() => _GenrePageState();
}

class _GenrePageState extends State<GenrePage> {
  late final ShowService _service = widget.service ?? ShowService();
  late final List<Genre> _genres = () {
    final base = genresOf(widget.tab);
    // 详情页可能传来表里没有的类型，补到第二位保证能被选中高亮
    if (base.contains(widget.genre)) return base;
    return [base.first, widget.genre, ...base.skip(1)];
  }();
  late final List<FacetOption> _years = buildYears(DateTime.now().year);
  late FilterSelection _selection = FilterSelection(genre: widget.genre);
  late PagedShowList _list = _makeList(_selection)..reset();

  PagedShowList _makeList(FilterSelection sel) {
    return PagedShowList(
      loader: (start) => _service.fetchFiltered(
        tab: widget.tab,
        selection: sel,
        start: start,
      ),
    );
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  void _apply(FilterSelection sel) {
    if (sel == _selection) return;
    final old = _list;
    setState(() {
      _selection = sel;
      _list = _makeList(sel);
    });
    old.dispose();
    _list.reset(); // 先挂载再请求
  }

  /// 传进来的类型可能不在本域类型表里（详情页跳转），仍要让它高亮
  Genre _selGenre() {
    final s = _selection.genre;
    return _genres.contains(s) ? s : _genres.first;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selection.genreTag.isEmpty
            ? '${widget.tab.label}·全部'
            : _selection.genreLabel),
      ),
      body: Column(
        children: [
          GenreBar(
            genres: _genres,
            selected: _selGenre(),
            onSelected: (g) => _apply(_selection.copyWith(genre: g)),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                FacetMenu(
                  label: '地区',
                  options: kAreas,
                  selected: _selection.area,
                  onSelected: (o) => _apply(_selection.copyWith(area: o)),
                ),
                const SizedBox(width: 8),
                FacetMenu(
                  label: '年份',
                  options: _years,
                  selected: _selection.year,
                  onSelected: (o) => _apply(_selection.copyWith(year: o)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _selection.isAll ? '全部类型' : _selection.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: PagedShowGrid(
              list: _list,
              onRefresh: () async => _list.reset(),
              emptyMessage: '这个组合暂无内容，换个类型或地区试试',
            ),
          ),
        ],
      ),
    );
  }
}
