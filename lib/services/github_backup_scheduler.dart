import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter/widgets.dart';

import 'github_backup_service.dart';

const githubBackupTaskName = 'weekly-github-ledger-backup';
const githubBackupUniqueName = 'weekly-github-ledger-backup-unique';
const _notificationId = 7001;

class GitHubBackupScheduler {
  GitHubBackupScheduler._();

  static final instance = GitHubBackupScheduler._();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_bolt'),
      ),
    );
  }

  Future<bool> enableWeekly() async {
    final permission = await _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();

    await Workmanager().registerPeriodicTask(
      githubBackupUniqueName,
      githubBackupTaskName,
      frequency: const Duration(days: 7),
      initialDelay: const Duration(days: 7),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );

    if (permission == false) return false;
    await _notifications.periodicallyShow(
      id: _notificationId,
      title: '皮卡丘记账备份提醒',
      body: '如需访问 GitHub，请先打开 VPN。加密备份会在网络可用时上传到你选择的私有仓库。',
      repeatInterval: RepeatInterval.weekly,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'weekly_github_backup',
          'GitHub 备份提醒',
          channelDescription: '提醒你检查 GitHub 加密备份。',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
    return true;
  }

  Future<void> disableWeekly() async {
    await Workmanager().cancelByUniqueName(githubBackupUniqueName);
    await _notifications.cancel(id: _notificationId);
  }
}

@pragma('vm:entry-point')
void githubBackupCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != githubBackupTaskName) return true;
    try {
      return await GitHubBackupService().uploadIfEnabled();
    } catch (_) {
      // Returning false asks WorkManager to retry with its configured backoff.
      return false;
    }
  });
}
