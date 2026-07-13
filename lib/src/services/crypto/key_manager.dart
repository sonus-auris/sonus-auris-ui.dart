import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'segment_cipher.dart';

/// Minimal secure key/value store so [KeyManager] can be unit-tested without
/// the platform plugin. In the app this is backed by `flutter_secure_storage`
/// (iOS Keychain / Android Keystore-backed EncryptedSharedPreferences).
abstract class SecureKeyStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Owns the device **master key (MK)** and all key-wrapping operations.
///
/// The MK is generated on first launch and never leaves the device in the
/// clear: it lives in the platform secure enclave-backed store and is only ever
/// exported *wrapped* by a key the user controls (a recovery passphrase, or an
/// account-escrow secret released after Supabase 2FA). This is what keeps the
/// system zero-knowledge — the backend can hold every recovery blob and still
/// never recover the MK on its own.
class KeyManager {
  KeyManager({required this._store, AesGcm? aead, Argon2id? passphraseKdf})
    : _aead = aead ?? AesGcm.with256bits(),
      _passphraseKdf = passphraseKdf ?? _defaultPassphraseKdf();

  /// Storage key for the base64 master key. Bumped if the format ever changes.
  static const String masterKeyStorageId = 'sa.mk.v1';

  /// OWASP-leaning Argon2id parameters. Tunable per-device if enrollment is slow.
  static Argon2id _defaultPassphraseKdf() => Argon2id(
    memory: 19 * 1024, // 19 MiB
    parallelism: 1,
    iterations: 2,
    hashLength: SegmentCipher.dekLength,
  );

  final SecureKeyStore _store;
  final AesGcm _aead;
  final Argon2id _passphraseKdf;
  final Random _random = Random.secure();

  SecretKey? _cachedMasterKey;

  /// Returns the device master key, generating and persisting one on first use.
  Future<SecretKey> getOrCreateMasterKey() async {
    final cached = _cachedMasterKey;
    if (cached != null) {
      return cached;
    }
    final existing = await _store.read(masterKeyStorageId);
    if (existing != null && existing.trim().isNotEmpty) {
      final bytes = base64Decode(existing.trim());
      if (bytes.length != SegmentCipher.dekLength) {
        throw StateError('Stored master key has an unexpected length.');
      }
      return _cachedMasterKey = SecretKey(bytes);
    }
    final created = await _aead.newSecretKey();
    final bytes = await created.extractBytes();
    await _store.write(masterKeyStorageId, base64Encode(bytes));
    return _cachedMasterKey = created;
  }

  /// True once a master key exists on this device.
  Future<bool> hasMasterKey() async {
    if (_cachedMasterKey != null) {
      return true;
    }
    final existing = await _store.read(masterKeyStorageId);
    return existing != null && existing.trim().isNotEmpty;
  }

  /// Wraps a per-segment DEK with the master key. Suitable as the `wrapDek`
  /// callback for [SegmentCipher.seal].
  Future<Uint8List> wrapDek(SecretKey dek) async {
    final mk = await getOrCreateMasterKey();
    final dekBytes = await dek.extractBytes();
    final box = await _aead.encrypt(dekBytes, secretKey: mk);
    return box.concatenation();
  }

  /// Recovers a per-segment DEK from its wrapped form. Suitable as the
  /// `unwrapDek` callback for [SegmentCipher.open].
  Future<SecretKey> unwrapDek(Uint8List wrappedDek) async {
    final mk = await getOrCreateMasterKey();
    final box = SecretBox.fromConcatenation(
      wrappedDek,
      nonceLength: SegmentCipher.nonceLength,
      macLength: SegmentCipher.macLength,
    );
    final dekBytes = await _aead.decrypt(box, secretKey: mk);
    return SecretKey(dekBytes);
  }

  /// Hands a single DEK to the caller in the clear, for the rare, user-initiated
  /// server-side job that needs one clip decrypted (e.g. mirroring a saved clip
  /// into Google Drive). Only ever called per-clip and never exposes the MK.
  Future<Uint8List> releaseDekForJob(Uint8List wrappedDek) async {
    final dek = await unwrapDek(wrappedDek);
    return Uint8List.fromList(await dek.extractBytes());
  }

  // --- Recovery: passphrase -------------------------------------------------

  /// Wraps the master key under a key derived from [passphrase] (Argon2id).
  /// The returned JSON-encodable blob is safe to store anywhere — including our
  /// own backend — because it is useless without the passphrase.
  Future<Map<String, Object?>> exportPassphraseRecovery(
    String passphrase,
  ) async {
    _requireStrongPassphrase(passphrase);
    final mk = await getOrCreateMasterKey();
    final salt = _randomBytes(16);
    final wrappingKey = await _passphraseKdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    final mkBytes = await mk.extractBytes();
    final box = await _aead.encrypt(mkBytes, secretKey: wrappingKey);
    return <String, Object?>{
      'v': 1,
      'kdf': 'argon2id',
      'mem': _passphraseKdf.memory,
      'par': _passphraseKdf.parallelism,
      'it': _passphraseKdf.iterations,
      'salt': base64Encode(salt),
      'blob': base64Encode(box.concatenation()),
    };
  }

  /// Restores and persists the master key from a passphrase recovery blob.
  /// Throws if the passphrase is wrong (GCM auth failure) or the blob is malformed.
  Future<void> restoreFromPassphraseRecovery(
    String passphrase,
    Map<String, Object?> recovery,
  ) async {
    final kdf = Argon2id(
      memory: (recovery['mem'] as num?)?.toInt() ?? _passphraseKdf.memory,
      parallelism:
          (recovery['par'] as num?)?.toInt() ?? _passphraseKdf.parallelism,
      iterations:
          (recovery['it'] as num?)?.toInt() ?? _passphraseKdf.iterations,
      hashLength: SegmentCipher.dekLength,
    );
    final salt = base64Decode(recovery['salt'] as String);
    final wrappingKey = await kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
    final mkBytes = await _decryptConcat(
      recovery['blob'] as String,
      wrappingKey,
    );
    await _persistMasterKey(mkBytes);
  }

  // --- Recovery: account escrow (Supabase 2FA gated) ------------------------

  /// Generates a high-entropy account-recovery secret, wraps the master key
  /// under it, and returns both. The caller escrows the *blob* on the backend
  /// (released only after Supabase 2FA) and keeps the *secret* under the user's
  /// account control (e.g. shown once as a recovery code, or stored in the
  /// user's own password manager). The backend never sees the secret, so it can
  /// hold the blob and still never recover the MK — preserving zero-knowledge.
  Future<AccountRecoveryMaterial> exportAccountRecovery() async {
    final mk = await getOrCreateMasterKey();
    final secret = _randomBytes(32);
    final salt = _randomBytes(16);
    final wrappingKey = await _deriveAccountKey(secret, salt);
    final mkBytes = await mk.extractBytes();
    final box = await _aead.encrypt(mkBytes, secretKey: wrappingKey);
    return AccountRecoveryMaterial(
      recoverySecretBase64: base64Encode(secret),
      blob: <String, Object?>{
        'v': 1,
        'kdf': 'hkdf-sha256',
        'salt': base64Encode(salt),
        'blob': base64Encode(box.concatenation()),
      },
    );
  }

  /// Restores the master key from an account-recovery blob plus its secret.
  Future<void> restoreFromAccountRecovery(
    String recoverySecretBase64,
    Map<String, Object?> recovery,
  ) async {
    final secret = base64Decode(recoverySecretBase64.trim());
    final salt = base64Decode(recovery['salt'] as String);
    final wrappingKey = await _deriveAccountKey(secret, salt);
    final mkBytes = await _decryptConcat(
      recovery['blob'] as String,
      wrappingKey,
    );
    await _persistMasterKey(mkBytes);
  }

  Future<SecretKey> _deriveAccountKey(List<int> secret, List<int> salt) async {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: SegmentCipher.dekLength,
    );
    return hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: salt,
      info: utf8.encode('sonus-auris/account-recovery/v1'),
    );
  }

  // --- internals ------------------------------------------------------------

  Future<List<int>> _decryptConcat(String b64, SecretKey key) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(b64),
      nonceLength: SegmentCipher.nonceLength,
      macLength: SegmentCipher.macLength,
    );
    return _aead.decrypt(box, secretKey: key);
  }

  Future<void> _persistMasterKey(List<int> mkBytes) async {
    if (mkBytes.length != SegmentCipher.dekLength) {
      throw StateError('Recovered master key has an unexpected length.');
    }
    await _store.write(masterKeyStorageId, base64Encode(mkBytes));
    _cachedMasterKey = SecretKey(mkBytes);
  }

  void _requireStrongPassphrase(String passphrase) {
    if (passphrase.trim().length < 10) {
      throw ArgumentError(
        'Recovery passphrase must be at least 10 characters.',
      );
    }
  }

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}

/// The two halves of an account-recovery enrolment: the [blob] (escrowed on the
/// backend behind 2FA) and the [recoverySecretBase64] (kept by the user).
class AccountRecoveryMaterial {
  const AccountRecoveryMaterial({
    required this.recoverySecretBase64,
    required this.blob,
  });

  final String recoverySecretBase64;
  final Map<String, Object?> blob;
}
