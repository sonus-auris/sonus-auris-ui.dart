import 'dart:async';
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

  test(
    'open snapshots validated wrappers and content before awaiting',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final plaintext = sample(512);
      final container = await cipher.seal(
        plaintext: plaintext,
        wrapDek: km.wrapDek,
        wrapForAccount: (_) async =>
            sample(SegmentCipher.accountWrappedDekLength),
      );
      final parsed = SegmentCipher.peekHeader(container);
      final expectedDeviceWrapper = Uint8List.fromList(parsed.wrappedDek);
      final expectedAccountWrapper = Uint8List.fromList(
        parsed.accountWrappedDek!,
      );
      final unwrapStarted = Completer<void>();
      final allowUnwrap = Completer<void>();
      Uint8List? callbackWrapper;

      final opened = cipher.open(
        container: container,
        unwrapDek: (wrappedDek) async {
          callbackWrapper = wrappedDek;
          unwrapStarted.complete();
          await allowUnwrap.future;
          return km.unwrapDek(wrappedDek);
        },
      );
      await unwrapStarted.future;
      container.fillRange(8, container.length, 0);

      expect(parsed.wrappedDek, expectedDeviceWrapper);
      expect(parsed.accountWrappedDek, expectedAccountWrapper);
      expect(callbackWrapper, expectedDeviceWrapper);
      allowUnwrap.complete();
      expect(await opened, plaintext);
    },
  );

  test('seal snapshots plaintext before awaiting key wrapping', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final expectedPlaintext = sample(512);
    final mutablePlaintext = Uint8List.fromList(expectedPlaintext);
    final wrapStarted = Completer<void>();
    final allowWrap = Completer<void>();

    final sealing = cipher.seal(
      plaintext: mutablePlaintext,
      wrapDek: (dek) async {
        wrapStarted.complete();
        await allowWrap.future;
        return km.wrapDek(dek);
      },
    );
    await wrapStarted.future;
    mutablePlaintext.fillRange(0, mutablePlaintext.length, 0);
    allowWrap.complete();

    final container = await sealing;
    expect(
      await cipher.open(container: container, unwrapDek: km.unwrapDek),
      expectedPlaintext,
    );
  });

  test(
    'seal rejects non-canonical device and account wrapper lengths',
    () async {
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
    },
  );

  test(
    'seal destroys its transient DEK on success and callback failure',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      SecretKey? successfulDek;
      await cipher.seal(
        plaintext: sample(16),
        wrapDek: (dek) {
          successfulDek = dek;
          return km.wrapDek(dek);
        },
      );
      expect(successfulDek, isNotNull);
      expect(successfulDek!.isDestroyed, isTrue);

      SecretKey? failedDek;
      await expectLater(
        cipher.seal(
          plaintext: sample(16),
          wrapDek: (dek) async {
            failedDek = dek;
            throw StateError('synthetic wrapping failure');
          },
        ),
        throwsStateError,
      );
      expect(failedDek, isNotNull);
      expect(failedDek!.isDestroyed, isTrue);
    },
  );

  test('peekHeader rejects non-canonical encoded wrapper lengths', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final v1 = await cipher.seal(plaintext: sample(32), wrapDek: km.wrapDek);
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

  test('open rejects malformed headers before invoking key unwrap', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final malformed = await cipher.seal(
      plaintext: sample(32),
      wrapDek: km.wrapDek,
    );
    malformed[7] = SegmentCipher.wrappedDekLength - 1;

    var unwrapCalls = 0;
    await expectLater(
      cipher.open(
        container: malformed,
        unwrapDek: (_) async {
          unwrapCalls++;
          return SecretKey(List<int>.filled(SegmentCipher.dekLength, 0));
        },
      ),
      throwsFormatException,
    );
    expect(unwrapCalls, 0);
  });

  test(
    'peekHeader rejects every non-canonical version and flag byte',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final v1 = await cipher.seal(
        plaintext: Uint8List(0),
        wrapDek: km.wrapDek,
      );
      final v2 = await cipher.seal(
        plaintext: Uint8List(0),
        wrapDek: km.wrapDek,
        wrapForAccount: (_) async =>
            Uint8List(SegmentCipher.accountWrappedDekLength),
      );

      for (var flags = 0; flags <= 0xff; flags++) {
        if (flags != 0x01) {
          final mutated = Uint8List.fromList(v1)..[5] = flags;
          expect(
            () => SegmentCipher.peekHeader(mutated),
            throwsFormatException,
          );
        }
        if (flags != 0x03) {
          final mutated = Uint8List.fromList(v2)..[5] = flags;
          expect(
            () => SegmentCipher.peekHeader(mutated),
            throwsFormatException,
          );
        }
      }

      for (var version = 0; version <= 0xff; version++) {
        if (version == SegmentCipher.version ||
            version == SegmentCipher.versionMultiRecipient) {
          continue;
        }
        final mutated = Uint8List.fromList(v2)..[4] = version;
        expect(() => SegmentCipher.peekHeader(mutated), throwsFormatException);
      }
    },
  );

  test(
    'peekHeader rejects every truncated v2 prefix at the boundary',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final v2 = await cipher.seal(
        plaintext: Uint8List(0),
        wrapDek: km.wrapDek,
        wrapForAccount: (_) async =>
            Uint8List(SegmentCipher.accountWrappedDekLength),
      );
      final contentOffset =
          8 +
          SegmentCipher.wrappedDekLength +
          2 +
          SegmentCipher.accountWrappedDekLength;
      expect(
        v2,
        hasLength(contentOffset + SegmentCipher.minimumContentBoxLength),
      );
      expect(
        await cipher.open(container: v2, unwrapDek: km.unwrapDek),
        isEmpty,
      );

      for (var end = 0; end < v2.length; end++) {
        final truncated = Uint8List.sublistView(v2, 0, end);
        expect(
          () => SegmentCipher.peekHeader(truncated),
          throwsFormatException,
        );
      }
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
    'tampering fails authentication and destroys the recovered DEK',
    () async {
      final km = KeyManager(store: InMemoryKeyStore());
      final container = await cipher.seal(
        plaintext: sample(4096),
        wrapDek: km.wrapDek,
      );
      container[container.length - 1] ^= 0x01; // flip a bit in the tag/cipher

      SecretKey? recoveredDek;
      await expectLater(
        cipher.open(
          container: container,
          unwrapDek: (wrappedDek) async {
            recoveredDek = await km.unwrapDek(wrappedDek);
            return recoveredDek!;
          },
        ),
        throwsA(isA<Object>()),
      );
      expect(recoveredDek, isNotNull);
      expect(recoveredDek!.isDestroyed, isTrue);
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
