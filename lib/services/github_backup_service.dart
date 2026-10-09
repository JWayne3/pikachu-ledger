import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../data/ledger_database.dart';
import 'backup_encryption_service.dart';
import 'github_auth_service.dart';
import 'github_backup_scheduler.dart';

class GitHubBackupConfig {
  const GitHubBackupConfig({
    required this.owner,
    required this.repository,
    required this.weeklyEnabled,
    this.lastBackupAt,
  });

  final String owner;
  final String repository;
  final bool weeklyEnabled;
  final DateTime? lastBackupAt;
}

class GitHubBackupException implements Exception {
  const GitHubBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubBackupService {
  GitHubBackupService({
    LedgerDatabase? database,
    GitHubAuthService? auth,
    http.Client? client,
    FlutterSecureStorage? storage,
    BackupEncryptionService? encryption,
  }) : _database = database ?? LedgerDatabase.instance,
       _auth = auth ?? GitHubAuthService(),
       _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage(),
       _encryption = encryption ?? BackupEncryptionService();

  static const _apiVersion = '2026-03-10';
  static const _requestTimeout = Duration(seconds: 30);
  static const _ownerKey = 'github_backup_owner';
  static const _repositoryKey = 'github_backup_repository';
  static const _passphraseKey = 'github_backup_passphrase';
  static const _weeklyEnabledKey = 'github_backup_weekly_enabled';
  static const _lastBackupAtKey = 'github_backup_last_backup_at';
  static const _backupPath = 'pikachu-ledger/backup.json';
  static const _maxEncryptedBackupBytes = 900000;

  final LedgerDatabase _database;
  final GitHubAuthService _auth;
  final http.Client _client;
  final FlutterSecureStorage _storage;
  final BackupEncryptionService _encryption;

  void dispose() {
    _auth.dispose();
    _client.close();
  }

  Future<GitHubBackupConfig?> loadConfig() async {
    final owner = await _storage.read(key: _ownerKey);
    final repository = await _storage.read(key: _repositoryKey);
    if (owner == null || repository == null) return null;
    final enabled = await _storage.read(key: _weeklyEnabledKey) == 'true';
    final lastBackup = await _storage.read(key: _lastBackupAtKey);
    return GitHubBackupConfig(
      owner: owner,
      repository: repository,
      weeklyEnabled: enabled,
      lastBackupAt: DateTime.tryParse(lastBackup ?? '')?.toLocal(),
    );
  }

  Future<void> configure({
    required String owner,
    required String repository,
    required String? passphrase,
  }) async {
    final normalizedOwner = owner.trim();
    final normalizedRepository = repository.trim();
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(normalizedOwner) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(normalizedRepository)) {
      throw const GitHubBackupException('请输入有效的 GitHub 用户名/组织名和仓库名。');
    }
    final storedPassphrase = passphrase?.isEmpty ?? true
        ? await _storage.read(key: _passphraseKey)
        : passphrase;
    if (storedPassphrase == null || storedPassphrase.runes.length < 12) {
      throw const GitHubBackupException('加密口令至少需要 12 个字符。');
    }

    final token = await _requiredToken();
    await _verifyPrivateWritableRepository(
      normalizedOwner,
      normalizedRepository,
      token,
    );

    await _storage.write(key: _ownerKey, value: normalizedOwner);
    await _storage.write(key: _repositoryKey, value: normalizedRepository);
    await _storage.write(key: _passphraseKey, value: storedPassphrase);
  }

  Future<bool> setWeeklyEnabled(bool enabled) async {
    if (enabled && await loadConfig() == null) {
      throw const GitHubBackupException('请先设置私有仓库和加密口令。');
    }
    if (enabled) {
      final reminderEnabled = await GitHubBackupScheduler.instance
          .enableWeekly();
      await _storage.write(key: _weeklyEnabledKey, value: 'true');
      return reminderEnabled;
    }
    await _storage.write(key: _weeklyEnabledKey, value: 'false');
    await GitHubBackupScheduler.instance.disableWeekly();
    return true;
  }

  Future<void> removeConfiguration() async {
    await setWeeklyEnabled(false);
    for (final key in [
      _ownerKey,
      _repositoryKey,
      _passphraseKey,
      _lastBackupAtKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<void> uploadNow() async {
    final config = await loadConfig();
    if (config == null) {
      throw const GitHubBackupException('请先设置私有仓库和加密口令。');
    }
    final passphrase = await _storage.read(key: _passphraseKey);
    if (passphrase == null || passphrase.isEmpty) {
      throw const GitHubBackupException('找不到加密口令，请重新设置备份。');
    }

    final token = await _requiredToken();
    await _verifyPrivateWritableRepository(
      config.owner,
      config.repository,
      token,
    );
    final snapshot = await _database.createBackupSnapshot();
    final encrypted = await _encryption.encryptSnapshot(snapshot, passphrase);
    final encryptedBytes = utf8.encode(encrypted);
    if (encryptedBytes.length > _maxEncryptedBackupBytes) {
      throw const GitHubBackupException('加密备份超过当前 GitHub 接口的安全大小限制，请先导出到本地保存。');
    }

    final fileUri = _contentsUri(config.owner, config.repository);
    String? sha;
    final existingResponse = await _client
        .get(fileUri, headers: _headers(token))
        .timeout(_requestTimeout);
    if (existingResponse.statusCode == 200) {
      sha = _decodeJson(existingResponse)['sha'] as String?;
    } else if (existingResponse.statusCode != 404) {
      _throwResponseError(existingResponse);
    }

    final requestBody = {
      'message': 'Update encrypted ledger backup',
      'content': base64Encode(encryptedBytes),
    };
    if (sha != null) requestBody['sha'] = sha;
    final response = await _client
        .put(fileUri, headers: _headers(token), body: jsonEncode(requestBody))
        .timeout(_requestTimeout);
    _decodeJson(response);
    await _storage.write(
      key: _lastBackupAtKey,
      value: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<bool> uploadIfEnabled() async {
    final enabled = await _storage.read(key: _weeklyEnabledKey) == 'true';
    if (!enabled) return true;
    await uploadNow();
    return true;
  }

  Future<Map<String, Object?>> downloadAndDecrypt(String passphrase) async {
    final config = await loadConfig();
    if (config == null) {
      throw const GitHubBackupException('请先设置私有仓库。');
    }
    final token = await _requiredToken();
    await _verifyPrivateWritableRepository(
      config.owner,
      config.repository,
      token,
    );
    final response = await _client
        .get(
          _contentsUri(config.owner, config.repository),
          headers: _headers(token),
        )
        .timeout(_requestTimeout);
    final data = _decodeJson(response);
    final encodedContent = data['content'];
    if (encodedContent is! String || encodedContent.trim().isEmpty) {
      throw const GitHubBackupException('GitHub 没有返回备份内容。');
    }
    final encrypted = utf8.decode(
      base64Decode(encodedContent.replaceAll(RegExp(r'\s'), '')),
    );
    return _encryption.decryptSnapshot(encrypted, passphrase);
  }

  Future<String> _requiredToken() async {
    final token = await _auth.validAccessToken();
    if (token == null || token.isEmpty) {
      throw const GitHubBackupException('GitHub 登录已失效，请重新登录后再试。');
    }
    return token;
  }

  Future<void> _verifyPrivateWritableRepository(
    String owner,
    String repository,
    String token,
  ) async {
    final repositoryData = await _requestJson(
      _client.get(_repositoryUri(owner, repository), headers: _headers(token)),
    );
    if (repositoryData['private'] != true) {
      throw const GitHubBackupException('备份已停止：目标仓库不是私有仓库。请先改为私有后重试。');
    }
    final permissions = repositoryData['permissions'];
    if (permissions is! Map || permissions['push'] != true) {
      throw const GitHubBackupException('此 GitHub 授权没有向该仓库写入内容的权限。');
    }
  }

  Uri _repositoryUri(String owner, String repository) =>
      Uri.https('api.github.com', '/repos/$owner/$repository');

  Uri _contentsUri(String owner, String repository) => Uri.https(
    'api.github.com',
    '/repos/$owner/$repository/contents/$_backupPath',
  );

  Map<String, String> _headers(String token) => {
    'Accept': 'application/vnd.github+json',
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': _apiVersion,
  };

  Future<Map<String, dynamic>> _requestJson(
    Future<http.Response> request,
  ) async => _decodeJson(await request.timeout(_requestTimeout));

  Map<String, dynamic> _decodeJson(http.Response response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw GitHubBackupException(
        'GitHub 返回了无法识别的响应（HTTP ${response.statusCode}）。',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const GitHubBackupException('GitHub 返回了无效响应。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded['message'] ?? 'HTTP ${response.statusCode}';
      throw GitHubBackupException('GitHub 请求失败：$message');
    }
    return decoded;
  }

  void _throwResponseError(http.Response response) {
    _decodeJson(response);
  }
}
