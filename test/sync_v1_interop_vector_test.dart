import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/account_recipient.dart';
import 'package:audio_dashcam/src/services/crypto/key_manager.dart';
import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/in_memory_key_store.dart';

void main() {
  late Map<String, dynamic> vector;

  setUpAll(() async {
    vector = jsonDecode(
      await File('test/fixtures/sonus_auris_sync_v1.json').readAsString(),
    ) as Map<String, dynamic>;
  });

  test('Dart derives the normative X25519 account public key', () async {
    final inputs = _section(vector, 'inputs');
    final keyPair = await X25519().newKeyPairFromSeed(
      _hex(inputs['account_x25519_private_seed'] as String),
    );
    final publicKey = await keyPair.extractPublicKey();

    expect(
      _toHex(publicKey.bytes),
      inputs['account_x25519_public_key'],
    );
  });

  test('Dart opens the normative account-recipient wrapped DEK', () async {
    final inputs = _section(vector, 'inputs');
    final accountRecipient = _section(vector, 'account_recipient_v1');

    final recovered = await AccountRecipient().open(
      privateSeed: _hex(inputs['account_x25519_private_seed'] as String),
      blob: _hex(accountRecipient['sealed_dek'] as String),
    );

    expect(_toHex(recovered), inputs['data_encryption_key']);
  });

  test('Dart parses and opens the complete normative SAC1 v2 container', () async {
    final inputs = _section(vector, 'inputs');
    final deviceWrap = _section(vector, 'device_wrap_v1');
    final accountRecipient = _section(vector, 'account_recipient_v1');
    final containerVector = _section(vector, 'sac1_container_v2');
    final container = _hex(containerVector['container'] as String);

    expect(container.length, containerVector['container_size']);
    final header = SegmentCipher.peekHeader(container);
    expect(header.version, SegmentCipher.versionMultiRecipient);
    expect(header.flags, containerVector['flags']);
    expect(_toHex(header.wrappedDek), deviceWrap['wrapped_dek']);
    expect(
      _toHex(header.accountWrappedDek!),
      accountRecipient['sealed_dek'],
    );

    final store = InMemoryKeyStore({
      KeyManager.masterKeyStorageId: base64Encode(
        _hex(inputs['device_master_key'] as String),
      ),
    });
    final openedOnOriginDevice = await SegmentCipher().open(
      container: container,
      unwrapDek: KeyManager(store: store).unwrapDek,
    );
    expect(
      utf8.decode(openedOnOriginDevice),
      inputs['plaintext_utf8'],
    );

    final dek = await AccountRecipient().open(
      privateSeed: _hex(inputs['account_x25519_private_seed'] as String),
      blob: header.accountWrappedDek!,
    );
    final contentBox = SecretBox.fromConcatenation(
      Uint8List.sublistView(container, header.contentOffset),
      nonceLength: SegmentCipher.nonceLength,
      macLength: SegmentCipher.macLength,
    );
    final openedOnAuthorizedPeer = await AesGcm.with256bits().decrypt(
      contentBox,
      secretKey: SecretKey(dek),
    );
    expect(utf8.decode(openedOnAuthorizedPeer), inputs['plaintext_utf8']);
  });

  test('Dart reproduces the object, recipient-set, and manifest hashes', () async {
    final containerVector = _section(vector, 'sac1_container_v2');
    final recipientSet = _section(vector, 'recipient_set');
    final manifest = _section(vector, 'signed_manifest_v1');
    final sha256 = Sha256();

    expect(
      _toHex((await sha256.hash(_hex(containerVector['container'] as String))).bytes),
      containerVector['container_sha256'],
    );
    expect(
      _toHex(
        (await sha256.hash(
          utf8.encode(recipientSet['canonical_json'] as String),
        )).bytes,
      ),
      recipientSet['sha256'],
    );
    expect(
      _toHex(
        (await sha256.hash(
          utf8.encode(manifest['canonical_json'] as String),
        )).bytes,
      ),
      manifest['sha256'],
    );
  });

  test('Dart verifies the normative Ed25519 manifest signature', () async {
    final manifest = _section(vector, 'signed_manifest_v1');
    final message = utf8.encode(manifest['canonical_json'] as String);
    final signature = Signature(
      _hex(manifest['signature'] as String),
      publicKey: SimplePublicKey(
        _hex(manifest['ed25519_public_key'] as String),
        type: KeyPairType.ed25519,
      ),
    );

    expect(
      await Ed25519().verify(message, signature: signature),
      isTrue,
    );

    final tampered = Uint8List.fromList(message)..[10] ^= 0x01;
    expect(
      await Ed25519().verify(tampered, signature: signature),
      isFalse,
    );
  });

  test('Dart fails closed for account-wrap and content tampering', () async {
    final inputs = _section(vector, 'inputs');
    final accountRecipient = _section(vector, 'account_recipient_v1');
    final containerVector = _section(vector, 'sac1_container_v2');

    final tamperedWrap = _hex(accountRecipient['sealed_dek'] as String)
      ..[50] ^= 0x01;
    await expectLater(
      AccountRecipient().open(
        privateSeed: _hex(inputs['account_x25519_private_seed'] as String),
        blob: tamperedWrap,
      ),
      throwsA(isA<Object>()),
    );

    final tamperedContainer = _hex(containerVector['container'] as String)
      ..[220] ^= 0x01;
    final store = InMemoryKeyStore({
      KeyManager.masterKeyStorageId: base64Encode(
        _hex(inputs['device_master_key'] as String),
      ),
    });
    await expectLater(
      SegmentCipher().open(
        container: tamperedContainer,
        unwrapDek: KeyManager(store: store).unwrapDek,
      ),
      throwsA(isA<Object>()),
    );

    final unsupported = _hex(containerVector['container'] as String)..[4] = 3;
    expect(
      () => SegmentCipher.peekHeader(unsupported),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _section(Map<String, dynamic> root, String key) =>
    root[key] as Map<String, dynamic>;

Uint8List _hex(String value) {
  if (value.length.isOdd) {
    throw FormatException('Hex input has an odd length: ${value.length}');
  }
  final output = Uint8List(value.length ~/ 2);
  for (var i = 0; i < output.length; i++) {
    output[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return output;
}

String _toHex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
