import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/ledger_database.dart';
import '../models/ledger_entry.dart';
import '../services/github_backup_service.dart';
import '../services/github_auth_service.dart';

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
              const Text('打开 GitHub 授权页面，输入这次性验证码：'),
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
    } catch (error) {
      _showMessage('GitHub 登录失败：$error');
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
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
    final ownerController = TextEditingController(text: current?.owner ?? '');
    final repositoryController = TextEditingController(
      text: current?.repository ?? '',
    );
    final passphraseController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var enableWeekly = current?.weeklyEnabled ?? true;

    final setup = await showDialog<_GitHubBackupSetup>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置 GitHub 加密备份'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '账本会先在本机加密，再写入你选择的私有仓库。备份文件不会公开；请记住加密口令，换机恢复时需要它。',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: ownerController,
                    decoration: const InputDecoration(
                      labelText: '仓库所有者（用户名或组织）',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '请输入所有者' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: repositoryController,
                    decoration: const InputDecoration(
                      labelText: '私有仓库名',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? '请输入仓库名' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: passphraseController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: current == null ? '加密口令（至少 12 个字符）' : '新加密口令',
                      helperText: current == null
                          ? '应用会把口令保存在 Android 加密存储中，用于自动备份。'
                          : '留空保留现有口令；换机恢复需要你记住它。',
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if ((value ?? '').isEmpty && current != null) return null;
                      if ((value ?? '').runes.length < 12) {
                        return '口令至少需要 12 个字符';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: enableWeekly,
                    onChanged: (value) =>
                        setDialogState(() => enableWeekly = value ?? false),
                    title: const Text('开启每周自动备份与提醒'),
                    subtitle: const Text('Android 会在网络可用时调度上传，时间可能有延迟。'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
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
                  _GitHubBackupSetup(
                    owner: ownerController.text.trim(),
                    repository: repositoryController.text.trim(),
                    passphrase: passphraseController.text,
                    weeklyEnabled: enableWeekly,
                  ),
                );
              },
              child: const Text('验证并保存'),
            ),
          ],
        ),
      ),
    );
    ownerController.dispose();
    repositoryController.dispose();
    passphraseController.dispose();
    if (setup == null) return;

    try {
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
      _showMessage('构建版本还没有配置 GitHub App Slug。');
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
              if (value == 'export') {
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
                value: 'export',
                child: Row(
                  children: [
                    Icon(Icons.download_outlined),
                    SizedBox(width: 12),
                    Text('导出备份'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'restore',
                child: Row(
                  children: [
                    Icon(Icons.upload_outlined),
                    SizedBox(width: 12),
                    Text('恢复备份'),
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
              onPressed: () => _showEntryForm(),
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
    final monthEntries = _monthEntries;
    final expense = _total(monthEntries, EntryType.expense);
    final totals = <String, int>{};
    for (final entry in monthEntries.where(
      (e) => e.type == EntryType.expense,
    )) {
      totals.update(
        entry.category,
        (value) => value + entry.amountCents,
        ifAbsent: () => entry.amountCents,
      );
    }
    final categories = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        _monthPicker(),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_monthLabel(_displayMonth)}支出',
                  style: TextStyle(color: Colors.grey.shade700),
                ),
                const SizedBox(height: 8),
                Text(
                  _money(expense),
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '月预算',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: _editMonthlyBudget,
                      child: Text(_monthlyBudget == null ? '设置' : '调整'),
                    ),
                    if (_monthlyBudget != null)
                      IconButton(
                        tooltip: '清除预算',
                        onPressed: _clearMonthlyBudget,
                        icon: const Icon(Icons.close, size: 20),
                      ),
                  ],
                ),
                if (_monthlyBudget == null)
                  Text(
                    '设置预算后，可查看本月支出进度。',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  )
                else ...[
                  Text(
                    '已支出 ${_money(expense)} / ${_money(_monthlyBudget!)}',
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: (expense / _monthlyBudget!).clamp(0.0, 1.0),
                      minHeight: 8,
                      color: expense > _monthlyBudget!
                          ? Colors.red.shade400
                          : const Color(0xFF287A5B),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    expense > _monthlyBudget!
                        ? '已超出 ${_money(expense - _monthlyBudget!)}'
                        : '剩余 ${_money(_monthlyBudget! - expense)}',
                    style: TextStyle(
                      color: expense > _monthlyBudget!
                          ? Colors.red.shade700
                          : Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        _sectionTitle('支出分类'),
        const SizedBox(height: 8),
        if (categories.isEmpty)
          _emptyState(
            icon: Icons.pie_chart_outline,
            title: '还没有支出数据',
            subtitle: '记录支出后，这里会显示分类汇总。',
          )
        else
          ...categories.map((item) {
            final ratio = expense == 0 ? 0.0 : item.value / expense;
            final color = _categoryColor(item.key);
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(_categoryIcon(item.key), color: color, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: Text(item.key)),
                        Text(
                          '${(ratio * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _money(item.value),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 7,
                        color: color,
                        backgroundColor: color.withValues(alpha: 0.12),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
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
                      '还需配置 GitHub App Client ID。应用不会内置 Client Secret。',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _installGitHubApp,
                      icon: const Icon(Icons.install_mobile_outlined),
                      label: const Text('安装或管理 GitHub App'),
                    ),
                  ),
                  if (GitHubAuthService.appSlug.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '构建时需配置 GITHUB_APP_SLUG；安装时请选择仅一个账本私有仓库。',
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 12,
                        ),
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
                        ? '选择私有仓库并设置加密口令。'
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
                      onPressed: _configureGitHubBackup,
                      icon: const Icon(Icons.settings_backup_restore),
                      label: const Text('设置私有仓库'),
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
          backgroundColor: _categoryColor(entry.category)
              .withValues(alpha: 0.12),
          foregroundColor: _categoryColor(entry.category),
          child: Icon(_categoryIcon(entry.category), size: 20),
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

  static IconData _categoryIcon(String category) => switch (category) {
    '餐饮' => Icons.restaurant,
    '交通' => Icons.directions_bus,
    '购物' => Icons.shopping_bag_outlined,
    '居住' => Icons.home_outlined,
    '娱乐' => Icons.movie_outlined,
    '医疗' => Icons.medical_services_outlined,
    '工资' => Icons.account_balance_wallet_outlined,
    '奖金' => Icons.card_giftcard_outlined,
    '兼职' => Icons.work_outline,
    _ => Icons.category_outlined,
  };

  static Color _categoryColor(String category) => switch (category) {
    '餐饮' => const Color(0xFFE28A45),
    '交通' => const Color(0xFF4C83C3),
    '购物' => const Color(0xFF9A6CC1),
    '居住' => const Color(0xFF558C77),
    '娱乐' => const Color(0xFFCB6A77),
    '医疗' => const Color(0xFF4E9CA0),
    '工资' => const Color(0xFF287A5B),
    '奖金' => const Color(0xFFB28B3B),
    _ => const Color(0xFF818A84),
  };
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

  static const _expenseCategories = ['餐饮', '交通', '购物', '居住', '娱乐', '医疗', '其他'];
  static const _incomeCategories = ['工资', '奖金', '兼职', '其他'];

  List<String> get _categories {
    final categories = _type == EntryType.expense
        ? _expenseCategories
        : _incomeCategories;
    final existingCategory = widget.initialEntry?.category;
    if (existingCategory != null && !categories.contains(existingCategory)) {
      return [...categories, existingCategory];
    }
    return categories;
  }

  @override
  void initState() {
    super.initState();
    final entry = widget.initialEntry;
    if (entry == null) return;
    _type = entry.type;
    _category = entry.category;
    _date = entry.date;
    _amountController.text = (entry.amountCents / 100).toStringAsFixed(2);
    _noteController.text = entry.note;
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
      _category = _categories.first;
    });
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
                onSelectionChanged: (selection) => _changeType(selection.first),
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
              const Text('分类', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _categories
                    .map(
                      (category) => ChoiceChip(
                        label: Text(category),
                        selected: _category == category,
                        onSelected: (_) => setState(() => _category = category),
                      ),
                    )
                    .toList(growable: false),
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
