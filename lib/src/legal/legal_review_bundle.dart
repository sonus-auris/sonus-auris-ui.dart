import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Offline external-only review documents. Loading never records acceptance.
class LegalReviewDocument {
  const LegalReviewDocument({required this.id, required this.asset, required this.text});

  final String id;
  final String asset;
  final String text;
}

class LegalReviewBundle {
  LegalReviewBundle._(this.sourceCommit, List<LegalReviewDocument> documents)
      : documents = List.unmodifiable(documents);

  final String sourceCommit;
  final List<LegalReviewDocument> documents;

  static const _expected = <String, String>{
    'mobile-eula.md': 'SONUS-EXT-MOBILE-EULA',
    'apple-platform-addendum.md': 'SONUS-EXT-APPLE',
    'mobile-subscription-agreement.md': 'SONUS-EXT-SUBSCRIPTION',
  };

  static Future<LegalReviewBundle> load({AssetBundle? assets}) async {
    final bundle = assets ?? rootBundle;
    final raw = jsonDecode(await bundle.loadString('assets/legal/manifest.json'));
    if (raw is! Map<String, dynamic> || raw['schemaVersion'] != 1 ||
        raw['sourceRepository'] != 'sonus-auris/sonus-auris-docs' ||
        raw['profile'] != 'review-only' || raw['approvedForRelease'] != false ||
        raw['sourceCommit'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(raw['sourceCommit'] as String)) {
      throw const FormatException('Invalid legal review manifest');
    }
    final entries = raw['documents'];
    if (entries is! List || entries.length != _expected.length) {
      throw const FormatException('Invalid legal document count');
    }
    final seen = <String>{};
    final documents = <LegalReviewDocument>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> || entry['asset'] is! String ||
          _expected[entry['asset']] != entry['id'] ||
          entry['path'] != 'docs/legal/external/additional/${entry['asset']}' ||
          !seen.add(entry['asset'] as String)) {
        throw const FormatException('Unlisted or duplicate legal document');
      }
      final asset = entry['asset'] as String;
      final data = await bundle.load('assets/legal/$asset');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final digest = sha1.convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes]).toString();
      if (entry['bytes'] != bytes.length || entry['gitBlobSha'] != digest) {
        throw const FormatException('Legal document integrity failure');
      }
      final text = utf8.decode(bytes);
      if (!text.contains('\nstatus: draft\n') ||
          !text.contains('DRAFT TEMPLATE — NOT AN EXECUTED AGREEMENT — NOT LEGAL ADVICE')) {
        throw const FormatException('Legal document warning missing');
      }
      documents.add(LegalReviewDocument(id: entry['id'] as String, asset: asset, text: text));
    }
    return LegalReviewBundle._(raw['sourceCommit'] as String, documents);
  }
}
