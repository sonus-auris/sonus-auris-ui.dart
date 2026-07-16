// ignore_for_file: prefer_initializing_formals

import 'dart:typed_data';

import 'account_recipient.dart';
import 'key_manager.dart';
import 'segment_cipher.dart';

/// Thin facade the upload/download paths depend on, so they never touch key
/// material directly. Seals plaintext audio into a [SegmentCipher] container
/// before it leaves the device, and opens containers coming back from the cloud.
class SegmentEncryptor {
  // Keep stable public named parameters (`keyManager`, `accountPublicKey`);
  // initializing formals would expose private field names as API.
  SegmentEncryptor({
    required KeyManager keyManager,
    SegmentCipher? cipher,
    AccountRecipient? accountRecipient,
    Uint8List? accountPublicKey,
  }) : _keyManager = keyManager,
       _cipher = cipher ?? SegmentCipher(),
       _accountRecipient = accountRecipient ?? AccountRecipient(),
       _accountPublicKey = accountPublicKey;

  final KeyManager _keyManager;
  final SegmentCipher _cipher;
  final AccountRecipient _accountRecipient;

  /// The account's X25519 public key, once provisioned onto this device. When
  /// set, every sealed segment is *also* wrapped to the account so the desktop
  /// master can read it (v2 container). Null on a device that has not yet synced
  /// the account key → v1 (device-only) containers, exactly as before.
  Uint8List? _accountPublicKey;

  bool get hasAccountRecipient => _accountPublicKey != null;

  /// Sets (or clears) the account public key, e.g. after the device syncs it
  /// from the backend on login.
  set accountPublicKey(Uint8List? key) => _accountPublicKey = key;

  /// Encrypts audio bytes for upload. The returned container is what is hashed,
  /// sized, and PUT to the cloud — the plaintext never leaves the device.
  Future<Uint8List> seal(Uint8List plaintext) {
    final accountKey = _accountPublicKey;
    return _cipher.seal(
      plaintext: plaintext,
      wrapDek: _keyManager.wrapDek,
      wrapForAccount: accountKey == null
          ? null
          : (dek) async => _accountRecipient.seal(
              publicKey: accountKey,
              dekBytes: await dek.extractBytes(),
            ),
    );
  }

  /// Decrypts a container fetched from the cloud. Bytes that are not a
  /// recognised container (legacy, pre-encryption objects) are returned as-is
  /// so older backups remain playable. This device always opens via its own
  /// device key (the account-recipient block is for the desktop master).
  Future<Uint8List> open(Uint8List bytes) {
    if (!SegmentCipher.looksEncrypted(bytes)) {
      return Future<Uint8List>.value(bytes);
    }
    return _cipher.open(container: bytes, unwrapDek: _keyManager.unwrapDek);
  }

  /// Whether on-device encryption is active. Always true once constructed;
  /// exposed so call sites can branch without a null-check on the encryptor.
  bool get enabled => true;
}
