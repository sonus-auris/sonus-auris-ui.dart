import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonus_auris_console/src/services/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('pending magic-link state round-trips with strict expiry', () {
    final pending = PendingMagicLink(
      codeVerifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      email: 'a@example.test',
      supabaseUrl: 'https://project.supabase.co',
      redirectUrl: 'https://console.example/auth/callback',
      requestedAtUtc: DateTime.utc(2026, 7, 29, 12),
    );

    final restored = PendingMagicLink.decode(pending.encode());

    expect(restored.codeVerifier, pending.codeVerifier);
    expect(restored.email, pending.email);
    expect(
      restored.isExpired(now: DateTime.utc(2026, 7, 29, 12, 14, 59)),
      isFalse,
    );
    expect(restored.isExpired(now: DateTime.utc(2026, 7, 29, 12, 15)), isTrue);
    expect(restored.isExpired(now: DateTime.utc(2026, 7, 29, 11, 58)), isTrue);
  });

  test('corrupt browser pending state is removed on read', () async {
    SharedPreferences.setMockInitialValues({
      'sonus.console.pendingAuth.v1': '{"code_verifier":3}',
    });
    final store = PrefsTokenStore();

    expect(await store.readPendingMagicLink(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sonus.console.pendingAuth.v1'), isFalse);
  });

  test(
    'native pending state uses secure storage and clears corruption',
    () async {
      const key = 'sonus.console.pendingAuth.v1';
      FlutterSecureStorage.setMockInitialValues({key: 'not-json'});
      const secureStorage = FlutterSecureStorage();
      final store = SecureTokenStore(storage: secureStorage);

      expect(await store.readPendingMagicLink(), isNull);
      expect(await secureStorage.read(key: key), isNull);
    },
  );
}
