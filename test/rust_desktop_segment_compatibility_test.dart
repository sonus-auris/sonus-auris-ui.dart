import 'dart:typed_data';

import 'package:audio_dashcam/src/services/crypto/segment_cipher.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixed AES-256-GCM SAC1 vector shared with desktop.app.rs/cloud_backup.rs:
// MK=0x07*32, DEK=0x09*32, wrap nonce=0x01*12, content nonce=0x02*12.
const _rustContainerHex =
    '534143310101003c'
    '010101010101010101010101'
    '7fe880be99b6e507d8ddd528793e7938a1f21dfd119e321a51384a6b6fbd3'
    'fb2a9e6ba821fe6ce6d8715a77388d04b65'
    '020202020202020202020202'
    '886195007336ff69898f6e44a2fe0818e85c0fbaabaafd4f9d2980d2cb33d0';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);

void main() {
  test('Flutter opens the fixed Rust desktop SAC1 segment', () async {
    final cipher = SegmentCipher();
    final aead = AesGcm.with256bits();
    final clear = await cipher.open(
      container: _hex(_rustContainerHex),
      unwrapDek: (wrappedDek) async {
        final box = SecretBox.fromConcatenation(
          wrappedDek,
          nonceLength: SegmentCipher.nonceLength,
          macLength: SegmentCipher.macLength,
        );
        final dek = await aead.decrypt(
          box,
          secretKey: SecretKey(List<int>.filled(32, 7)),
        );
        return SecretKey(dek);
      },
    );
    expect(String.fromCharCodes(clear), 'rust-to-flutter');
  });
}
