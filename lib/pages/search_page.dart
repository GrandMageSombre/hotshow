import 'dart:async';

import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../services/history_store.dart';
import '../services/show_service.dart';
import '../widgets/common_views.dart';
import '../widgets/show_card.dart';
import '../widgets/show_grid.dart';

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
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  List<ShowItem> _items = [];
  bool _loading = false;
  Object? _error;
  bool _hasMore = true;
  int _start = 0;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    historyStore.load();
    _scroll.addListener(_onScroll);
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
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _items = [];
        _error = null;
        _loading = false;
        _lastQuery = '';
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), _search);
  }

  void _submit() {
    _debounce?.cancel();
    _search(record: true);
  }

  Future<void> _search({bool record = false}) async {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;
    _lastQuery = kw;
    setState(() {
      _loading = true;
      _error = null;
      _start = 0;
      _hasMore = true;
    });
    if (record) historyStore.addSearch(kw);
    try {
      final list = await _service.search(kw);
      if (!mounted || kw != _lastQuery) return;
      setState(() {
        _items = list;
        _loading = false;
        _start = list.length;
        _hasMore = list.length >= 10;
      });
    } catch (e) {
      if (!mounted || kw != _lastQuery) return;
      setState(() {
        _error = e;
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore || _items.isEmpty) return;
    final kw = _lastQuery;
    setState(() => _loading = true);
    try {
      final list = await _service.search(kw, start: _start);
      if (!mounted || kw != _lastQuery) return;
      setState(() {
        _items = [..._items, ...list];
        _start += list.length;
        _hasMore = list.length >= 10;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _hasMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              hintText: '搜索电视剧 / 短剧 / 动漫 / 电影…',
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
      body: _controller.text.trim().isEmpty && _items.isEmpty
          ? _buildSearchHistory()
          : _buildResults(),
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

  Widget _buildResults() {
    if (_error != null && _items.isEmpty) {
      return ErrorRetry(error: _error, onRetry: () => _search(record: false));
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return EmptyHint(message: '没有找到「${_controller.text.trim()}」相关的内容');
    }
    return LayoutBuilder(builder: (context, box) {
      final metrics = ShowGridMetrics.resolve(
        availableWidth:
            box.maxWidth - ShowGridMetrics.horizontalPadding * 2,
        textScaler: MediaQuery.textScalerOf(context),
      );
      return GridView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          ShowGridMetrics.horizontalPadding,
          12,
          ShowGridMetrics.horizontalPadding,
          12,
        ),
        gridDelegate: metrics.delegate(),
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return ListTail(hasMore: _hasMore || _loading);
          }
          return ShowCard(item: _items[i]);
        },
      );
    });
  }
}
