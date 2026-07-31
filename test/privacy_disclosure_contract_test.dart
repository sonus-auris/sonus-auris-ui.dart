import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('external recognition is disclosed before cloud STT can be enabled', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('Send speech clips for transcription?'));
    expect(source, contains('The provider receives audio needed for '));
    expect(source, contains("'that request; this is separate from encrypted"));
    expect(source, contains('Enable transcription'));
  });

  test('store privacy guidance covers recognition-provider audio', () {
    for (final path in [
      'docs/compliance/PRIVACY_POLICY.md',
      'docs/compliance/DATA_SAFETY_play.md',
      'docs/compliance/PRIVACY_LABELS_appstore.md',
    ]) {
      final policy = File(path).readAsStringSync().toLowerCase();
      expect(
        policy,
        contains('recognition provider'),
        reason: '$path must disclose external recognition audio processing',
      );
    }
  });
}
