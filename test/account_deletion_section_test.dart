import 'package:audio_dashcam/src/app/mfa_gate_controller.dart';
import 'package:audio_dashcam/src/models/account_status.dart';
import 'package:audio_dashcam/src/models/supabase_mfa.dart';
import 'package:audio_dashcam/src/widgets/account_deletion_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wrong email fails closed before starting an MFA challenge', (
    tester,
  ) async {
    final controller = _DeletionMfaController(_phoneFactor);
    var deleteCalls = 0;
    await _pumpSection(
      tester,
      controller: controller,
      onDelete: (_) async => deleteCalls += 1,
    );

    await tester.enterText(
      find.byKey(const ValueKey('account-deletion-email-field')),
      'another@example.com',
    );
    await tester.tap(
      find.byKey(const ValueKey('account-deletion-challenge-button')),
    );
    await tester.pump();

    expect(controller.challengeCalls, 0);
    expect(controller.verifyCalls, 0);
    expect(deleteCalls, 0);
    expect(
      find.text('Enter the exact signed-in email address to continue.'),
      findsNWidgets(2),
      reason: 'the error remains inline and in a floating notification',
    );
  });

  for (final factor in [_phoneFactor, _totpFactor]) {
    testWidgets(
      'exact email plus fresh ${factor.factorType} proof permits review',
      (tester) async {
        final controller = _DeletionMfaController(factor);
        var deleteCalls = 0;
        await _pumpSection(
          tester,
          controller: controller,
          onDelete: (confirmedEmail) async {
            expect(confirmedEmail, 'user@example.com');
            deleteCalls += 1;
          },
        );

        await tester.enterText(
          find.byKey(const ValueKey('account-deletion-email-field')),
          'USER@EXAMPLE.COM',
        );
        await tester.tap(
          find.byKey(const ValueKey('account-deletion-challenge-button')),
        );
        await tester.pump();
        expect(controller.challengeFactorId, factor.id);

        final codeField = find.byKey(
          const ValueKey('account-deletion-code-field'),
        );
        await tester.ensureVisible(codeField);
        await tester.enterText(codeField, '123456');
        final review = find.byKey(
          const ValueKey('account-deletion-review-button'),
        );
        await tester.ensureVisible(review);
        await tester.tap(review);
        await tester.pump();

        expect(controller.verifyCalls, 1);
        expect(controller.verifiedCode, '123456');
        expect(controller.completesSignIn, isFalse);
        expect(find.text('Permanently delete this account?'), findsOneWidget);
        expect(deleteCalls, 0);

        await tester.tap(
          find.byKey(const ValueKey('account-deletion-confirm-button')),
        );
        await tester.pump();
        expect(deleteCalls, 1);
      },
    );
  }

  testWidgets('no verified second factor keeps deletion disabled', (
    tester,
  ) async {
    final controller = _DeletionMfaController(null);
    await _pumpSection(tester, controller: controller, onDelete: (_) async {});

    final button = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('account-deletion-challenge-button')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('Add and verify a phone or authenticator'),
      findsOneWidget,
    );
  });
}

const _phoneFactor = MfaFactor(
  id: 'phone-1',
  factorType: 'phone',
  status: 'verified',
  friendlyName: 'Personal phone',
  phone: '+15551234567',
);

const _totpFactor = MfaFactor(
  id: 'totp-1',
  factorType: 'totp',
  status: 'verified',
  friendlyName: 'Authy',
);

Future<void> _pumpSection(
  WidgetTester tester, {
  required _DeletionMfaController controller,
  required Future<void> Function(String confirmedEmail) onDelete,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AccountDeletionSection(
            controller: controller,
            signedInEmail: 'user@example.com',
            onDeleteAccount: onDelete,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _DeletionMfaController implements MfaGateController {
  _DeletionMfaController(this.factor);

  final MfaFactor? factor;
  int challengeCalls = 0;
  int verifyCalls = 0;
  String? challengeFactorId;
  String? verifiedCode;
  bool? completesSignIn;

  @override
  Stream<AccountStatus> get accountStatus => Stream.value(accountStatusValue);

  @override
  AccountStatus get accountStatusValue =>
      AccountStatus(mfaFactors: factor == null ? const [] : [factor!]);

  @override
  String? get latestMessage => null;

  @override
  Future<List<MfaFactor>> refreshMfaFactors() async =>
      factor == null ? const [] : [factor!];

  @override
  Future<String?> challengeMfaFactor(String factorId) async {
    challengeCalls += 1;
    challengeFactorId = factorId;
    return 'challenge-1';
  }

  @override
  Future<bool> verifyMfaFactor({
    required String factorId,
    required String challengeId,
    required String code,
    bool completesSignIn = false,
  }) async {
    verifyCalls += 1;
    verifiedCode = code;
    this.completesSignIn = completesSignIn;
    return factorId == factor?.id && challengeId == 'challenge-1';
  }

  @override
  Future<TotpEnrollment?> enrollTotpFactor({String? friendlyName}) async =>
      null;

  @override
  Future<PhoneEnrollment?> enrollPhoneFactor({
    required String phone,
    String? friendlyName,
  }) async => null;
}
