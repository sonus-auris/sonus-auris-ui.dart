import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'segment_cipher.dart';

/// Public-key wrapping of a segment DEK to the **account** recipient.
///
/// This is what lets an authorized peer read another device's encrypted object
/// while a device master key remains local: a phone seals each segment DEK to
/// the account's X25519 **public** key, and only a holder of the corresponding
/// account **private** seed can open it. Anonymous sealed-box construction:
///
/// ```
/// blob = ephemeralPublicKey(32) | nonce(12) | ciphertext(32) | tag(16)
/// shared = X25519(ephemeralPrivate, accountPublic)
/// key    = HKDF-SHA256(shared, info="sonus-auris/account-recipient/v1")
/// (ct,tag) = AES-256-GCM(dek, key, nonce)
/// ```
///
/// Both sides reject a non-contributory/all-zero X25519 output before HKDF.
/// The Rust peer must implement this exact 92-byte wire format.
///
/// This is a cryptographic primitive, not sync authorization. A receiver must
/// verify the signed manifest, device/account binding, complete container
/// hash and length, key epoch, recipient-set hash, and predecessor checkpoint
/// before using [open] to expose synchronized plaintext or mutate durable state.
class AccountRecipient {
  AccountRecipient({X25519? x25519, AesGcm? aead})
    : _x25519 = x25519 ?? X25519(),
      _aead = aead ?? AesGcm.with256bits();

  static const int publicKeyLength = 32;
  static const int sealedDekLength =
      publicKeyLength +
      SegmentCipher.nonceLength +
      SegmentCipher.dekLength +
      SegmentCipher.macLength;
  static const List<int> _info = [
    // utf8 "sonus-auris/account-recipient/v1"
    115, 111, 110, 117, 115, 45, 97, 117, 114, 105, 115, 47, 97, 99, 99, 111,
    117, 110, 116, 45, 114, 101, 99, 105, 112, 105, 101, 110, 116, 47, 118, 49,
  ];

  final X25519 _x25519;
  final AesGcm _aead;

  /// Generates a fresh account keypair. The 32-byte seed is the private key to
  /// store encrypted under the account recovery/authorization boundary; the
  /// public bytes may be published in a verified key bundle.
  Future<AccountKeyPair> generateKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    try {
      final publicKey = await keyPair.extractPublicKey();
      final privateSeed = await keyPair.extractPrivateKeyBytes();
      if (publicKey.bytes.length != publicKeyLength ||
          privateSeed.length != publicKeyLength) {
        throw StateError('X25519 produced an invalid key length.');
      }
      return AccountKeyPair(
        publicKey: Uint8List.fromList(publicKey.bytes),
        privateSeed: Uint8List.fromList(privateSeed),
      );
    } finally {
      keyPair.destroy();
    }
  }

  /// Seals [dekBytes] (a raw 32-byte DEK) to the account [publicKey]. Suitable as
  /// the `wrapForAccount` callback for [SegmentCipher.seal].
  Future<Uint8List> seal({
    required Uint8List publicKey,
    required List<int> dekBytes,
  }) async {
    if (publicKey.length != publicKeyLength) {
      throw ArgumentError('Account public key must be 32 bytes.');
    }
    if (dekBytes.length != SegmentCipher.dekLength) {
      throw ArgumentError('Data encryption key must be 32 bytes.');
    }

    final publicKeySnapshot = Uint8List.fromList(publicKey);
    final dekSnapshot = Uint8List.fromList(dekBytes);
    try {
      final ephemeral = await _x25519.newKeyPair();
      try {
        final ephemeralPublic = await ephemeral.extractPublicKey();
        if (ephemeralPublic.bytes.length != publicKeyLength) {
          throw StateError('X25519 produced an invalid public key length.');
        }
        final shared = await _sharedSecret(
          keyPair: ephemeral,
          remotePublicKey: SimplePublicKey(
            publicKeySnapshot,
            type: KeyPairType.x25519,
          ),
        );
        final key = await _deriveValidatedKey(shared);
        try {
          final box = await _aead.encrypt(dekSnapshot, secretKey: key);
          final out = BytesBuilder(copy: false)
            ..add(ephemeralPublic.bytes)
            ..add(box.concatenation());
          final encoded = out.toBytes();
          if (encoded.length != sealedDekLength) {
            throw StateError(
              'Account-sealed DEK has an invalid encoded length.',
            );
          }
          return encoded;
        } finally {
          key.destroy();
        }
      } finally {
        ephemeral.destroy();
      }
    } finally {
      _zeroize(dekSnapshot);
    }
  }

  /// Opens a sealed blob with the account [privateSeed] (32-byte X25519 seed),
  /// recovering the DEK bytes after the caller has completed sync authorization.
  Future<Uint8List> open({
    required Uint8List privateSeed,
    required Uint8List blob,
  }) async {
    if (privateSeed.length != publicKeyLength) {
      throw const FormatException('Account private seed must be 32 bytes.');
    }
    if (blob.length != sealedDekLength) {
      throw FormatException(
        'Account-sealed DEK must be exactly $sealedDekLength bytes.',
      );
    }

    final privateSeedSnapshot = Uint8List.fromList(privateSeed);
    final blobSnapshot = Uint8List.fromList(blob);
    try {
      final ephemeralPublic = Uint8List.sublistView(
        blobSnapshot,
        0,
        publicKeyLength,
      );
      final rest = Uint8List.sublistView(blobSnapshot, publicKeyLength);
      final keyPair = await _x25519.newKeyPairFromSeed(privateSeedSnapshot);
      try {
        final shared = await _sharedSecret(
          keyPair: keyPair,
          remotePublicKey: SimplePublicKey(
            ephemeralPublic,
            type: KeyPairType.x25519,
          ),
        );
        final key = await _deriveValidatedKey(shared);
        try {
          final secretBox = SecretBox.fromConcatenation(
            rest,
            nonceLength: SegmentCipher.nonceLength,
            macLength: SegmentCipher.macLength,
          );
          final dek = await _aead.decrypt(secretBox, secretKey: key);
          try {
            if (dek.length != SegmentCipher.dekLength) {
              throw const FormatException(
                'Account-sealed DEK did not contain a 32-byte key.',
              );
            }
            return Uint8List.fromList(dek);
          } finally {
            _zeroize(dek);
          }
        } finally {
          key.destroy();
        }
      } finally {
        keyPair.destroy();
      }
    } finally {
      _zeroize(privateSeedSnapshot);
    }
  }

  Future<SecretKey> _sharedSecret({
    required SimpleKeyPair keyPair,
    required SimplePublicKey remotePublicKey,
  }) async {
    try {
      return await _x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: remotePublicKey,
      );
    } catch (_) {
      throw const FormatException(
        'X25519 key agreement rejected a non-contributory public key.',
      );
    }
  }

  Future<SecretKey> _deriveValidatedKey(SecretKey shared) async {
    try {
      final bytes = await shared.extractBytes();
      if (bytes.length != publicKeyLength) {
        throw const FormatException(
          'X25519 key agreement produced an invalid shared-secret length.',
        );
      }
      // Scan every byte and branch only after the fixed 32-byte loop; do not use
      // `every`, `any`, or an early return that leaks the first non-zero offset.
      var aggregate = 0;
      for (final byte in bytes) {
        aggregate |= byte;
      }
      if (aggregate == 0) {
        throw const FormatException(
          'X25519 key agreement produced a non-contributory shared secret.',
        );
      }
      return await _deriveKey(shared);
    } finally {
      shared.destroy();
    }
  }

  Future<SecretKey> _deriveKey(SecretKey shared) {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: SegmentCipher.dekLength,
    );
    return hkdf.deriveKey(secretKey: shared, nonce: const [], info: _info);
  }

  static void _zeroize(List<int> bytes) {
    try {
      bytes.fillRange(0, bytes.length, 0);
    } on UnsupportedError {
      // Some platform providers expose read-only views; key objects are still
      // invalidated with destroy(), but physical erasure is provider-dependent.
    }
  }
}

class AccountKeyPair {
  const AccountKeyPair({required this.publicKey, required this.privateSeed});

  final Uint8List publicKey;
  final Uint8List privateSeed;

  String get publicKeyBase64 => base64Encode(publicKey);
}
