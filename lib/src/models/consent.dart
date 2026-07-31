/// The data-capture consents requested during onboarding.
///
/// Each item maps to concrete OS capabilities that Android and iOS require an
/// explicit, informed opt-in (and a usage-description string) for. The wire
/// [key]s are stable identifiers stored locally and in Supabase, so do not
/// rename them — add new items instead.
enum ConsentItem {
  /// RECORD_AUDIO / NSMicrophoneUsageDescription. The core capability; the app
  /// cannot function without it, so it is [required].
  microphone(
    key: 'microphone',
    title: 'Microphone & audio recording',
    rationale:
        'After you tap Start or explicitly arm a schedule, Sonus Auris may '
        'record a rolling local audio buffer and continue while the screen is '
        'locked or you use another app. A schedule records your intent, but it '
        'cannot override iOS or Android restrictions: force-quitting, '
        'force-stopping, or OS termination can prevent a future scheduled '
        'start. Android shows a persistent notification and iOS shows its '
        'microphone indicator while recording. The working rolling window may '
        'remain plaintext inside the app-private device sandbox for your '
        'configured retention period so approved local analysis can run. Every '
        'backup or cross-device sync object is encrypted on-device before it '
        'leaves. This consent is required for recording to work.',
    required: true,
  ),

  /// Storing/uploading the encrypted audio window off-device (cloud backup).
  cloudBackup(
    key: 'cloud_backup',
    title: 'Encrypted cloud backup & device sync',
    rationale:
        'Optionally back up a longer retention window or synchronize it to '
        'your authorized devices. Every audio object is end-to-end encrypted '
        'on-device before it leaves this device.',
    required: false,
  ),

  /// POST_NOTIFICATIONS (Android 13+) / iOS notifications — alarms & reminders.
  notifications(
    key: 'notifications',
    title: 'Notifications & alarms',
    rationale:
        'Used for sleep-cycle alarms, recording-state controls, and scheduled '
        'recording reminders or user actions when the operating system cannot '
        'start capture automatically.',
    required: false,
  ),

  /// ACCESS_FINE/COARSE_LOCATION / NSLocationWhenInUse — GPS evidence tagging
  /// and Wi-Fi-SSID context triggers.
  location(
    key: 'location',
    title: 'Location',
    rationale:
        'Optional GPS tags prove where a clip was recorded, and Wi-Fi network '
        'changes can prompt to start recording. Off unless you enable it.',
    required: false,
  ),

  /// Accelerometer (NSMotionUsageDescription) for collision hints and sleep.
  motion(
    key: 'motion',
    title: 'Motion sensor',
    rationale:
        'While recording, the accelerometer can flag a possible collision and '
        'remind you that audio is being saved. During sleep analysis it also '
        'detects stillness, tossing, and getting up. On-device only.',
    required: false,
  ),

  /// Bluetooth scan/connect (NSBluetoothAlwaysUsageDescription) for context
  /// triggers (nearby/connected devices).
  bluetooth(
    key: 'bluetooth',
    title: 'Bluetooth',
    rationale:
        'Detect connecting to a car or nearby devices to prompt recording. '
        'Off unless you enable context triggers.',
    required: false,
  );

  const ConsentItem({
    required this.key,
    required this.title,
    required this.rationale,
    required this.required,
  });

  final String key;
  final String title;
  final String rationale;
  final bool required;

  static ConsentItem? fromKey(String key) {
    for (final item in ConsentItem.values) {
      if (item.key == key) {
        return item;
      }
    }
    return null;
  }
}

/// An immutable record of the user's onboarding consent choices. Stored locally
/// and, once the user is signed in, synced to Supabase (`user_consents`).
class ConsentRecord {
  const ConsentRecord({
    required this.consentVersion,
    required this.acceptedAtUtc,
    required this.grants,
    this.platform = '',
    this.synced = false,
  });

  /// The disclosure version the user agreed to. When this no longer matches the
  /// app's current [kConsentVersion] the user is re-onboarded.
  final String consentVersion;
  final DateTime acceptedAtUtc;

  /// Per-[ConsentItem] grant, keyed by [ConsentItem.key].
  final Map<String, bool> grants;

  /// 'android' / 'ios' / etc. — recorded for audit.
  final String platform;

  /// True once this record has been written to Supabase.
  final bool synced;

  bool granted(ConsentItem item) => grants[item.key] ?? false;

  /// All required items are granted (a valid acceptance).
  bool get hasRequiredConsents =>
      ConsentItem.values.where((i) => i.required).every(granted);

  ConsentRecord copyWith({bool? synced}) {
    return ConsentRecord(
      consentVersion: consentVersion,
      acceptedAtUtc: acceptedAtUtc,
      grants: grants,
      platform: platform,
      synced: synced ?? this.synced,
    );
  }

  Map<String, dynamic> toJson() => {
    'consentVersion': consentVersion,
    'acceptedAtUtc': acceptedAtUtc.toIso8601String(),
    'platform': platform,
    'grants': grants,
    'synced': synced,
  };

  factory ConsentRecord.fromJson(Map<String, dynamic> json) {
    final rawGrants = json['grants'];
    final grants = <String, bool>{};
    if (rawGrants is Map) {
      rawGrants.forEach((key, value) {
        if (key is String && value is bool) {
          grants[key] = value;
        }
      });
    }
    return ConsentRecord(
      consentVersion: json['consentVersion'] as String? ?? '',
      acceptedAtUtc:
          DateTime.tryParse(json['acceptedAtUtc'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      grants: grants,
      platform: json['platform'] as String? ?? '',
      synced: json['synced'] as bool? ?? false,
    );
  }

  /// Row shape for the Supabase `user_consents` table. The authed user is
  /// resolved server-side from the access token (RLS `auth.uid()`), so no user
  /// id is sent from the client. [deviceId] ties the consent to this install.
  Map<String, dynamic> toSupabaseRow(String deviceId) => {
    'device_id': deviceId,
    'consent_version': consentVersion,
    'platform': platform,
    'granted': grants,
    'accepted_at': acceptedAtUtc.toIso8601String(),
  };
}
