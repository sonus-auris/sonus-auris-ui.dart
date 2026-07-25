// Guards the web shell and PWA manifest against regressing to the Flutter
// scaffold defaults.
//
// These values are user-visible: `<title>` shows in the browser tab, and
// `manifest.json` is read verbatim by PWA/TWA install and store-wrapping flows,
// so "A new Flutter project." reaching a store listing is a real defect. The
// same expectations are asserted end-to-end against a deployed build by
// sonus-auris-e2e (`tests/console/{meta,pwa}.test.mjs`); this test catches a
// regression here at source, before a build is ever produced.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter's `create` scaffold values. None may survive into a shipped build.
const templateDefaults = <String>[
  'A new Flutter project.',
  'sonus_auris_console', // the raw pubspec id, not a human/branded name
];

void main() {
  group('web/index.html', () {
    late String html;

    setUpAll(() => html = File('web/index.html').readAsStringSync());

    test('has a branded, non-template <title>', () {
      final title = RegExp(r'<title>(.*?)</title>').firstMatch(html)?.group(1);
      expect(title, isNotNull, reason: 'no <title> in the web shell');
      expect(title!.trim(), isNotEmpty);
      for (final scaffold in templateDefaults) {
        expect(title, isNot(contains(scaffold)),
            reason: '<title> still carries the Flutter template value');
      }
    });

    test('declares a viewport meta so non-desktop widths render', () {
      expect(html, contains('name="viewport"'));
      expect(html, contains('width=device-width'));
    });

    test('has a real meta description', () {
      final match =
          RegExp(r'<meta name="description" content="([^"]*)"').firstMatch(html);
      expect(match, isNotNull, reason: 'no meta description');
      final description = match!.group(1)!;
      expect(description.trim(), isNotEmpty);
      expect(description, isNot(contains('A new Flutter project.')));
    });
  });

  group('web/manifest.json', () {
    late Map<String, Object?> manifest;

    setUpAll(() {
      manifest = jsonDecode(File('web/manifest.json').readAsStringSync())
          as Map<String, Object?>;
    });

    test('name and short_name are human/branded, not the raw project id', () {
      for (final key in ['name', 'short_name']) {
        final value = manifest[key] as String?;
        expect(value, isNotNull, reason: 'manifest.$key missing');
        expect(value!.trim(), isNotEmpty);
        expect(value, isNot(equals('sonus_auris_console')),
            reason: 'manifest.$key is still the raw pubspec id');
      }
    });

    test('description is real product copy', () {
      final description = manifest['description'] as String?;
      expect(description, isNotNull, reason: 'manifest.description missing');
      expect(description, isNot(equals('A new Flutter project.')));
      expect(description!.trim(), isNotEmpty);
    });

    test('theme and background colors are set and not the Flutter default', () {
      for (final key in ['theme_color', 'background_color']) {
        final value = manifest[key] as String?;
        expect(value, isNotNull, reason: 'manifest.$key missing');
        // #0175C2 is the scaffold blue; the app ships the brand palette.
        expect(value!.toUpperCase(), isNot(equals('#0175C2')),
            reason: 'manifest.$key is still the Flutter template blue');
      }
    });

    test('declares icons', () {
      final icons = manifest['icons'];
      expect(icons, isA<List<Object?>>());
      expect((icons! as List<Object?>), isNotEmpty);
    });
  });
}
