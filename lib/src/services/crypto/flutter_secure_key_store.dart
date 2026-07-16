import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'key_manager.dart';

/// [SecureKeyStore] backed by the platform secure store: the iOS Keychain
/// (with `first_unlock_this_device` accessibility so the key is never synced
/// off-device or included in unencrypted backups) and Android Keystore-backed
/// Android Keystore-protected storage.
class FlutterSecureKeyStore implements SecureKeyStore {
  FlutterSecureKeyStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
