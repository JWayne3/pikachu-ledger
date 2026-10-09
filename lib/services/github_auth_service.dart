import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class GitHubDeviceFlow {
  const GitHubDeviceFlow({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    this.repositoryId,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Duration expiresIn;
  final Duration interval;
  final int? repositoryId;
}

class GitHubAccount {
  const GitHubAccount({required this.login, this.avatarUrl});

  final String login;
  final String? avatarUrl;
}

class GitHubAuthException implements Exception {
  const GitHubAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

class GitHubAuthService {
  GitHubAuthService({http.Client? client, FlutterSecureStorage? storage})
    : _client = client ?? http.Client(),
      _storage = storage ?? const FlutterSecureStorage();

  static const clientId = String.fromEnvironment('GITHUB_APP_CLIENT_ID');
  static const appSlug = String.fromEnvironment('GITHUB_APP_SLUG');
  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _accessTokenUrl = 'https://github.com/login/oauth/access_token';
  static const _apiVersion = '2026-03-10';
  static const _requestTimeout = Duration(seconds: 30);

  static const _accessTokenKey = 'github_access_token';
  static const _refreshTokenKey = 'github_refresh_token';
  static const _expiresAtKey = 'github_access_token_expires_at';
  static const _loginKey = 'github_login';
  static const _avatarKey = 'github_avatar_url';

  final http.Client _client;
  final FlutterSecureStorage _storage;

  bool get isConfigured => clientId.isNotEmpty;

  void dispose() => _client.close();

  Future<GitHubDeviceFlow> beginSignIn({int? repositoryId}) async {
    if (!isConfigured) {
      throw const GitHubAuthException(
        '这个构建版本还没有接入皮卡丘记账的 GitHub 授权服务。这不是你的 GitHub 账号问题；本地记账不受影响。',
      );
    }

    final response = await _client
        .post(
          Uri.parse(_deviceCodeUrl),
          headers: const {'Accept': 'application/json'},
          body: {'client_id': clientId, 'scope': 'offline_access'},
        )
        .timeout(_requestTimeout);
    final data = _decodeResponse(response);
    final deviceCode = data['device_code'];
    final userCode = data['user_code'];
    final verification = data['verification_uri'];
    if (deviceCode is! String ||
        userCode is! String ||
        verification is! String) {
      throw const GitHubAuthException('GitHub 没有返回有效的设备授权信息。');
    }

    final verificationUri = Uri.tryParse(verification);
    if (verificationUri == null ||
        verificationUri.scheme != 'https' ||
        verificationUri.host != 'github.com') {
      throw const GitHubAuthException('GitHub 返回了无效的授权网址。');
    }

    return GitHubDeviceFlow(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: verificationUri,
      expiresIn: Duration(seconds: _integer(data['expires_in'], fallback: 900)),
      interval: Duration(seconds: _integer(data['interval'], fallback: 5)),
      repositoryId: repositoryId,
    );
  }

  Future<GitHubAccount> waitForAuthorization(
    GitHubDeviceFlow flow, {
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(flow.expiresIn);
    var pollInterval = flow.interval;

    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled?.call() ?? false) {
        throw const GitHubAuthException('已取消 GitHub 登录。');
      }
      final remaining = deadline.difference(DateTime.now());
      await Future<void>.delayed(
        pollInterval < remaining ? pollInterval : remaining,
      );
      if (isCancelled?.call() ?? false) {
        throw const GitHubAuthException('已取消 GitHub 登录。');
      }

      final response = await _client
          .post(
            Uri.parse(_accessTokenUrl),
            headers: const {'Accept': 'application/json'},
            body: {
              'client_id': clientId,
              'device_code': flow.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              if (flow.repositoryId != null)
                'repository_id': flow.repositoryId.toString(),
            },
          )
          .timeout(_requestTimeout);
      final data = _decodeResponse(response, allowOAuthError: true);
      final accessToken = data['access_token'];
      if (accessToken is String && accessToken.isNotEmpty) {
        await _storeTokens(data);
        return _loadAccount(accessToken);
      }

      switch (data['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          pollInterval += const Duration(seconds: 5);
          continue;
        case 'access_denied':
          throw const GitHubAuthException('你已在 GitHub 取消授权。');
        case 'expired_token':
          throw const GitHubAuthException('授权码已过期，请重新开始登录。');
        default:
          throw GitHubAuthException(
            'GitHub 登录失败：${data['error_description'] ?? data['error'] ?? '未知错误'}',
          );
      }
    }
    throw const GitHubAuthException('授权等待超时，请重新开始登录。');
  }

  Future<String?> validAccessToken() async {
    final token = await _storage.read(key: _accessTokenKey);
    if (token == null || token.isEmpty) return null;

    final expiresAtText = await _storage.read(key: _expiresAtKey);
    final expiresAt = DateTime.tryParse(expiresAtText ?? '');
    if (expiresAt == null ||
        DateTime.now().isBefore(
          expiresAt.subtract(const Duration(minutes: 2)),
        )) {
      return token;
    }

    final refreshToken = await _storage.read(key: _refreshTokenKey);
    if (refreshToken == null || !isConfigured) return null;
    final response = await _client
        .post(
          Uri.parse(_accessTokenUrl),
          headers: const {'Accept': 'application/json'},
          body: {
            'client_id': clientId,
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
          },
        )
        .timeout(_requestTimeout);
    final data = _decodeResponse(response, allowOAuthError: true);
    if (data['access_token'] is! String) {
      await signOut();
      return null;
    }
    await _storeTokens(data);
    return data['access_token'] as String;
  }

  Future<GitHubAccount?> currentAccount() async {
    final login = await _storage.read(key: _loginKey);
    if (login == null || login.isEmpty) return null;
    return GitHubAccount(
      login: login,
      avatarUrl: await _storage.read(key: _avatarKey),
    );
  }

  Future<void> signOut() async {
    for (final key in [
      _accessTokenKey,
      _refreshTokenKey,
      _expiresAtKey,
      _loginKey,
      _avatarKey,
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<GitHubAccount> _loadAccount(String token) async {
    final response = await _client
        .get(Uri.https('api.github.com', '/user'), headers: _apiHeaders(token))
        .timeout(_requestTimeout);
    final data = _decodeResponse(response);
    final login = data['login'];
    if (login is! String || login.isEmpty) {
      throw const GitHubAuthException('无法读取 GitHub 用户资料。');
    }
    final avatar = data['avatar_url'];
    final account = GitHubAccount(
      login: login,
      avatarUrl: avatar is String ? avatar : null,
    );
    await _storage.write(key: _loginKey, value: account.login);
    if (account.avatarUrl != null) {
      await _storage.write(key: _avatarKey, value: account.avatarUrl);
    }
    return account;
  }

  Future<void> _storeTokens(Map<String, dynamic> data) async {
    final accessToken = data['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const GitHubAuthException('GitHub 没有返回访问令牌。');
    }
    await _storage.write(key: _accessTokenKey, value: accessToken);

    final refreshToken = data['refresh_token'];
    if (refreshToken is String && refreshToken.isNotEmpty) {
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
    }
    final expiresIn = data['expires_in'];
    if (expiresIn is num) {
      final expiresAt = DateTime.now()
          .add(Duration(seconds: expiresIn.toInt()))
          .toUtc()
          .toIso8601String();
      await _storage.write(key: _expiresAtKey, value: expiresAt);
    } else {
      await _storage.delete(key: _expiresAtKey);
    }
  }

  Map<String, String> _apiHeaders(String token) => {
    'Accept': 'application/vnd.github+json',
    'Authorization': 'Bearer $token',
    'X-GitHub-Api-Version': _apiVersion,
  };

  Map<String, dynamic> _decodeResponse(
    http.Response response, {
    bool allowOAuthError = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw GitHubAuthException(
        'GitHub 返回了无法识别的响应（HTTP ${response.statusCode}）。',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const GitHubAuthException('GitHub 返回了无效响应。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final description = decoded['message'] ?? 'HTTP ${response.statusCode}';
      throw GitHubAuthException('GitHub 请求失败：$description');
    }
    if (!allowOAuthError && decoded['error'] != null) {
      throw GitHubAuthException(
        'GitHub 请求失败：${decoded['error_description'] ?? decoded['error']}',
      );
    }
    return decoded;
  }

  static int _integer(Object? value, {required int fallback}) =>
      value is num ? value.toInt() : fallback;
}
