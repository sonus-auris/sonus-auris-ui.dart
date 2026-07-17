import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/in_memory_key_store.dart';

void main() {
  test('generates a master key once and reuses it', () async {
    final store = InMemoryKeyStore();
    final km = KeyManager(store: store);

    expect(await km.hasMasterKey(), isFalse);
    final mk1 = await km.getOrCreateMasterKey();
    expect(await km.hasMasterKey(), isTrue);
    expect(store.snapshot.containsKey(KeyManager.masterKeyStorageId), isTrue);

    // A fresh manager over the same store recovers the identical key.
    final km2 = KeyManager(store: store);
    final mk2 = await km2.getOrCreateMasterKey();
    expect(await mk1.extractBytes(), equals(await mk2.extractBytes()));
  });

  test(
    'passphrase recovery restores the same master key on a new device',
    () async {
      final originalStore = InMemoryKeyStore();
      final original = KeyManager(store: originalStore);
      await original.getOrCreateMasterKey();
      final recovery = await original.exportPassphraseRecovery(
        'correct horse staple',
      );

      // New device: empty store, import from the blob + passphrase.
      final fresh = KeyManager(store: InMemoryKeyStore());
      await fresh.restoreFromPassphraseRecovery(
        'correct horse staple',
        recovery,
      );

      final a = await original.getOrCreateMasterKey();
      final b = await fresh.getOrCreateMasterKey();
      expect(await a.extractBytes(), equals(await b.extractBytes()));
    },
  );

  test('wrong passphrase fails to recover', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    await km.getOrCreateMasterKey();
    final recovery = await km.exportPassphraseRecovery('the-right-passphrase');

    final fresh = KeyManager(store: InMemoryKeyStore());
    expect(
      () =>
          fresh.restoreFromPassphraseRecovery('the-wrong-passphrase', recovery),
      throwsA(isA<Object>()),
    );
  });

  test('rejects weak passphrases at enrolment', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    await km.getOrCreateMasterKey();
    expect(() => km.exportPassphraseRecovery('short'), throwsArgumentError);
  });

  test(
    'account-escrow recovery restores the master key with its secret',
    () async {
      final original = KeyManager(store: InMemoryKeyStore());
      await original.getOrCreateMasterKey();
      final material = await original.exportAccountRecovery();

      final fresh = KeyManager(store: InMemoryKeyStore());
      await fresh.restoreFromAccountRecovery(
        material.recoverySecretBase64,
        material.blob,
      );

      final a = await original.getOrCreateMasterKey();
      final b = await fresh.getOrCreateMasterKey();
      expect(await a.extractBytes(), equals(await b.extractBytes()));
    },
  );

  test(
    'account-escrow blob is useless without the secret (zero-knowledge)',
    () async {
      final original = KeyManager(store: InMemoryKeyStore());
      await original.getOrCreateMasterKey();
      final material = await original.exportAccountRecovery();

      final attacker = KeyManager(store: InMemoryKeyStore());
      final wrongSecret = base64Wrong(material.recoverySecretBase64);
      expect(
        () => attacker.restoreFromAccountRecovery(wrongSecret, material.blob),
        throwsA(isA<Object>()),
      );
    },
  );

  test('wrapped DEK is the expected envelope size', () async {
    final km = KeyManager(store: InMemoryKeyStore());
    final cipher = SegmentCipher();
    final container = await cipher.seal(
      plaintext: Uint8List.fromList(List<int>.filled(10, 7)),
      wrapDek: km.wrapDek,
    );
    final header = SegmentCipher.peekHeader(container);
    // nonce(12) + dek(32) + mac(16)
    expect(header.wrappedDek.length, 60);
  });
}

/// Produce a definitely-wrong secret of equal length by re-encoding flipped bytes.
String base64Wrong(String b64) {
  final bytes = base64Decode(b64);
  bytes[0] ^= 0xFF;
  return base64Encode(bytes);
}
