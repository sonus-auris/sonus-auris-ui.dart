// Account-level cloud state surfaced to the UI: pending MFA challenges, the
// device registry outcome for THIS install, and the plan/device-limit gate.
import 'supabase_mfa.dart';

class AccountStatus {
  const AccountStatus({
    this.mfaRequired = false,
    this.mfaFactors = const <MfaFactor>[],
    this.deviceRevoked = false,
    this.activeRecorderDeviceCount = 0,
    this.exceededDeviceLimit = false,
    this.plan = 'free',
    this.deviceLimit = 2,
    this.features = const <String, Object?>{},
  });

  /// The first factor succeeded but the account has verified MFA factors and
  /// the session is still `aal1` — the UI must run a factor challenge before
  /// treating the user as signed in.
  final bool mfaRequired;

  /// Factors known for the signed-in user (verified and pending), for both the
  /// challenge step and the Account management list.
  final List<MfaFactor> mfaFactors;

  /// This install's `devices` row carries `revoked_at`: the owner removed the
  /// device in the console. Cloud sync is halted until it re-registers.
  final bool deviceRevoked;

  /// Active (non-revoked) recorder devices on the account, this one included.
  final int activeRecorderDeviceCount;

  /// True when the account holds more active recorders than the plan allows
  /// AND this install is among the stalest ones over the line. A soft gate:
  /// the UI shows the upgrade banner; recording keeps working until
  /// server-side enforcement lands.
  final bool exceededDeviceLimit;

  /// `free` or `plus` (from the entitlements row; free when absent).
  final String plan;

  /// Active recorder devices the plan allows.
  final int deviceLimit;

  /// Plan feature flags (e.g. `permanent_saves`).
  final Map<String, Object?> features;

  bool get isPlus => plan.trim().toLowerCase() == 'plus';

  List<MfaFactor> get verifiedMfaFactors =>
      mfaFactors.where((factor) => factor.isVerified).toList(growable: false);

  AccountStatus copyWith({
    bool? mfaRequired,
    List<MfaFactor>? mfaFactors,
    bool? deviceRevoked,
    int? activeRecorderDeviceCount,
    bool? exceededDeviceLimit,
    String? plan,
    int? deviceLimit,
    Map<String, Object?>? features,
  }) {
    return AccountStatus(
      mfaRequired: mfaRequired ?? this.mfaRequired,
      mfaFactors: mfaFactors ?? this.mfaFactors,
      deviceRevoked: deviceRevoked ?? this.deviceRevoked,
      activeRecorderDeviceCount:
          activeRecorderDeviceCount ?? this.activeRecorderDeviceCount,
      exceededDeviceLimit: exceededDeviceLimit ?? this.exceededDeviceLimit,
      plan: plan ?? this.plan,
      deviceLimit: deviceLimit ?? this.deviceLimit,
      features: features ?? this.features,
    );
  }
}
