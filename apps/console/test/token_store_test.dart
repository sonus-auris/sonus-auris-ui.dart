import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonus_auris_console/src/models/supabase_session.dart';
import 'package:sonus_auris_console/src/services/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'browser store keeps sessions in memory and purges legacy secrets',
    () async {
      SharedPreferences.setMockInitialValues({
        'sonus.console.accessToken': 'legacy-access',
        'sonus.console.refreshToken': 'legacy-refresh',
        'sonus.console.expiresAt': '2099-01-01T00:00:00Z',
        'sonus.console.userId': 'legacy-user',
        'sonus.console.email': 'legacy@example.test',
      });
      final session = SupabaseSession(
        accessToken: 'header.payload.signature',
        refreshToken: 'refresh',
        expiresAtUtc: DateTime.utc(2099),
        userId: 'user-1',
        email: 'a@example.test',
      );
      final store = PrefsTokenStore();

      await store.writeSession(session);

      expect(await store.readSession(), same(session));
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'sonus.console.accessToken',
        'sonus.console.refreshToken',
        'sonus.console.expiresAt',
        'sonus.console.userId',
        'sonus.console.email',
      ]) {
        expect(prefs.containsKey(key), isFalse);
      }
      expect(await PrefsTokenStore().readSession(), isNull);
    },
  );

  test('browser store persists only the non-secret install id', () async {
    SharedPreferences.setMockInitialValues({});
    final first = PrefsTokenStore();
    final id = await first.deviceInstallId();

    expect(id, isNotEmpty);
    expect(await PrefsTokenStore().deviceInstallId(), id);
  });

  test('hostile browser storage never escapes as an internal error', () async {
    // Browser storage is writable by any injected script, so a stored value of
    // the wrong *type* makes `getString` throw before decoding is reached.
    SharedPreferences.setMockInitialValues({
      'sonus.console.pendingAuth.v1': <String>['not', 'a', 'string'],
      'sonus.console.deviceId': 42,
    });
    final store = PrefsTokenStore();

    expect(await store.readPendingMagicLink(), isNull);
    expect(await store.deviceInstallId(), isNotEmpty);

    // The unreadable pending record is dropped rather than kept forever.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get('sonus.console.pendingAuth.v1'), isNull);
  });
}
