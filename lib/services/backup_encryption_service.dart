import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Encrypts ledger snapshots before they leave the device.
///
/// PBKDF2 uses 600,000 HMAC-SHA256 iterations. The passphrase is needed to
/// restore a backup on another device, so it must be remembered separately.
class BackupEncryptionService {
  static const _format = 'pikachu_ledger_encrypted_backup';
  static const _version = 1;
  static const _iterations = 600000;

  static final _cipher = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _iterations,
    bits: 256,
  );

  Future<String> encryptSnapshot(
    Map<String, Object?> snapshot,
    String passphrase,
  ) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final key = await _kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    final compressed = gzip.encode(utf8.encode(jsonEncode(snapshot)));
    final secretBox = await _cipher.encrypt(compressed, secretKey: key);

    return jsonEncode({
      'format': _format,
      'version': _version,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _iterations,
      'cipher': 'AES-256-GCM',
      'compression': 'gzip',
      'salt': base64Encode(salt),
      'nonce': base64Encode(secretBox.nonce),
      'ciphertext': base64Encode(secretBox.cipherText),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  Future<Map<String, Object?>> decryptSnapshot(
    String encryptedBackup,
    String passphrase,
  ) async {
    final decoded = jsonDecode(encryptedBackup);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != _format ||
        decoded['version'] != _version ||
        decoded['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        decoded['iterations'] != _iterations ||
        decoded['cipher'] != 'AES-256-GCM' ||
        decoded['compression'] != 'gzip') {
      throw const FormatException('加密备份格式或版本不受支持。');
    }

    try {
      final salt = base64Decode(decoded['salt'] as String);
      final nonce = base64Decode(decoded['nonce'] as String);
      final ciphertext = base64Decode(decoded['ciphertext'] as String);
      final mac = Mac(base64Decode(decoded['mac'] as String));
      final key = await _kdf.deriveKeyFromPassword(
        password: passphrase,
        nonce: salt,
      );
      final cleartext = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: mac),
        secretKey: key,
      );
      final snapshot = jsonDecode(utf8.decode(gzip.decode(cleartext)));
      if (snapshot is! Map) {
        throw const FormatException('解密后的账本数据格式无效。');
      }
      return snapshot.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('加密口令错误，或备份文件已损坏。');
    } on TypeError {
      throw const FormatException('加密备份内容无效或已损坏。');
    }
  }
}
