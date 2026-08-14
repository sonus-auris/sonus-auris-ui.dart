import '../models/account_status.dart';
import '../models/supabase_mfa.dart';

/// Narrow MFA contract used by the gate so its error and orientation behavior
/// can be exercised without booting every plugin-backed application service.
abstract interface class MfaGateController {
  Stream<AccountStatus> get accountStatus;

  AccountStatus get accountStatusValue;

  String? get latestMessage;

  Future<List<MfaFactor>> refreshMfaFactors();

  Future<TotpEnrollment?> enrollTotpFactor({String? friendlyName});

  Future<PhoneEnrollment?> enrollPhoneFactor({
    required String phone,
    String? friendlyName,
  });

  Future<String?> challengeMfaFactor(String factorId);

  Future<bool> verifyMfaFactor({
    required String factorId,
    required String challengeId,
    required String code,
    bool completesSignIn,
  });
}
