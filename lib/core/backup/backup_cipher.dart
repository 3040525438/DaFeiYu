/// 备份加解密（对齐 SwiftUI 版 BackupCrypto.swift）。
///
/// 容器格式：`DFBK1`（5 字节 magic）+ 版本（1 字节）+ 12 字节 nonce + 密文（含 GCM 认证标签）。
/// 明文备份不经过本容器，由上层显式二次确认后直接写 JSON。
/// 密钥只存本地安全存储（真机用 flutter_secure_storage，测试用内存替身），
/// 永不随备份文件一起导出（D44：密钥丢失即无法解密）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/models/backup.dart';

/// 备份密钥存储抽象：App 用 FlutterSecureStorage；测试用内存替身。
abstract class BackupKeyStoring {
  /// 读取密钥；不存在则生成 32 字节随机密钥并持久化
  Future<Uint8List> loadOrCreateKey();

  /// 只读取密钥，不生成
  Future<Uint8List?> existingKey();

  Future<void> deleteKey();
}

/// 真机实现：密钥存 flutter_secure_storage（base64 编码）
class SecureStorageKeyStore implements BackupKeyStoring {
  SecureStorageKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _keyName = 'backup.master_key';
  final FlutterSecureStorage _storage;
  final Random _random = Random.secure();

  @override
  Future<Uint8List> loadOrCreateKey() async {
    final existing = await existingKey();
    if (existing != null) return existing;
    final key = _generateKey();
    await _storage.write(key: _keyName, value: base64Encode(key));
    return key;
  }

  @override
  Future<Uint8List?> existingKey() async {
    final stored = await _storage.read(key: _keyName);
    if (stored == null || stored.isEmpty) return null;
    return Uint8List.fromList(base64Decode(stored));
  }

  @override
  Future<void> deleteKey() async {
    await _storage.delete(key: _keyName);
  }

  Uint8List _generateKey() {
    return Uint8List.fromList(
      List<int>.generate(32, (int _) => _random.nextInt(256)),
    );
  }
}

/// 测试用内存密钥存储
class InMemoryKeyStore implements BackupKeyStoring {
  Uint8List? _key;

  @override
  Future<Uint8List> loadOrCreateKey() async {
    final existing = await existingKey();
    if (existing != null) return existing;
    _key = Uint8List.fromList(
      List<int>.generate(32, (int _) => Random.secure().nextInt(256)),
    );
    return _key!;
  }

  @override
  Future<Uint8List?> existingKey() async => _key;

  @override
  Future<void> deleteKey() async {
    _key = null;
  }
}

/// 备份容器：封印（加密）与开封（解密）
class BackupContainer {
  static const List<int> magic = <int>[0x44, 0x46, 0x42, 0x4B, 0x31]; // "DFBK1"
  static const int version = 1;
  static const int nonceLength = 12;
  static int get headerLength => magic.length + 1 + nonceLength;
  static const String cipherIdentifier = 'aes-256-gcm';

  static final AesGcm _aesGcm = AesGcm.with256bits();

  /// 校验密钥长度
  static void validateKey(Uint8List key) {
    if (key.length != 32) {
      throw BackupCipherError.invalidKeyLength(key.length);
    }
  }

  static Uint8List randomNonce() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(nonceLength, (int _) => random.nextInt(256)),
    );
  }

  /// 封印：`plaintext` → DFBK1 容器
  static Future<Uint8List> seal(Uint8List plaintext, Uint8List key) async {
    validateKey(key);
    final nonce = randomNonce();
    final secretKey = SecretKeyData(key);
    final box = await _aesGcm.encrypt(plaintext, secretKey: secretKey, nonce: nonce);
    final bytes = <int>[
      ...magic,
      version,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ];
    return Uint8List.fromList(bytes);
  }

  /// 开封：DFBK1 容器 → `plaintext`
  static Future<Uint8List> open(Uint8List container, Uint8List key) async {
    validateKey(key);
    if (container.length < headerLength) {
      throw BackupCipherError.truncatedContainer;
    }
    for (var i = 0; i < magic.length; i++) {
      if (container[i] != magic[i]) throw BackupCipherError.badMagic;
    }
    final containerVersion = container[magic.length];
    if (containerVersion != version) {
      throw BackupCipherError.unsupportedVersion(containerVersion);
    }
    final nonce = container.sublist(magic.length + 1, headerLength);
    final sealed = container.sublist(headerLength);
    if (sealed.isEmpty) throw BackupCipherError.truncatedContainer;
    if (sealed.length < 16) throw BackupCipherError.authenticationFailed;
    try {
      final clear = await _aesGcm.decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(sealed.sublist(sealed.length - 16)),
        ),
        secretKey: SecretKeyData(key),
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw BackupCipherError.authenticationFailed;
    }
  }

  /// 判断字节流是否为 DFBK1 容器
  static bool isContainer(Uint8List data) {
    if (data.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) return false;
    }
    return true;
  }
}
