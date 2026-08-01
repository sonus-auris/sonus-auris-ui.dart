// The browser surface must apply the same mandatory-MFA rule as the mobile and
// desktop clients.
//
// `SupabaseMfaGate` holds account data closed on mobile (`lib/main.dart`) and
// desktop (`lib/main_desktop.dart`) until the Supabase JWT reaches AAL2. The
// web shell has no `AppController` and therefore no `SupabaseMfaGate`, so its
// equivalent gate lives inline in `lib/main_web.dart`. These tests pin that it
// exists, because losing it is silent: an AAL1 session simply starts rendering
// the account surface and opening Realtime channels again.
//
// `SonusWebApp` builds its own `SupabaseAuthClient` with no injection seam, so
// an AAL1 session cannot be driven through the real widget in a test. What is
// asserted here is the structural gate plus the predicate it relies on.
import 'dart:convert';
import 'dart:io';

import 'package:audio_dashcam/src/models/supabase_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final webSource = File('lib/main_web.dart').readAsStringSync();

  test('the web shell treats only an AAL2 session as authorized', () {
    // "Signed in" on the web surface must be the AAL2 predicate, never the
    // mere presence of a session object.
    expect(
      webSource,
      contains('bool get _isAuthorized => _session?.isPasswordlessAal2'),
      reason: 'the web authorization predicate is missing or renamed',
    );
    expect(
      webSource,
      contains('final signedIn = _isAuthorized;'),
      reason: 'the account surface must render off the AAL2 predicate',
    );
    expect(
      webSource,
      isNot(contains('final signedIn = _session != null;')),
      reason: 'holding any session is not the same as clearing mandatory MFA',
    );
  });

  test('a first-factor-only web session opens no account channels', () {
    // _adoptSession must return before Realtime/device wiring when the token
    // has not reached AAL2. Neither Realtime client carries an AAL check of
    // its own, so this early return is the only thing stopping an AAL1 token
    // from being used to subscribe.
    final adopt = RegExp(
      r'Future<void> _adoptSession\([\s\S]*?\n  \}',
    ).firstMatch(webSource)?.group(0);
    expect(adopt, isNotNull, reason: '_adoptSession was renamed or removed');

    final gateIndex = adopt!.indexOf('if (!session.isPasswordlessAal2)');
    expect(
      gateIndex,
      isNonNegative,
      reason: '_adoptSession no longer gates on AAL2',
    );
    expect(
      adopt.indexOf('_realtime.connect('),
      greaterThan(gateIndex),
      reason: 'Realtime is connected before the AAL2 gate',
    );
    expect(
      adopt.indexOf('_connectDevices()'),
      greaterThan(gateIndex),
      reason: 'the device registry is contacted before the AAL2 gate',
    );
    expect(
      adopt.substring(gateIndex),
      contains('_secondFactorRequiredStatus'),
      reason: 'the AAL1 branch must explain why the account stays closed',
    );
  });

  test('an AAL1 session is left a way out', () {
    // A user stuck at the gate must still be able to sign out, so the action
    // is bound to holding a session rather than to being authorized.
    expect(webSource, contains('if (hasSession)'));
    expect(webSource, contains("label: const Text('Sign out')"));
  });

  test(
    'the AAL2 predicate rejects first-factor and password-backed tokens',
    () {
      String token(Map<String, Object?> claims) {
        final payload = _base64UrlNoPad(claims);
        return 'eyJhbGciOiJub25lIn0.$payload.signature';
      }

      const otpFirstFactor = [
        {'method': 'otp'},
      ];
      const otpThenTotp = [
        {'method': 'otp'},
        {'method': 'totp'},
      ];
      const passwordThenTotp = [
        {'method': 'password'},
        {'method': 'totp'},
      ];

      expect(
        supabaseJwtIsPasswordlessAal2(
          token({'aal': 'aal2', 'amr': otpThenTotp}),
        ),
        isTrue,
        reason: 'a passwordless AAL2 token is the one that opens the account',
      );
      expect(
        supabaseJwtIsPasswordlessAal2(
          token({'aal': 'aal1', 'amr': otpFirstFactor}),
        ),
        isFalse,
        reason: 'an email code alone must not authorize the web surface',
      );
      expect(
        supabaseJwtIsPasswordlessAal2(
          token({'aal': 'aal2', 'amr': passwordThenTotp}),
        ),
        isFalse,
        reason: 'a password-backed session is not a passwordless session',
      );
      expect(supabaseJwtIsPasswordlessAal2(''), isFalse);
      expect(supabaseJwtIsPasswordlessAal2('not-a-jwt'), isFalse);
    },
  );
}

String _base64UrlNoPad(Map<String, Object?> claims) {
  final json = _jsonEncode(claims);
  return _base64Url(json);
}

String _jsonEncode(Object? value) => const JsonCodec().encode(value);

String _base64Url(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');
