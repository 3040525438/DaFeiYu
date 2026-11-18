/// 应用入口：底部导航（聊天 / 模型配置），依赖由 AppContainer 注入。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_container.dart';
import 'features/chat/chat_page.dart';
import 'features/settings/model_config_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = await AppContainer.create();
  runApp(
    ChangeNotifierProvider<AppContainer>.value(
      value: container,
      child: const DaFeiYuApp(),
    ),
  );
}

class DaFeiYuApp extends StatelessWidget {
  const DaFeiYuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '大肥鱼',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7A6FF0),
        fontFamily: 'sans-serif',
      ),
      home: const _RootScaffold(),
    );
  }
}

class _RootScaffold extends StatefulWidget {
  const _RootScaffold();

  @override
  State<_RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends State<_RootScaffold> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const <Widget>[
          ChatPage(),
          ModelConfigPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int index) => setState(() => _tab = index),
        destinations: const <Widget>[
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: '聊天'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
        ],
      ),
    );
  }
}
