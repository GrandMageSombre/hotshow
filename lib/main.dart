import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/history_page.dart';
import 'pages/home_page.dart';
import 'pages/search_page.dart';
import 'services/history_store.dart';
import 'services/offline_cache.dart';
import 'services/playback_store.dart';
import 'services/show_service.dart';
import 'services/source_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit（libmpv）需要在 runApp 前完成原生初始化
  MediaKit.ensureInitialized();
  historyStore.load();
  sourceStore.load();
  playbackStore.load();
  offlineCache.load();
  runApp(const HotShowApp());
}

class HotShowApp extends StatelessWidget {
  final ShowService? service;
  final bool autoRefresh;
  const HotShowApp({super.key, this.service, this.autoRefresh = true});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFE5455C);
    return MaterialApp(
      title: '热剧速览',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: _HomeShell(service: service, autoRefresh: autoRefresh),
    );
  }
}

class _HomeShell extends StatefulWidget {
  final ShowService? service;
  final bool autoRefresh;
  const _HomeShell({this.service, this.autoRefresh = true});

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomePage(service: widget.service, autoRefresh: widget.autoRefresh),
          SearchPage(service: widget.service),
          HistoryPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.local_fire_department_outlined),
            selectedIcon: Icon(Icons.local_fire_department_rounded),
            label: '热播',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_rounded),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_rounded),
            label: '历史',
          ),
        ],
      ),
    );
  }
}
