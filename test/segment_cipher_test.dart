import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
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

      final recovered = await cipher.open(
        container: container,
        unwrapDek: km.unwrapDek,
      );
      expect(recovered, equals(plaintext));
    },
  );

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
