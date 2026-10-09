import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'screens/ledger_home_page.dart';
import 'services/github_backup_scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    await GitHubBackupScheduler.instance.initialize();
    await Workmanager().initialize(githubBackupCallbackDispatcher);
  }
  runApp(const LedgerApp());
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  static const _pikachuYellow = Color(0xFFFFC928);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '皮卡丘记账',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _pikachuYellow),
        scaffoldBackgroundColor: const Color(0xFFFFFAE9),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFAE9),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const LedgerHomePage(),
    );
  }
}
