import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/account_recipient.dart';
import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/in_memory_key_store.dart';

void main() {
  final recipient = AccountRecipient();
  final cipher = SegmentCipher();
  final aead = AesGcm.with256bits();

  Uint8List sample(int n) =>
      Uint8List.fromList(List<int>.generate(n, (i) => (i * 13 + 7) & 0xFF));

  test('account seal/open round-trips a DEK', () async {
    final account = await recipient.generateKeyPair();
    final dek = sample(32);
    final blob = await recipient.seal(
      publicKey: account.publicKey,
      dekBytes: dek,
    );
    final recovered = await recipient.open(
      privateSeed: account.privateSeed,
      blob: blob,
    );
    expect(recovered, equals(dek));
  });

  test('a different account key cannot open the sealed DEK', () async {
    final account = await recipient.generateKeyPair();
    final other = await recipient.generateKeyPair();
    final blob = await recipient.seal(
      publicKey: account.publicKey,
      dekBytes: sample(32),
    );
    expect(
      () => recipient.open(privateSeed: other.privateSeed, blob: blob),
      throwsA(isA<Object>()),
    );
  });

  test(
    'v2 container: phone reads its own, desktop (account key) reads it too',
    () async {
      final phone = KeyManager(store: InMemoryKeyStore());
      final account = await recipient.generateKeyPair();
      final plaintext = sample(5000);

      // Phone seals: wrapped to its own device key AND to the account public key.
      final container = await cipher.seal(
        plaintext: plaintext,
        wrapDek: phone.wrapDek,
        wrapForAccount: (dek) async => recipient.seal(
          publicKey: account.publicKey,
          dekBytes: await dek.extractBytes(),
        ),
      );

      final header = SegmentCipher.peekHeader(container);
      expect(header.version, SegmentCipher.versionMultiRecipient);
      expect(header.accountWrappedDek, isNotNull);

      // 1) The phone opens it with its own device key.
      final viaPhone = await cipher.open(
        container: container,
        unwrapDek: phone.unwrapDek,
      );
      expect(viaPhone, equals(plaintext));

      // 2) The desktop "master" opens the SAME segment via the account private
      //    key: recover the DEK from the account block, decrypt the content box.
      final dekBytes = await recipient.open(
        privateSeed: account.privateSeed,
        blob: header.accountWrappedDek!,
      );
      final content = Uint8List.sublistView(container, header.contentOffset);
      final box = SecretBox.fromConcatenation(
        content,
        nonceLength: SegmentCipher.nonceLength,
        macLength: SegmentCipher.macLength,
      );
      final viaDesktop = await aead.decrypt(
        box,
        secretKey: SecretKey(dekBytes),
      );
      expect(viaDesktop, equals(plaintext));
    },
  );

  test(
    'a second phone (no account key) cannot read another device segment',
    () async {
      final phoneA = KeyManager(store: InMemoryKeyStore());
      final phoneB = KeyManager(store: InMemoryKeyStore());
      final account = await recipient.generateKeyPair();
      final container = await cipher.seal(
        plaintext: sample(1000),
        wrapDek: phoneA.wrapDek,
        wrapForAccount: (dek) async => recipient.seal(
          publicKey: account.publicKey,
          dekBytes: await dek.extractBytes(),
        ),
      );
      // Phone B has neither phone A's device key nor the account private key.
      expect(
        () => cipher.open(container: container, unwrapDek: phoneB.unwrapDek),
        throwsA(isA<Object>()),
      );
    },
  );

  test('v1 containers (no account key) still round-trip', () async {
    final phone = KeyManager(store: InMemoryKeyStore());
    final plaintext = sample(800);
    final container = await cipher.seal(
      plaintext: plaintext,
      wrapDek: phone.wrapDek,
    );
    expect(SegmentCipher.peekHeader(container).version, SegmentCipher.version);
    final out = await cipher.open(
      container: container,
      unwrapDek: phone.unwrapDek,
    );
    expect(out, equals(plaintext));
  });
}
