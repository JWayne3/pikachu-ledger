import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ledger_database.dart';
import '../models/ledger_categories.dart';
import '../models/ledger_entry.dart';
import 'ledger_statistics_page.dart';
import '../services/github_backup_service.dart';
import '../services/github_auth_service.dart';
import '../services/ledger_excel_service.dart';
import '../services/tap_sound_service.dart';

class LedgerHomePage extends StatefulWidget {
  const LedgerHomePage({super.key});

  @override
  State<LedgerHomePage> createState() => _LedgerHomePageState();
}

class _LedgerHomePageState extends State<LedgerHomePage>
    with WidgetsBindingObserver {
  final _database = LedgerDatabase.instance;
  final _githubAuth = GitHubAuthService();
  final _githubBackup = GitHubBackupService();
  final _now = DateTime.now();
  late DateTime _displayMonth = DateTime(_now.year, _now.month);

  List<LedgerEntry> _entries = const [];
  bool _loading = true;
  int _selectedTab = 0;
  EntryType? _billFilter;
  String? _categoryFilter;
  int? _monthlyBudget;
  GitHubAccount? _githubAccount;
  GitHubBackupConfig? _githubBackupConfig;
  bool _authenticating = false;
  bool _uploadingBackup = false;
  bool _cancelGitHubSignIn = false;

  List<LedgerEntry> get _monthEntries => _entries
      .where(
        (entry) =>
            entry.date.year == _displayMonth.year &&
            entry.date.month == _displayMonth.month,
      )
      .toList(growable: false);

  int _total(Iterable<LedgerEntry> entries, EntryType type) => entries
      .where((entry) => entry.type == type)
      .fold(0, (total, entry) => total + entry.amountCents);

  @override
  void initState() {
    super.initState();
    unawaited(TapSoundService.initialize());
    WidgetsBinding.instance.addObserver(this);
    _loadEntries();
    _loadGitHubAccount();
    _loadGitHubBackupConfig();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadGitHubAccount();
      _loadGitHubBackupConfig();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _githubAuth.dispose();
    _githubBackup.dispose();
    super.dispose();
  }

  Future<void> _loadGitHubAccount() async {
    final account = await _githubAuth.currentAccount();
    if (mounted) setState(() => _githubAccount = account);
  }

  Future<void> _loadGitHubBackupConfig() async {
    final config = await _githubBackup.loadConfig();
    if (mounted) setState(() => _githubBackupConfig = config);
  }

  Future<void> _signInToGitHub() async {
    if (_authenticating) return;
    try {
      final flow = await _githubAuth.beginSignIn();
      if (!mounted) return;
      final shouldPoll = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('登录 GitHub'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '按下面步骤连接 GitHub：\n1. 点“打开 GitHub”进入授权页。\n2. 输入下面的一次性验证码并确认授权。\n3. 返回应用后，选择或先手动创建一个私有仓库，再设置加密备份。',
              ),
              const SizedBox(height: 12),
              Center(
                child: SelectableText(
                  flow.userCode,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '验证码有效约 15 分钟。授权后返回此应用继续。',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: flow.userCode)),
              icon: const Icon(Icons.copy),
              label: const Text('复制验证码'),
            ),
            TextButton.icon(
              onPressed: () async {
                await launchUrl(
                  flow.verificationUri,
                  mode: LaunchMode.externalApplication,
                );
              },
              icon: const Icon(Icons.open_in_browser),
              label: const Text('打开 GitHub'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('我已授权'),
            ),
          ],
        ),
      );
      if (shouldPoll != true) return;

      setState(() {
        _authenticating = true;
        _cancelGitHubSignIn = false;
      });
      final account = await _githubAuth.waitForAuthorization(
        flow,
        isCancelled: () => _cancelGitHubSignIn,
      );
      if (!mounted) return;
      setState(() => _githubAccount = account);
      _showMessage('已登录 GitHub：${account.login}');
      await _loadGitHubBackupConfig();
      if (_githubBackupConfig == null) {
        await _promptGitHubBackupSetup();
      }
    } catch (error) {
      _showMessage('GitHub 登录失败：$error');
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  Future<void> _promptGitHubBackupSetup() async {
    if (_githubAccount == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('GitHub 已连接'),
        content: const Text(
          '账单默认只保存在手机。请先在 GitHub 创建一个私有仓库（可见性选择 Private），或使用已有的私有仓库。创建后回到账户页点设置按钮，填写仓库信息和加密口令。GitHub 会要求将 App 安装到仓库；请选择 Only select repositories，并只勾选备份仓库。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'later'),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'existing'),
            child: const Text('使用已有仓库'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'create'),
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开 GitHub 创建私有仓库'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'create') {
      final opened = await launchUrl(
        Uri.https('github.com', '/new'),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        _showMessage('无法打开 GitHub。请在浏览器访问 github.com/new 创建私有仓库。');
      }
    } else if (choice == 'existing') {
      await _configureGitHubBackup();
    }
  }

  Future<bool> _installGitHubAppForRepository(
    GitHubRepository repository,
  ) async {
    final slug = GitHubAuthService.appSlug;
    if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(slug)) {
      _showMessage('当前版本未配置 GitHub App 安装链接，请使用应用内的普通仓库设置。');
      return false;
    }
    final installUri = Uri.https('github.com', '/apps/$slug/installations/new');
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('将 App 安装到此仓库'),
        content: Text(
          '下一步会打开 GitHub。\n\n1. 选择你的个人账户。\n2. 选择“Only select repositories”。\n3. 只勾选 ${repository.fullName}。\n4. 确认安装后返回本应用，点击“已完成，继续”。\n\n应用只需要向这个私有仓库写入加密备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开 GitHub 安装页'),
          ),
        ],
      ),
    );
    if (open != true) return false;
    await launchUrl(installUri, mode: LaunchMode.externalApplication);
    if (!mounted) return false;
    final completed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认 GitHub App 安装'),
        content: Text(
          '安装完成后返回此应用。只要你已将 ${repository.fullName} 加入应用可访问的仓库，点“检查并继续”即可。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('已安装，检查权限'),
          ),
        ],
      ),
    );
    return completed == true;
  }

  void _cancelGitHubAuthentication() {
    setState(() => _cancelGitHubSignIn = true);
  }

  Future<void> _signOutOfGitHub() async {
    await _githubBackup.setWeeklyEnabled(false);
    await _githubAuth.signOut();
    if (!mounted) return;
    setState(() {
      _githubAccount = null;
      _githubBackupConfig = _githubBackupConfig == null
          ? null
          : GitHubBackupConfig(
              owner: _githubBackupConfig!.owner,
              repository: _githubBackupConfig!.repository,
              weeklyEnabled: false,
              lastBackupAt: _githubBackupConfig!.lastBackupAt,
            );
    });
    _showMessage('已退出 GitHub，并暂停自动备份');
  }

  Future<void> _configureGitHubBackup() async {
    final current = _githubBackupConfig;
    final setup = await showDialog<_GitHubBackupSetup>(
      context: context,
      builder: (_) => _GitHubBackupSetupDialog(current: current),
    );
    if (setup == null) return;

    try {
      final repository = GitHubRepository(
        owner: setup.owner,
        name: setup.repository,
      );
      var hasWriteAccess = await _githubBackup.hasWriteAccess(
        repository.owner,
        repository.name,
      );
      if (!hasWriteAccess) {
        final installed = await _installGitHubAppForRepository(repository);
        if (!installed) return;
        hasWriteAccess = await _githubBackup.hasWriteAccess(
          repository.owner,
          repository.name,
        );
      }
      if (!hasWriteAccess) {
        throw const GitHubBackupException(
          'GitHub App 仍没有此仓库的内容写入权限。请在安装页只选择该私有仓库后重试。',
        );
      }
      await _githubBackup.configure(
        owner: setup.owner,
        repository: setup.repository,
        passphrase: setup.passphrase,
      );
      final reminderEnabled = await _githubBackup.setWeeklyEnabled(
        setup.weeklyEnabled,
      );
      await _loadGitHubBackupConfig();
      if (!mounted) return;
      _showMessage(
        setup.weeklyEnabled && !reminderEnabled
            ? '私有仓库已验证，自动备份已开启；系统未授予通知权限，提醒未开启。'
            : setup.weeklyEnabled
            ? '私有仓库已验证，每周加密备份已开启。'
            : '私有仓库和加密口令已保存。',
      );
    } catch (error) {
      _showMessage('设置 GitHub 备份失败：$error');
    }
  }

  Future<void> _uploadGitHubBackup() async {
    if (_uploadingBackup) return;
    setState(() => _uploadingBackup = true);
    try {
      await _githubBackup.uploadNow();
      await _loadGitHubBackupConfig();
      _showMessage('加密账本已上传到私有仓库');
    } catch (error) {
      _showMessage('GitHub 备份失败：$error');
    } finally {
      if (mounted) setState(() => _uploadingBackup = false);
    }
  }

  Future<void> _setGitHubWeeklyBackup(bool enabled) async {
    try {
      final reminderEnabled = await _githubBackup.setWeeklyEnabled(enabled);
      await _loadGitHubBackupConfig();
      if (enabled && !reminderEnabled) {
        _showMessage('自动备份已开启，但系统未授予通知权限，提醒未开启。');
      } else {
        _showMessage(enabled ? '每周加密备份已开启' : '每周加密备份已暂停');
      }
    } catch (error) {
      _showMessage('更新自动备份设置失败：$error');
    }
  }

  Future<void> _restoreGitHubBackup() async {
    final passphraseController = TextEditingController();
    final passphrase = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从 GitHub 恢复'),
        content: TextField(
          controller: passphraseController,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '加密口令',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, passphraseController.text),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    passphraseController.dispose();
    if (passphrase == null || passphrase.isEmpty || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('替换本机账本？'),
        content: const Text('恢复会替换本机所有账单和预算。建议先从“更多选项”导出当前账本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('下载并替换'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final snapshot = await _githubBackup.downloadAndDecrypt(passphrase);
      await _database.restoreBackup(snapshot);
      await _loadEntries();
      _showMessage('GitHub 账本已解密并恢复');
    } catch (error) {
      _showMessage('恢复 GitHub 备份失败：$error');
    }
  }

  Future<void> _openGitHubAuthorizations() async {
    final uri = Uri.https('github.com', '/settings/applications');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _installGitHubApp() async {
    final slug = GitHubAuthService.appSlug;
    if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(slug)) {
      _showMessage('这个构建版本暂不可打开 GitHub 备份授权页。');
      return;
    }
    final uri = Uri.https('github.com', '/apps/$slug/installations/new');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _loadEntries() async {
    try {
      final entries = await _database.getEntries();
      final budget = await _database.getMonthlyBudget(_displayMonth);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _monthlyBudget = budget;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('读取本地账单失败：$error');
    }
  }

  Future<void> _showEntryForm({LedgerEntry? initialEntry}) async {
    final entry = await showModalBottomSheet<LedgerEntry>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _EntryForm(initialEntry: initialEntry),
    );
    if (entry == null) return;

    try {
      if (entry.id == null) {
        await _database.insertEntry(entry);
      } else {
        await _database.updateEntry(entry);
      }
      await _loadEntries();
      _showMessage(entry.id == null ? '已保存到本机' : '账单已更新');
    } catch (error) {
      _showMessage('保存账单失败：$error');
    }
  }

  Future<void> _editEntry(LedgerEntry entry) =>
      _showEntryForm(initialEntry: entry);

  Future<void> _editMonthlyBudget() async {
    final controller = TextEditingController(
      text: _monthlyBudget == null
          ? ''
          : (_monthlyBudget! / 100).toStringAsFixed(2),
    );
    final formKey = GlobalKey<FormState>();
    final amount = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${_monthLabel(_displayMonth)}月预算'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '预算金额',
              prefixText: '¥ ',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final amount = double.tryParse(value?.trim() ?? '');
              if (amount == null || amount <= 0) return '请输入大于 0 的金额';
              if (amount > 999999999) return '金额超出范围';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                (double.parse(controller.text.trim()) * 100).round(),
              );
            },
            child: const Text('保存预算'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null) return;

    try {
      await _database.setMonthlyBudget(_displayMonth, amount);
      if (!mounted) return;
      setState(() => _monthlyBudget = amount);
    } catch (error) {
      _showMessage('保存预算失败：$error');
    }
  }

  Future<void> _clearMonthlyBudget() async {
    try {
      await _database.clearMonthlyBudget(_displayMonth);
      if (mounted) setState(() => _monthlyBudget = null);
    } catch (error) {
      _showMessage('清除预算失败：$error');
    }
  }

  Future<void> _exportBackup() async {
    try {
      final snapshot = await _database.createBackupSnapshot();
      final now = DateTime.now();
      final filename =
          'ledger_backup_${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}.json';
      final savedFile = await FilePicker.saveFile(
        dialogTitle: '保存账本备份',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(snapshot))),
      );
      if (savedFile != null) _showMessage('备份已保存');
    } catch (error) {
      _showMessage('导出备份失败：$error');
    }
  }

  Future<void> _exportExcelData() async {
    try {
      final snapshot = await _database.createBackupSnapshot();
      final bytes = LedgerExcelService.encodeSnapshot(snapshot);
      final now = DateTime.now();
      final filename =
          'ledger_data_${now.year}${_twoDigits(now.month)}${_twoDigits(now.day)}.xlsx';
      final savedFile = await FilePicker.saveFile(
        dialogTitle: '导出账本数据到 Excel',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (savedFile != null) _showMessage('Excel 数据已导出');
    } catch (error) {
      _showMessage('导出 Excel 失败：$error');
    }
  }

  Future<void> _importExcelData() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择 Excel 数据文件',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      if (file == null) return;
      final fileLength = await file.length();
      if (fileLength != null && fileLength > 25 * 1024 * 1024) {
        throw const FormatException('文件超过 25 MB，请先拆分后再导入。');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 25 * 1024 * 1024) {
        throw const FormatException('文件超过 25 MB，请先拆分后再导入。');
      }
      final imported = LedgerExcelService.decode(bytes);
      final categoryCount = imported.customCategories.values.fold<int>(
        0,
        (sum, categories) => sum + categories.length,
      );
      if (!mounted) return;
      final issuePreview = imported.issues
          .take(3)
          .map((issue) => issue.toString())
          .join('\n');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('导入 Excel 数据？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '识别到 ${imported.entries.length} 笔账单、'
                  '${imported.monthlyBudgets.length} 个月预算、'
                  '$categoryCount 个自定义分类。',
                ),
                const SizedBox(height: 10),
                const Text(
                  '账单会追加到当前账本，不会覆盖现有记录；同一个文件重复导入可能产生重复账单。相同月份的预算会更新，自定义分类会合并。',
                ),
                if (imported.issues.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '另有 ${imported.issues.length} 行格式有误，将跳过。',
                    style: TextStyle(color: Colors.orange.shade900),
                  ),
                  if (issuePreview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      issuePreview,
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('导入数据'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      await _database.importSpreadsheetData(
        entries: imported.entries,
        monthlyBudgets: imported.monthlyBudgets,
        customCategories: imported.customCategories,
      );
      await _loadEntries();
      final importedParts = <String>[];
      if (imported.entries.isNotEmpty) {
        importedParts.add('${imported.entries.length} 笔账单');
      }
      if (imported.monthlyBudgets.isNotEmpty) {
        importedParts.add('${imported.monthlyBudgets.length} 个月预算');
      }
      if (categoryCount > 0) importedParts.add('$categoryCount 个自定义分类');
      final skipped = imported.issues.isEmpty
          ? ''
          : '，跳过 ${imported.issues.length} 行无效数据';
      _showMessage('已导入 ${importedParts.join('、')}$skipped');
    } on FormatException catch (error) {
      _showMessage('无法导入 Excel：${error.message}');
    } catch (error) {
      _showMessage('导入 Excel 失败：$error');
    }
  }

  Future<void> _restoreBackup() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (file == null) return;

      final decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
      if (decoded is! Map) {
        throw const FormatException('文件内容不是有效的账本备份。');
      }
      final snapshot = decoded.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('恢复账本备份？'),
          content: const Text('恢复会替换本机现有的全部账单和预算。建议先导出当前数据备份。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('替换并恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      await _database.restoreBackup(snapshot);
      await _loadEntries();
      _showMessage('账本已恢复');
    } on FormatException catch (error) {
      _showMessage('无法读取备份：${error.message}');
    } catch (error) {
      _showMessage('恢复备份失败：$error');
    }
  }

  Future<void> _deleteEntry(LedgerEntry entry) async {
    final id = entry.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这笔账单？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _database.deleteEntry(id);
      await _loadEntries();
    } catch (error) {
      _showMessage('删除失败：$error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeMonth(int delta) {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + delta);
      _categoryFilter = null;
    });
    _loadEntries();
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    const tabTitles = ['账本', '账单', '统计', '账户'];
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.bolt, color: Color(0xFFE3A900)),
        title: Text(
          tabTitles[_selectedTab],
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多选项',
            onSelected: (value) {
              if (value == 'exportExcel') {
                _exportExcelData();
              } else if (value == 'importExcel') {
                _importExcelData();
              } else if (value == 'exportBackup') {
                _exportBackup();
              } else if (value == 'restore') {
                _restoreBackup();
              } else if (value == 'about') {
                showAboutDialog(
                  context: context,
                  applicationName: '皮卡丘记账',
                  applicationVersion: '0.1.0',
                  children: const [Text('免费、无广告，账单保存在本机。')],
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'exportExcel',
                child: Row(
                  children: [
                    Icon(Icons.table_view_outlined),
                    SizedBox(width: 12),
                    Text('导出数据（Excel）'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'importExcel',
                child: Row(
                  children: [
                    Icon(Icons.file_open_outlined),
                    SizedBox(width: 12),
                    Text('导入数据（Excel）'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'exportBackup',
                child: Row(
                  children: [
                    Icon(Icons.download_outlined),
                    SizedBox(width: 12),
                    Text('导出备份（JSON）'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'restore',
                child: Row(
                  children: [
                    Icon(Icons.upload_outlined),
                    SizedBox(width: 12),
                    Text('恢复备份（JSON）'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'about',
                child: Row(
                  children: [
                    Icon(Icons.info_outline),
                    SizedBox(width: 12),
                    Text('关于'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _selectedTab,
              children: [
                _buildHomeTab(),
                _buildBillsTab(),
                _buildStatisticsTab(),
                _buildAccountTab(),
              ],
            ),
      floatingActionButton: _selectedTab >= 2
          ? null
          : FloatingActionButton.extended(
              onPressed: () {
                TapSoundService.playRecordDing();
                _showEntryForm();
              },
              enableFeedback: false,
              icon: const Icon(Icons.add),
              label: const Text('记一笔'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: '账单',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            label: '统计',
          ),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '账户'),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    final monthEntries = _monthEntries;
    final income = _total(monthEntries, EntryType.income);
    final expense = _total(monthEntries, EntryType.expense);
    final recent = monthEntries.take(5).toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
      children: [
        _monthPicker(),
        const SizedBox(height: 14),
        _summaryCard(income: income, expense: expense),
        const SizedBox(height: 26),
        _sectionTitle('最近记录', trailing: '${monthEntries.length} 笔'),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          _emptyState(
            icon: Icons.edit_note,
            title: '还没有账单',
            subtitle: '点“记一笔”，开始记录今天的收支。',
          )
        else
          ...recent.map(_entryTile),
      ],
    );
  }

  Widget _buildBillsTab() {
    final monthEntries = _monthEntries;
    final categories =
        monthEntries.map((entry) => entry.category).toSet().toList()..sort();
    final entries = _monthEntries
        .where((entry) => _billFilter == null || entry.type == _billFilter)
        .where(
          (entry) =>
              _categoryFilter == null || entry.category == _categoryFilter,
        )
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
      children: [
        _monthPicker(),
        const SizedBox(height: 14),
        _summaryCard(
          income: _total(_monthEntries, EntryType.income),
          expense: _total(_monthEntries, EntryType.expense),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          children: [
            _filterChip('全部', null),
            _filterChip('支出', EntryType.expense),
            _filterChip('收入', EntryType.income),
          ],
        ),
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              _categoryFilterChip('全部分类', null),
              ...categories.map(
                (category) => _categoryFilterChip(category, category),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (entries.isEmpty)
          _emptyState(
            icon: Icons.receipt_long_outlined,
            title: '这个月还没有账单',
            subtitle: '新增一笔后会显示在这里。',
          )
        else
          ...entries.map(_entryTile),
      ],
    );
  }

  Widget _buildStatisticsTab() {
    return LedgerStatisticsPage(
      entries: _entries,
      initialDate: _displayMonth,
      monthlyBudget: _monthlyBudget,
      onEditMonthlyBudget: _editMonthlyBudget,
      onClearMonthlyBudget: _clearMonthlyBudget,
    );
  }

  Widget _buildAccountTab() {
    final account = _githubAccount;
    final backup = _githubBackupConfig;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(
                      backgroundColor: Color(0xFFFFE28A),
                      foregroundColor: Color(0xFF4B3A0A),
                      child: Icon(Icons.code),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account == null ? 'GitHub 账户' : account.login,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            account == null ? '尚未登录' : '已连接 GitHub',
                            style: TextStyle(color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_authenticating) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text('等待 GitHub 授权……'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _cancelGitHubAuthentication,
                      child: const Text('取消登录'),
                    ),
                  ),
                ] else if (account == null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _signInToGitHub,
                      icon: const Icon(Icons.login),
                      label: const Text('使用 GitHub 登录'),
                    ),
                  ),
                  if (!_githubAuth.isConfigured) ...[
                    const SizedBox(height: 10),
                    Text(
                      '此构建版本暂未启用 GitHub 连接；本地记账仍可正常使用。',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ] else ...[
                  if (backup != null)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _installGitHubApp,
                        icon: const Icon(Icons.manage_accounts_outlined),
                        label: const Text('管理 GitHub 备份授权'),
                      ),
                    ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _signOutOfGitHub,
                      icon: const Icon(Icons.logout),
                      label: const Text('从本机退出'),
                    ),
                  ),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: _openGitHubAuthorizations,
                      child: const Text('在 GitHub 管理或撤销授权'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('GitHub 加密备份'),
                  subtitle: Text(
                    account == null
                        ? '登录 GitHub 后可连接你指定的私有仓库。'
                        : backup == null
                        ? '请先创建或选择私有仓库，再设置加密备份。'
                        : '${backup.owner}/${backup.repository}\n${backup.weeklyEnabled ? '每周自动备份已开启' : '每周自动备份已暂停'}',
                  ),
                  trailing: IconButton(
                    tooltip: '设置仓库和加密口令',
                    onPressed: account == null ? null : _configureGitHubBackup,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
                if (backup != null) ...[
                  const Divider(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: backup.weeklyEnabled,
                    onChanged: account == null ? null : _setGitHubWeeklyBackup,
                    title: const Text('每周自动备份与提醒'),
                    subtitle: const Text('Android 在网络可用时运行，系统调度时间可能延后。'),
                  ),
                  if (backup.lastBackupAt != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '上次备份：${_formatDateTime(backup.lastBackupAt!)}',
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: account == null || _uploadingBackup
                              ? null
                              : _uploadGitHubBackup,
                          icon: _uploadingBackup
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload_outlined),
                          label: const Text('立即备份'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: account == null || _uploadingBackup
                              ? null
                              : _restoreGitHubBackup,
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('从 GitHub 恢复'),
                        ),
                      ),
                    ],
                  ),
                ] else if (account != null) ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _promptGitHubBackupSetup,
                      icon: const Icon(Icons.settings_backup_restore),
                      label: const Text('设置 GitHub 加密备份'),
                    ),
                  ),
                ],
                if (backup != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      '仅上传加密快照，不会在多台设备间自动合并账单。请记住加密口令；上传需有可访问 GitHub 的网络，VPN 由你自行开启。',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              const ListTile(
                leading: Icon(Icons.chat_bubble_outline),
                title: Text('微信登录'),
                subtitle: Text('待配置微信开放平台应用。'),
              ),
              const Divider(height: 1, indent: 56),
              const ListTile(
                leading: Icon(Icons.group_outlined),
                title: Text('QQ 登录'),
                subtitle: Text('待配置 QQ 互联应用。'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '登录是可选的。本机记账无需注册；启用 GitHub 同步前会说明上传内容和目标仓库。',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _monthPicker() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        tooltip: '上个月',
        onPressed: () => _changeMonth(-1),
        icon: const Icon(Icons.chevron_left),
      ),
      Text(
        _monthLabel(_displayMonth),
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      IconButton(
        tooltip: '下个月',
        onPressed: () => _changeMonth(1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  Widget _summaryCard({required int income, required int expense}) {
    final balance = income - expense;
    final budgetRatio = _monthlyBudget == null
        ? null
        : (expense / _monthlyBudget!).clamp(0.0, 1.0);
    return Card(
      color: const Color(0xFFFFC928),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_monthLabel(_displayMonth)}结余',
              style: const TextStyle(color: Color(0xFF5C4A15)),
            ),
            const SizedBox(height: 5),
            Text(
              '${balance < 0 ? '−' : ''}${_money(balance.abs())}',
              style: const TextStyle(
                color: Color(0xFF302607),
                fontSize: 32,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: _summaryValue('收入', income, Icons.south_west)),
                const SizedBox(width: 12),
                Expanded(child: _summaryValue('支出', expense, Icons.north_east)),
              ],
            ),
            if (budgetRatio != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '预算进度',
                      style: TextStyle(color: Color(0xFF5C4A15), fontSize: 12),
                    ),
                  ),
                  Text(
                    '${(expense / _monthlyBudget! * 100).round()}%',
                    style: const TextStyle(
                      color: Color(0xFF5C4A15),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: budgetRatio,
                  minHeight: 6,
                  color: const Color(0xFF4B3A0A),
                  backgroundColor: const Color(0x66FFFFFF),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryValue(String label, int amount, IconData icon) => Row(
    children: [
      Icon(icon, color: const Color(0xFF5C4A15), size: 16),
      const SizedBox(width: 6),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Color(0xFF5C4A15), fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              _money(amount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF302607),
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _sectionTitle(String title, {String? trailing}) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      const Spacer(),
      if (trailing != null)
        Text(
          trailing,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
    ],
  );

  Widget _filterChip(String label, EntryType? type) => ChoiceChip(
    label: Text(label),
    selected: _billFilter == type,
    onSelected: (_) => setState(() => _billFilter = type),
  );

  Widget _categoryFilterChip(String label, String? category) => ChoiceChip(
    label: Text(label),
    selected: _categoryFilter == category,
    onSelected: (_) => setState(() => _categoryFilter = category),
  );

  Widget _entryTile(LedgerEntry entry) {
    final income = entry.type == EntryType.income;
    final color = income ? const Color(0xFF287A5B) : const Color(0xFF303833);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
        leading: CircleAvatar(
          backgroundColor: LedgerCategories.color(entry.category)
              .withValues(alpha: 0.12),
          foregroundColor: LedgerCategories.color(entry.category),
          child: Icon(LedgerCategories.icon(entry.category), size: 20),
        ),
        title: Text(
          entry.category,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            if (entry.note.isNotEmpty) entry.note,
            _dateLabel(entry.date),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${income ? '+' : '−'}${_money(entry.amountCents)}',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            IconButton(
              tooltip: '编辑账单',
              visualDensity: VisualDensity.compact,
              onPressed: () => _editEntry(entry),
              icon: Icon(
                Icons.edit_outlined,
                color: Colors.grey.shade500,
                size: 19,
              ),
            ),
            IconButton(
              tooltip: '删除账单',
              visualDensity: VisualDensity.compact,
              onPressed: () => _deleteEntry(entry),
              icon: Icon(
                Icons.delete_outline,
                color: Colors.grey.shade500,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 38, horizontal: 20),
    child: Column(
      children: [
        Icon(icon, size: 42, color: Colors.grey.shade400),
        const SizedBox(height: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
      ],
    ),
  );

  static String _monthLabel(DateTime date) => '${date.year}年${date.month}月';

  static String _dateLabel(DateTime date) =>
      '${date.month}月${date.day}日 ${const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][date.weekday - 1]}';

  static String _money(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';

  static String _formatDateTime(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class _GitHubBackupSetup {
  const _GitHubBackupSetup({
    required this.owner,
    required this.repository,
    required this.passphrase,
    required this.weeklyEnabled,
  });

  final String owner;
  final String repository;
  final String passphrase;
  final bool weeklyEnabled;
}

class _GitHubBackupSetupDialog extends StatefulWidget {
  const _GitHubBackupSetupDialog({required this.current});

  final GitHubBackupConfig? current;

  @override
  State<_GitHubBackupSetupDialog> createState() =>
      _GitHubBackupSetupDialogState();
}

class _GitHubBackupSetupDialogState extends State<_GitHubBackupSetupDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _ownerController;
  late final TextEditingController _repositoryController;
  final _passphraseController = TextEditingController();
  late bool _enableWeekly;

  @override
  void initState() {
    super.initState();
    _ownerController = TextEditingController(text: widget.current?.owner ?? '');
    _repositoryController = TextEditingController(
      text: widget.current?.repository ?? '',
    );
    _enableWeekly = widget.current?.weeklyEnabled ?? true;
  }

  @override
  void dispose() {
    _ownerController.dispose();
    _repositoryController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(
      _GitHubBackupSetup(
        owner: _ownerController.text.trim(),
        repository: _repositoryController.text.trim(),
        passphrase: _passphraseController.text,
        weeklyEnabled: _enableWeekly,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNewSetup = widget.current == null;
    return AlertDialog(
      title: const Text('设置 GitHub 加密备份'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('账本会先在本机加密，再写入你选择的私有仓库。备份文件不会公开；请记住加密口令，换机恢复时需要它。'),
              const SizedBox(height: 14),
              TextFormField(
                controller: _ownerController,
                decoration: const InputDecoration(
                  labelText: '仓库所有者（用户名或组织）',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入所有者' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _repositoryController,
                decoration: const InputDecoration(
                  labelText: '私有仓库名',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入仓库名' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _passphraseController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: isNewSetup ? '加密口令（至少 12 个字符）' : '新加密口令',
                  helperText: isNewSetup
                      ? '应用会把口令保存在 Android 加密存储中，用于自动备份。'
                      : '留空保留现有口令；换机恢复需要你记住它。',
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if ((value ?? '').isEmpty && !isNewSetup) return null;
                  if ((value ?? '').runes.length < 12) {
                    return '口令至少需要 12 个字符';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _enableWeekly,
                onChanged: (value) =>
                    setState(() => _enableWeekly = value ?? false),
                title: const Text('开启每周自动备份与提醒'),
                subtitle: const Text('Android 会在网络可用时调度上传，时间可能有延迟。'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('验证并保存')),
      ],
    );
  }
}

class _EntryForm extends StatefulWidget {
  const _EntryForm({this.initialEntry});

  final LedgerEntry? initialEntry;

  @override
  State<_EntryForm> createState() => _EntryFormState();
}

class _EntryFormState extends State<_EntryForm> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  EntryType _type = EntryType.expense;
  String _category = '餐饮';
  DateTime _date = DateTime.now();

  List<String> _customExpenseCategories = const [];
  List<String> _customIncomeCategories = const [];

  List<String> get _categories {
    final builtIns = LedgerCategories.builtIns(_type);
    final custom = _type == EntryType.expense
        ? _customExpenseCategories
        : _customIncomeCategories;
    final existingCategory = widget.initialEntry?.category;
    return {
      ...builtIns.where((category) => category != LedgerCategories.other),
      ...custom,
      if (existingCategory != null &&
          existingCategory != LedgerCategories.other &&
          !builtIns.contains(existingCategory) &&
          !custom.contains(existingCategory))
        existingCategory,
      LedgerCategories.other,
    }.toList(growable: false);
  }

  List<String> get _customCategories => _type == EntryType.expense
      ? _customExpenseCategories
      : _customIncomeCategories;

  @override
  void initState() {
    super.initState();
    final entry = widget.initialEntry;
    if (entry != null) {
      _type = entry.type;
      _category = entry.category;
      _date = entry.date;
      _amountController.text = (entry.amountCents / 100).toStringAsFixed(2);
      _noteController.text = entry.note;
    }
    _loadCustomCategories();
  }

  Future<void> _loadCustomCategories() async {
    final categories = await Future.wait([
      LedgerDatabase.instance.getCustomCategories(EntryType.expense),
      LedgerDatabase.instance.getCustomCategories(EntryType.income),
    ]);
    if (!mounted) return;
    setState(() {
      _customExpenseCategories = categories[0];
      _customIncomeCategories = categories[1];
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _changeType(EntryType type) {
    setState(() {
      _type = type;
      _category = LedgerCategories.builtIns(type).first;
    });
  }

  Future<void> _chooseOtherCategory({bool createCustom = false}) async {
    final categoryController = TextEditingController(
      text: _category == LedgerCategories.other || createCustom
          ? ''
          : _category,
    );
    final noteController = TextEditingController(text: _noteController.text);
    final formKey = GlobalKey<FormState>();
    final choice = await showDialog<_OtherCategoryChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(createCustom ? '添加自定义分类' : '其他分类'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: categoryController,
                autofocus: createCustom,
                maxLength: 16,
                decoration: InputDecoration(
                  labelText: createCustom ? '分类名称' : '自定义分类（可留空）',
                  hintText: '例如：家庭聚餐',
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
                validator: (value) {
                  final name = (value ?? '').trim();
                  if (createCustom && name.isEmpty) return '请输入分类名称';
                  if (name.runes.length > 16) return '分类名称最多 16 个字符';
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: noteController,
                maxLength: 60,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注（选填）',
                  hintText: '例如：给家人买的水果',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '自定义分类会保存在本机，之后记账时也能直接选择。',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              final name = categoryController.text.trim();
              Navigator.pop(
                dialogContext,
                _OtherCategoryChoice(
                  category: name.isEmpty ? LedgerCategories.other : name,
                  note: noteController.text.trim(),
                ),
              );
            },
            child: Text(createCustom ? '添加并选择' : '完成'),
          ),
        ],
      ),
    );
    categoryController.dispose();
    noteController.dispose();
    if (choice == null) return;

    final isCustom = !LedgerCategories.builtIns(_type)
        .contains(choice.category);
    if (isCustom) {
      await LedgerDatabase.instance.addCustomCategory(_type, choice.category);
      if (!mounted) return;
      setState(() {
        if (_type == EntryType.expense) {
          _customExpenseCategories = {
            ..._customExpenseCategories,
            choice.category,
          }.toList()..sort();
        } else {
          _customIncomeCategories = {
            ..._customIncomeCategories,
            choice.category,
          }.toList()..sort();
        }
      });
    }
    setState(() {
      _category = choice.category;
      _noteController.text = choice.note;
    });
  }

  Future<void> _removeCustomCategory(String category) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除自定义分类？'),
        content: Text('“$category”将不再出现在新账单分类中，已有账单不会被修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    await LedgerDatabase.instance.removeCustomCategory(_type, category);
    if (!mounted) return;
    setState(() {
      if (_type == EntryType.expense) {
        _customExpenseCategories = _customExpenseCategories
            .where((item) => item != category)
            .toList(growable: false);
      } else {
        _customIncomeCategories = _customIncomeCategories
            .where((item) => item != category)
            .toList(growable: false);
      }
      if (_category == category) _category = LedgerCategories.other;
    });
  }

  Future<void> _manageCustomCategories() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('分类设置'),
          content: SizedBox(
            width: double.maxFinite,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _customCategories.isEmpty
                  ? const Text('还没有自定义分类。添加后，它会出现在记账分类列表中。')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final category in _customCategories)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              LedgerCategories.icon(category),
                              color: LedgerCategories.color(category),
                            ),
                            title: Text(
                              category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: '移除分类',
                              onPressed: () async {
                                await _removeCustomCategory(category);
                                if (mounted) setDialogState(() {});
                              },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _chooseOtherCategory(createCustom: true);
              },
              icon: const Icon(Icons.add),
              label: const Text('添加分类'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null) setState(() => _date = selected);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amountController.text.trim());
    Navigator.of(context).pop(
      LedgerEntry(
        id: widget.initialEntry?.id,
        type: _type,
        amountCents: (amount * 100).round(),
        category: _category,
        date: DateTime(_date.year, _date.month, _date.day),
        note: _noteController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.initialEntry == null ? '记一笔' : '编辑账单',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<EntryType>(
                segments: const [
                  ButtonSegment(
                    value: EntryType.expense,
                    label: Text('支出'),
                    icon: Icon(Icons.north_east),
                  ),
                  ButtonSegment(
                    value: EntryType.income,
                    label: Text('收入'),
                    icon: Icon(Icons.south_west),
                  ),
                ],
                selected: {_type},
                style: SegmentedButton.styleFrom(enableFeedback: false),
                onSelectionChanged: (selection) {
                  TapSoundService.playSelectionDing();
                  _changeType(selection.first);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '金额',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final amount = double.tryParse(value?.trim() ?? '');
                  if (amount == null || amount <= 0) return '请输入大于 0 的金额';
                  if (amount > 999999999) return '金额超出范围';
                  return null;
                },
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Text(
                    '分类',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _chooseOtherCategory(createCustom: true),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('自定义分类'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 4,
                  childAspectRatio: 0.9,
                ),
                itemCount: _categories.length + 1,
                itemBuilder: (context, index) {
                  if (index == _categories.length) {
                    return Tooltip(
                      message: '管理自定义分类',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _manageCustomCategories,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.settings_outlined,
                                size: 24,
                                color: Colors.grey.shade700,
                              ),
                              const SizedBox(height: 5),
                              const Text('设置', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                    );
                  }
                  final category = _categories[index];
                  final isCustom = _customCategories.contains(category);
                  final selected = _category == category;
                  return Tooltip(
                    message: isCustom ? '长按可移除自定义分类' : category,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      enableFeedback: false,
                      onTap: () {
                        TapSoundService.playSelectionDing();
                        if (category == LedgerCategories.other) {
                          _chooseOtherCategory();
                        } else {
                          setState(() => _category = category);
                        }
                      },
                      onLongPress: isCustom
                          ? () => _removeCustomCategory(category)
                          : null,
                      child: Container(
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFFFFE28A)
                              : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFFE3A900)
                                : Colors.transparent,
                            width: 1.4,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              LedgerCategories.icon(category),
                              size: 24,
                              color: LedgerCategories.color(category),
                            ),
                            const SizedBox(height: 5),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
                              child: Text(
                                category,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined),
                title: const Text('日期'),
                trailing: Text(_dateLabel(_date)),
                onTap: _chooseDate,
              ),
              TextFormField(
                controller: _noteController,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: '备注（选填）',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('保存账单'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _dateLabel(DateTime date) =>
      '${date.year}年${date.month}月${date.day}日';
}

class _OtherCategoryChoice {
  const _OtherCategoryChoice({required this.category, required this.note});

  final String category;
  final String note;
}
