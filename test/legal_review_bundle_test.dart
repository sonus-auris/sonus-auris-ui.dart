import 'dart:convert';

import 'package:audio_dashcam/src/legal/legal_review_bundle.dart';
import 'package:audio_dashcam/src/legal/legal_review_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _OverrideBundle extends CachingAssetBundle {
  _OverrideBundle(this.values);
  final Map<String, Uint8List> values;

  @override
  Future<ByteData> load(String key) async {
    final value = values[key];
    if (value != null) return ByteData.sublistView(value);
    return rootBundle.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('actual Flutter bundle contains the pinned external drafts', () async {
    final bundle = await LegalReviewBundle.load();
    expect(bundle.documents.length, 3);
    expect(bundle.sourceCommit, '8e21168887f32b627328adcbb7f9978d178011e5');
    expect(
      bundle.documents.every((document) => document.text.contains('Initials:')),
      isTrue,
    );
  });

  test('changed bytes fail closed', () async {
    final assets = _OverrideBundle({
      'assets/legal/mobile-eula.md': Uint8List.fromList(utf8.encode('changed')),
    });
    await expectLater(
      LegalReviewBundle.load(assets: assets),
      throwsFormatException,
    );
  });

  test('a flipped approval flag cannot turn drafts into live terms', () async {
    final manifest = jsonDecode(
      await rootBundle.loadString('assets/legal/manifest.json'),
    ) as Map<String, dynamic>;
    manifest['approvedForRelease'] = true;
    final assets = _OverrideBundle({
      'assets/legal/manifest.json': Uint8List.fromList(
        utf8.encode(jsonEncode(manifest)),
      ),
    });
    await expectLater(
      LegalReviewBundle.load(assets: assets),
      throwsFormatException,
    );
  });

  testWidgets('review page labels drafts and never offers acceptance', (tester) async {
    // Asset loading uses real I/O. Resolve it outside the fake-async frame loop,
    // then test rendering deterministically rather than spinning a progress UI.
    final bundle = await tester.runAsync(() => LegalReviewBundle.load());
    expect(bundle, isNotNull);
    await tester.pumpWidget(
      MaterialApp(
        home: LegalReviewPage(loadBundle: () => Future.value(bundle!)),
      ),
    );
    await tester.pump();
    expect(find.text('DRAFTS ONLY — NOT APPROVED OR ACCEPTED'), findsOneWidget);
    expect(find.text('SONUS-EXT-MOBILE-EULA'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
  });

  testWidgets('review page reports unavailable terms without acceptance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LegalReviewPage(
          loadBundle: () => Future<LegalReviewBundle>.error(
            const FormatException('fixture integrity failure'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('Legal documents unavailable. No terms accepted.'),
      findsOneWidget,
    );
    expect(find.text('Accept'), findsNothing);
  });
}
