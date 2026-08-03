import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop feature manifest is complete and tracks exceptions', () {
    final manifest = jsonDecode(
      File('parity/desktop-features.json').readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['manifestVersion'], '1.0.0');
    expect(manifest['implementation'], 'flutter');

    final features = (manifest['features'] as List).cast<Map>();
    expect(features.length, greaterThanOrEqualTo(20));

    final ids = <String>{};
    const allowedStatuses = {
      'supported',
      'platform-specific',
      'intentionally-deferred',
      'not-applicable',
    };
    for (final feature in features) {
      final id = feature['id'] as String;
      expect(ids.add(id), isTrue, reason: 'duplicate feature id: $id');
      final status = feature['status'] as String;
      expect(allowedStatuses, contains(status), reason: id);
      expect((feature['platforms'] as List), isNotEmpty, reason: id);
      if (status == 'intentionally-deferred') {
        expect(feature['linearIssue'], isNotNull, reason: id);
        expect(feature['reviewCondition'], isNotNull, reason: id);
      }
      if (status == 'platform-specific') {
        expect(feature['note'], isNotNull, reason: id);
      }
    }

    expect(ids, contains('pagelets.native-schema-v1'));
    expect(ids, contains('pagelets.offline-fallback'));
    expect(ids, contains('lifecycle.explicit-quit'));
    expect(ids, contains('retention.plaintext-100h-ceiling'));
  });
}
