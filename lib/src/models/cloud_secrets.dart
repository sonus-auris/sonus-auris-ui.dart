// In-memory holder for per-provider cloud credentials plus Supabase/STT/music tokens; persisted only in secure storage.
class CloudSecrets {
  const CloudSecrets({
    this.s3AccessKeyId = '',
    this.s3SecretAccessKey = '',
    this.s3SessionToken = '',
    this.backendDeviceToken = '',
    this.supabaseAccessToken = '',
    this.supabaseRefreshToken = '',
    this.supabaseAccessTokenExpiresAt = '',
    this.supabaseEmail = '',
    this.sttApiKey = '',
    this.soundCloudAccessToken = '',
    this.soundCloudRefreshToken = '',
    this.spotifyAccessToken = '',
    this.spotifyRefreshToken = '',
  });

  final String s3AccessKeyId;
  final String s3SecretAccessKey;
  final String s3SessionToken;
  final String backendDeviceToken;

  /// Supabase access-token JWT for the signed-in user. Sent to the backend as
  /// the `x-supabase-auth` identity header for registration and cloud linking.
  /// Never an admin/service key — only the user's session token.
  final String supabaseAccessToken;

  /// Supabase refresh token used to silently mint a fresh access token when the
  /// short-lived [supabaseAccessToken] is near expiry. Rotated on every refresh.
  final String supabaseRefreshToken;

  /// ISO-8601 UTC expiry of [supabaseAccessToken]. Empty when unknown.
  final String supabaseAccessTokenExpiresAt;

  /// Email of the signed-in Supabase user, for display only.
  final String supabaseEmail;

  /// API key/bearer for the opt-in cloud speech-to-text endpoint. Secret; empty
  /// when STT is unconfigured.
  final String sttApiKey;

  /// OAuth tokens for the user's linked SoundCloud account. Empty when unlinked.
  final String soundCloudAccessToken;
  final String soundCloudRefreshToken;

  /// OAuth tokens for the user's linked Spotify account. Empty when unlinked.
  final String spotifyAccessToken;
  final String spotifyRefreshToken;

  bool get hasSttApiKey => sttApiKey.trim().isNotEmpty;

  bool get hasSoundCloudToken => soundCloudAccessToken.trim().isNotEmpty;

  bool get hasSpotifyToken => spotifyAccessToken.trim().isNotEmpty;

  bool get hasS3Credentials =>
      s3AccessKeyId.trim().isNotEmpty && s3SecretAccessKey.trim().isNotEmpty;

  bool get hasBackendDeviceToken => backendDeviceToken.trim().isNotEmpty;

  bool get hasSupabaseToken => supabaseAccessToken.trim().isNotEmpty;

  bool get hasSupabaseRefreshToken => supabaseRefreshToken.trim().isNotEmpty;

  /// Either a usable access token or a refresh token we can redeem for one.
  bool get hasSupabaseSession => hasSupabaseToken || hasSupabaseRefreshToken;

  DateTime? get supabaseTokenExpiresAtUtc {
    final raw = supabaseAccessTokenExpiresAt.trim();
    if (raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// True when there is no access token, or it expires within [skew]. Callers
  /// should refresh before using the token for a backend request.
  bool supabaseTokenNeedsRefresh({
    Duration skew = const Duration(seconds: 60),
    DateTime? now,
  }) {
    if (!hasSupabaseToken) {
      return hasSupabaseRefreshToken;
    }
    final expiresAt = supabaseTokenExpiresAtUtc;
    if (expiresAt == null) {
      return false;
    }
    final reference = (now ?? DateTime.now().toUtc()).add(skew);
    return !reference.isBefore(expiresAt);
  }

  CloudSecrets copyWith({
    String? s3AccessKeyId,
    String? s3SecretAccessKey,
    String? s3SessionToken,
    String? backendDeviceToken,
    String? supabaseAccessToken,
    String? supabaseRefreshToken,
    String? supabaseAccessTokenExpiresAt,
    String? supabaseEmail,
    String? sttApiKey,
    String? soundCloudAccessToken,
    String? soundCloudRefreshToken,
    String? spotifyAccessToken,
    String? spotifyRefreshToken,
  }) {
    return CloudSecrets(
      s3AccessKeyId: s3AccessKeyId ?? this.s3AccessKeyId,
      s3SecretAccessKey: s3SecretAccessKey ?? this.s3SecretAccessKey,
      s3SessionToken: s3SessionToken ?? this.s3SessionToken,
      backendDeviceToken: backendDeviceToken ?? this.backendDeviceToken,
      supabaseAccessToken: supabaseAccessToken ?? this.supabaseAccessToken,
      supabaseRefreshToken: supabaseRefreshToken ?? this.supabaseRefreshToken,
      supabaseAccessTokenExpiresAt:
          supabaseAccessTokenExpiresAt ?? this.supabaseAccessTokenExpiresAt,
      supabaseEmail: supabaseEmail ?? this.supabaseEmail,
      sttApiKey: sttApiKey ?? this.sttApiKey,
      soundCloudAccessToken:
          soundCloudAccessToken ?? this.soundCloudAccessToken,
      soundCloudRefreshToken:
          soundCloudRefreshToken ?? this.soundCloudRefreshToken,
      spotifyAccessToken: spotifyAccessToken ?? this.spotifyAccessToken,
      spotifyRefreshToken: spotifyRefreshToken ?? this.spotifyRefreshToken,
    );
  }

  /// Clears every Supabase identity field while leaving cloud/device credentials
  /// untouched. Used on sign-out.
  CloudSecrets withoutSupabaseSession() {
    return CloudSecrets(
      s3AccessKeyId: s3AccessKeyId,
      s3SecretAccessKey: s3SecretAccessKey,
      s3SessionToken: s3SessionToken,
      backendDeviceToken: backendDeviceToken,
      sttApiKey: sttApiKey,
      soundCloudAccessToken: soundCloudAccessToken,
      soundCloudRefreshToken: soundCloudRefreshToken,
      spotifyAccessToken: spotifyAccessToken,
      spotifyRefreshToken: spotifyRefreshToken,
    );
  }

  /// Clears the tokens for one linked music account on unlink.
  CloudSecrets withoutSpotify() =>
      copyWith(spotifyAccessToken: '', spotifyRefreshToken: '');

  CloudSecrets withoutSoundCloud() =>
      copyWith(soundCloudAccessToken: '', soundCloudRefreshToken: '');
}
