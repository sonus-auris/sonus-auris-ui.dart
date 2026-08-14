import 'package:audio_dashcam/src/app/mfa_gate_controller.dart';
import 'package:audio_dashcam/src/models/account_status.dart';
import 'package:audio_dashcam/src/models/supabase_mfa.dart';
import 'package:audio_dashcam/src/widgets/supabase_mfa_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'landscape enrollment failures stay inline and stack as visible toasts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = _FailingMfaController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SupabaseMfaGate(controller: controller),
              ),
            ),
          ),
        ),
      );

      final enroll = find.byKey(const ValueKey('mandatory-mfa-totp-button'));
      await tester.tap(enroll);
      await tester.pumpAndSettle();
      await tester.tap(enroll);
      await tester.pumpAndSettle();

      expect(controller.friendlyNames, hasLength(2));
      expect(
        controller.friendlyNames.toSet(),
        hasLength(2),
        reason: 'a retry must never collide with the first pending factor',
      );
      expect(
        find.text(_FailingMfaController.serverError),
        findsNWidgets(3),
        reason: 'one inline error and two simultaneously visible toasts',
      );
      expect(
        find.byKey(const ValueKey('mandatory-mfa-error-toast-stack')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _FailingMfaController implements MfaGateController {
  static const serverError =
      'mfa_factor_name_conflict: A factor with that name already exists.';

  final friendlyNames = <String>[];
  final _status = const AccountStatus(mfaEnrollmentRequired: true);

  @override
  Stream<AccountStatus> get accountStatus => Stream.value(_status);

  @override
  AccountStatus get accountStatusValue => _status;

  @override
  String? get latestMessage => serverError;

  @override
  Future<TotpEnrollment?> enrollTotpFactor({String? friendlyName}) async {
    friendlyNames.add(friendlyName ?? '');
    return null;
  }

  @override
  Future<PhoneEnrollment?> enrollPhoneFactor({
    required String phone,
    String? friendlyName,
  }) async => null;

  @override
  Future<String?> challengeMfaFactor(String factorId) async => null;

  @override
  Future<List<MfaFactor>> refreshMfaFactors() async => const [];

  @override
  Future<bool> verifyMfaFactor({
    required String factorId,
    required String challengeId,
    required String code,
    bool completesSignIn = false,
  }) async => false;
}
