import 'package:flutter/material.dart';

import '../models/show_item.dart';
import '../services/history_store.dart';
import '../widgets/common_views.dart';
import '../widgets/show_card.dart';
import 'search_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    super.initState();
    historyStore.load();
  }

  void _openSearch(String kw) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchPage(initialQuery: kw)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史记录')),
      body: ListenableBuilder(
        listenable: historyStore,
        builder: (context, _) {
          if (historyStore.viewHistory.isEmpty &&
              historyStore.searchHistory.isEmpty) {
            return const EmptyHint(message: '暂无历史记录\n看过的剧和搜过的词都会出现在这里');
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (historyStore.searchHistory.isNotEmpty) ...[
                _sectionHeader(
                  icon: Icons.manage_search_rounded,
                  title: '搜索历史',
                  onClear: historyStore.clearSearch,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final kw in historyStore.searchHistory)
                      InputChip(
                        label: Text(kw),
                        onPressed: () => _openSearch(kw),
                        onDeleted: () => historyStore.removeSearch(kw),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
              ],
              if (historyStore.viewHistory.isNotEmpty) ...[
                _sectionHeader(
                  icon: Icons.visibility_rounded,
                  title: '浏览历史',
                  onClear: historyStore.clearView,
                ),
                const SizedBox(height: 12),
                LayoutBuilder(builder: (context, box) {
                  final cardW = gridCardWidth(box.maxWidth);
                  final columns = (box.maxWidth / 118).floor().clamp(2, 6);
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 14,
                      childAspectRatio: cardW / (cardW * 1.4 + 62),
                    ),
                    itemCount: historyStore.viewHistory.length,
                    itemBuilder: (context, i) {
                      final ShowItem item = historyStore.viewHistory[i];
                      return ShowCard(item: item, coverWidth: cardW);
                    },
                  );
                }),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader({
    required IconData icon,
    required String title,
    required VoidCallback onClear,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        TextButton(onPressed: onClear, child: const Text('清空')),
      ],
    );
  }
}
