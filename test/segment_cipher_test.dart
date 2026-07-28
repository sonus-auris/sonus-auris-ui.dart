import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/in_memory_key_store.dart';

void main() {
  final cipher = SegmentCipher();

  Uint8List sample(int n) =>
      Uint8List.fromList(List<int>.generate(n, (i) => (i * 37 + 11) & 0xFF));

  test(
    'round-trips a segment through seal/open with the device master key',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final plaintext = sample(48000); // ~ a short PCM chunk

      final container = await cipher.seal(
        plaintext: plaintext,
        wrapDek: km.wrapDek,
      );
      expect(SegmentCipher.looksEncrypted(container), isTrue);
      expect(container.length, greaterThan(plaintext.length));
      final header = SegmentCipher.peekHeader(container);
      expect(header.wrappedDek, hasLength(SegmentCipher.wrappedDekLength));

      final recovered = await cipher.open(
        container: container,
        unwrapDek: km.unwrapDek,
      );
      expect(recovered, equals(plaintext));
    },
  );

  test('seal rejects non-canonical device and account wrapper lengths', () async {
    for (final length in [59, 61]) {
      await expectLater(
        () => cipher.seal(
          plaintext: sample(16),
          wrapDek: (_) async => Uint8List(length),
        ),
        throwsArgumentError,
      );
    }

    for (final length in [91, 93]) {
      await expectLater(
        () => cipher.seal(
          plaintext: sample(16),
          wrapDek: (_) async => Uint8List(SegmentCipher.wrappedDekLength),
          wrapForAccount: (_) async => Uint8List(length),
        ),
        throwsArgumentError,
      );
    }
  });

  test('peekHeader rejects non-canonical encoded wrapper lengths', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final v1 = await cipher.seal(
      plaintext: sample(32),
      wrapDek: km.wrapDek,
    );
    for (final length in [59, 61]) {
      final mutated = Uint8List.fromList(v1);
      mutated[6] = (length >> 8) & 0xff;
      mutated[7] = length & 0xff;
      expect(() => SegmentCipher.peekHeader(mutated), throwsFormatException);
    }

    final v2 = await cipher.seal(
      plaintext: sample(32),
      wrapDek: km.wrapDek,
      wrapForAccount: (_) async =>
          Uint8List(SegmentCipher.accountWrappedDekLength),
    );
    final accountLengthOffset = 8 + SegmentCipher.wrappedDekLength;
    for (final length in [91, 93]) {
      final mutated = Uint8List.fromList(v2);
      mutated[accountLengthOffset] = (length >> 8) & 0xff;
      mutated[accountLengthOffset + 1] = length & 0xff;
      expect(() => SegmentCipher.peekHeader(mutated), throwsFormatException);
    }
  });

  test('peekHeader rejects exact-boundary truncation and unknown flags', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final v2 = await cipher.seal(
      plaintext: sample(32),
      wrapDek: km.wrapDek,
      wrapForAccount: (_) async =>
          Uint8List(SegmentCipher.accountWrappedDekLength),
    );

    final badFlags = Uint8List.fromList(v2)..[5] = 0x07;
    expect(() => SegmentCipher.peekHeader(badFlags), throwsFormatException);

    final contentOffset =
        8 +
        SegmentCipher.wrappedDekLength +
        2 +
        SegmentCipher.accountWrappedDekLength;
    final truncated = Uint8List.sublistView(
      v2,
      0,
      contentOffset + SegmentCipher.minimumContentBoxLength - 1,
    );
    expect(() => SegmentCipher.peekHeader(truncated), throwsFormatException);
  });

  test('a different device master key cannot open the container', () async {
    final alice = KeyManager(store: InMemoryKeyStore());
    final mallory = KeyManager(store: InMemoryKeyStore());
    final container = await cipher.seal(
      plaintext: sample(1024),
      wrapDek: alice.wrapDek,
    );

    expect(
      () => cipher.open(container: container, unwrapDek: mallory.unwrapDek),
      throwsA(isA<Object>()),
    );
  });

  test('each seal uses a fresh DEK and nonce (ciphertexts differ)', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final plaintext = sample(2048);
    final a = await cipher.seal(plaintext: plaintext, wrapDek: km.wrapDek);
    final b = await cipher.seal(plaintext: plaintext, wrapDek: km.wrapDek);
    expect(a, isNot(equals(b)));
  });

  test(
    'tampering with the ciphertext is detected (GCM auth failure)',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final container = await cipher.seal(
        plaintext: sample(4096),
        wrapDek: km.wrapDek,
      );
      container[container.length - 1] ^= 0x01; // flip a bit in the tag/cipher

      expect(
        () => cipher.open(container: container, unwrapDek: km.unwrapDek),
        throwsA(isA<Object>()),
      );
    },
  );

  test('peekHeader rejects non-container bytes', () {
    final plain = sample(64);
    expect(SegmentCipher.looksEncrypted(plain), isFalse);
    expect(() => SegmentCipher.peekHeader(plain), throwsFormatException);
  });

  test(
    'released DEK decrypts exactly that one segment (opt-in job path)',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final plaintext = sample(1500);
      final container = await cipher.seal(
        plaintext: plaintext,
        wrapDek: km.wrapDek,
      );
      final header = SegmentCipher.peekHeader(container);

      // The app releases only this segment's DEK to a server job.
      final dekBytes = await km.releaseDekForJob(header.wrappedDek);
      expect(dekBytes.length, SegmentCipher.dekLength);
    },
  );
}
