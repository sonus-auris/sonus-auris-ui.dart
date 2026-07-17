import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// On-device, zero-knowledge encryption for recorded audio segments.
///
/// Every segment is sealed on the phone *before* it leaves for the cloud using
/// envelope encryption:
///
///   * a fresh random 256-bit **data encryption key (DEK)** encrypts the audio
///     bytes with AES-256-GCM;
///   * the DEK is itself wrapped with the device **master key (MK)**, which is
///     held only in the platform Keychain / Keystore (see [KeyManager]).
///
/// The cloud (S3, Google Drive, iCloud, …) and our own backend only ever see
/// the [SegmentEnvelope] — ciphertext plus the *wrapped* DEK. Without the MK
/// nobody, including us, can recover the audio. For the rare, user-initiated
/// server-side job (e.g. mirroring a saved clip into the user's Google Drive)
/// the app unwraps a single DEK and hands only that one key to the backend; the
/// MK never leaves the device.
///
/// ## Container layout (version 1)
///
/// ```
/// offset  size  field
/// 0       4     magic            "SAC1"
/// 4       1     version          0x01
/// 5       1     flags            bit0 = DEK wrapped by device master key
/// 6       2     wrappedDekLen    uint16, big-endian
/// 8       L     wrappedDek       AES-256-GCM(DEK) as nonce|cipher|mac
/// 8+L     ...   contentBox       AES-256-GCM(audio) as nonce|cipher|mac
/// ```
///
/// The container is provider-agnostic: it is prepended to the object body so it
/// works identically for an S3 `PUT`, a Drive upload, or an iCloud file.
class SegmentCipher {
  SegmentCipher({AesGcm? aead}) : _aead = aead ?? AesGcm.with256bits();

  static const List<int> magic = <int>[0x53, 0x41, 0x43, 0x31]; // "SAC1"
  static const int version = 1;
  static const int versionMultiRecipient = 2;
  static const int _flagWrappedByMasterKey = 0x01;
  static const int _flagAccountRecipient = 0x02;

  /// AES-GCM standard sizes, in bytes.
  static const int nonceLength = 12;
  static const int macLength = 16;
  static const int dekLength = 32;
  static const int _headerFixedLength = 8; // magic+version+flags+u16 len

  final AesGcm _aead;

  /// Encrypts [plaintext] under a fresh DEK and returns the self-describing
  /// container. [wrapDek] (from the [KeyManager]) seals the DEK with the device
  /// master key so this device can read its own segment.
  ///
  /// When [wrapForAccount] is supplied (the device has an account public key),
  /// the DEK is *also* sealed to the account recipient, producing a v2
  /// multi-recipient container that the desktop master can open with the account
  /// private key. Without it, a v1 container is produced exactly as before.
  Future<Uint8List> seal({
    required Uint8List plaintext,
    required Future<Uint8List> Function(SecretKey dek) wrapDek,
    Future<Uint8List> Function(SecretKey dek)? wrapForAccount,
  }) async {
    final dek = await _aead.newSecretKey();
    final wrappedDek = await wrapDek(dek);
    final accountWrapped = wrapForAccount == null
        ? null
        : await wrapForAccount(dek);
    if (wrappedDek.length > 0xFFFF ||
        (accountWrapped != null && accountWrapped.length > 0xFFFF)) {
      throw ArgumentError('Wrapped DEK is too large to encode.');
    }
    final contentBox = await _aead.encrypt(plaintext, secretKey: dek);
    final contentBytes = contentBox.concatenation();

    final out = BytesBuilder(copy: false);
    out.add(magic);
    if (accountWrapped == null) {
      out.addByte(version);
      out.addByte(_flagWrappedByMasterKey);
      out.add(_u16be(wrappedDek.length));
      out.add(wrappedDek);
    } else {
      out.addByte(versionMultiRecipient);
      out.addByte(_flagWrappedByMasterKey | _flagAccountRecipient);
      out.add(_u16be(wrappedDek.length));
      out.add(wrappedDek);
      out.add(_u16be(accountWrapped.length));
      out.add(accountWrapped);
    }
    out.add(contentBytes);
    return out.toBytes();
  }

  /// Reverses [seal]. [unwrapDek] is supplied by the [KeyManager] and recovers
  /// the DEK from its wrapped form using the device master key.
  Future<Uint8List> open({
    required Uint8List container,
    required Future<SecretKey> Function(Uint8List wrappedDek) unwrapDek,
  }) async {
    final header = peekHeader(container);
    final dek = await unwrapDek(header.wrappedDek);
    final contentBytes = Uint8List.sublistView(container, header.contentOffset);
    final box = SecretBox.fromConcatenation(
      contentBytes,
      nonceLength: nonceLength,
      macLength: macLength,
    );
    final clear = await _aead.decrypt(box, secretKey: dek);
    return Uint8List.fromList(clear);
  }

  /// Parses the fixed header without decrypting. Throws [FormatException] when
  /// the bytes are not a recognised container (e.g. legacy plaintext objects).
  static SegmentHeader peekHeader(Uint8List container) {
    if (container.length < _headerFixedLength) {
      throw const FormatException('Encrypted segment is truncated.');
    }
    for (var i = 0; i < magic.length; i++) {
      if (container[i] != magic[i]) {
        throw const FormatException('Not a Sonus Auris encrypted segment.');
      }
    }
    final ver = container[4];
    if (ver != version && ver != versionMultiRecipient) {
      throw FormatException('Unsupported segment cipher version: $ver.');
    }
    final flags = container[5];
    final wrappedDekLen = (container[6] << 8) | container[7];
    var offset = _headerFixedLength + wrappedDekLen;
    if (container.length < offset + 2) {
      throw const FormatException('Encrypted segment is truncated.');
    }
    final wrappedDek = Uint8List.sublistView(
      container,
      _headerFixedLength,
      offset,
    );

    Uint8List? accountWrappedDek;
    if (ver == versionMultiRecipient && (flags & _flagAccountRecipient) != 0) {
      final accountLen = (container[offset] << 8) | container[offset + 1];
      final accountStart = offset + 2;
      final accountEnd = accountStart + accountLen;
      if (container.length < accountEnd) {
        throw const FormatException('Encrypted segment is truncated.');
      }
      accountWrappedDek = Uint8List.sublistView(
        container,
        accountStart,
        accountEnd,
      );
      offset = accountEnd;
    }
    if (container.length < offset + nonceLength + macLength) {
      throw const FormatException('Encrypted segment is truncated.');
    }
    return SegmentHeader(
      version: ver,
      flags: flags,
      wrappedDek: wrappedDek,
      accountWrappedDek: accountWrappedDek,
      contentOffset: offset,
    );
  }

  /// True when [bytes] begins with the container magic. Lets the download path
  /// transparently pass through any legacy, pre-encryption objects.
  static bool looksEncrypted(Uint8List bytes) {
    if (bytes.length < magic.length) {
      return false;
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  static Uint8List _u16be(int value) {
    return Uint8List(2)
      ..[0] = (value >> 8) & 0xFF
      ..[1] = value & 0xFF;
  }
}

class SegmentHeader {
  const SegmentHeader({
    required this.version,
    required this.flags,
    required this.wrappedDek,
    required this.contentOffset,
    this.accountWrappedDek,
  });

  final int version;
  final int flags;

  /// DEK wrapped to this device's master key (lets the device read its own).
  final Uint8List wrappedDek;

  /// DEK sealed to the account public key (lets the desktop master read it),
  /// present only in v2 multi-recipient containers.
  final Uint8List? accountWrappedDek;

  final int contentOffset;
}
