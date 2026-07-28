import 'dart:convert';
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

  test('account seal/open round-trips an exact 92-byte DEK wrapper', () async {
    final account = await recipient.generateKeyPair();
    final dek = sample(32);
    final blob = await recipient.seal(
      publicKey: account.publicKey,
      dekBytes: dek,
    );
    expect(blob.length, AccountRecipient.sealedDekLength);
    final recovered = await recipient.open(
      privateSeed: account.privateSeed,
      blob: blob,
    );
    expect(recovered, equals(dek));
  });

  test('account wrapper rejects non-canonical key and blob lengths', () async {
    final account = await recipient.generateKeyPair();

    expect(
      () => recipient.seal(
        publicKey: Uint8List(31),
        dekBytes: sample(SegmentCipher.dekLength),
      ),
      throwsArgumentError,
    );
    expect(
      () => recipient.seal(
        publicKey: account.publicKey,
        dekBytes: sample(SegmentCipher.dekLength - 1),
      ),
      throwsArgumentError,
    );

    for (final length in [91, 93]) {
      expect(
        () => recipient.open(
          privateSeed: account.privateSeed,
          blob: Uint8List(length),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => recipient.open(
        privateSeed: Uint8List(31),
        blob: Uint8List(AccountRecipient.sealedDekLength),
      ),
      throwsFormatException,
    );
  });

  test('non-contributory all-zero X25519 input is rejected before HKDF', () async {
    final account = await recipient.generateKeyPair();
    final zeroShared = SecretKey(List<int>.filled(32, 0));
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: SegmentCipher.dekLength,
    );
    final zeroDerivedKey = await hkdf.deriveKey(
      secretKey: zeroShared,
      nonce: const [],
      info: utf8.encode('sonus-auris/account-recipient/v1'),
    );
    final box = await aead.encrypt(
      sample(SegmentCipher.dekLength),
      secretKey: zeroDerivedKey,
      nonce: List<int>.filled(SegmentCipher.nonceLength, 0),
    );
    final maliciousBlob = BytesBuilder(copy: false)
      ..add(List<int>.filled(AccountRecipient.publicKeyLength, 0))
      ..add(box.concatenation());

    expect(
      () => recipient.open(
        privateSeed: account.privateSeed,
        blob: maliciousBlob.toBytes(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('non-contributory'),
        ),
      ),
    );
    zeroDerivedKey.destroy();
    zeroShared.destroy();
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
    'v2 container: phone reads its own, authorized peer reads it too',
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
      expect(
        header.accountWrappedDek,
        hasLength(SegmentCipher.accountWrappedDekLength),
      );

      // 1) The phone opens it with its own device key.
      final viaPhone = await cipher.open(
        container: container,
        unwrapDek: phone.unwrapDek,
      );
      expect(viaPhone, equals(plaintext));

      // 2) An authorized peer opens the SAME segment via the account private
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
      final viaPeerKey = SecretKey(dekBytes);
      try {
        final viaPeer = await aead.decrypt(box, secretKey: viaPeerKey);
        expect(viaPeer, equals(plaintext));
      } finally {
        viaPeerKey.destroy();
      }
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
