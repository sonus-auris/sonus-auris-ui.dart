import 'package:audio_dashcam/src/services/crypto/key_manager.dart';

/// A non-persistent [SecureKeyStore] for tests. Mirrors the plugin contract:
/// reads return null when absent, writes overwrite.
class InMemoryKeyStore implements SecureKeyStore {
  InMemoryKeyStore([Map<String, String>? seed]) : _data = {...?seed};

  final Map<String, String> _data;

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}
