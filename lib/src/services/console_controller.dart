// The console's application brain: owns the session lifecycle (passwordless +
// MFA), the device registry view, entitlements, and events, and exposes it all
// to the UI as a ChangeNotifier.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;

import '../config/console_config.dart';
import '../models/mfa.dart';
import '../models/supabase_session.dart';
import '../util/platform_info.dart';
import 'auth_client.dart';
import 'device_service.dart';
import 'entitlements_service.dart';
import 'events_service.dart';
import 'token_store.dart';

/// Where the user is in the sign-in journey.
enum AuthPhase {
  /// Restoring any stored session at startup.
  loading,

  /// Signed out — collect an email and send a code.
  signedOut,

  /// A code was emailed — collect it.
  codeSent,

  /// First factor cleared, but this account has no verified second factor yet.
  /// Console data remains inaccessible until enrollment is verified.
  mfaEnrollmentRequired,

  /// First factor cleared but the account requires a second factor.
  mfaRequired,

  /// Fully signed in with a verified factor and an `aal2` access token.
  signedIn,
}

class ConsoleController extends ChangeNotifier {
  ConsoleController({
    required this.config,
    TokenStore? tokenStore,
    AuthClient? authClient,
    DeviceService? deviceService,
    EntitlementsService? entitlementsService,
    EventsService? eventsService,
  }) : _store = tokenStore ?? createTokenStore(),
       _auth = authClient ?? AuthClient(config: config),
       _devices = deviceService ?? DeviceService(config: config),
       _entitlementsService =
           entitlementsService ?? EntitlementsService(config: config),
       _events = eventsService ?? EventsService(config: config);

  final ConsoleConfig config;
  final TokenStore _store;
  final AuthClient _auth;
  final DeviceService _devices;
  final EntitlementsService _entitlementsService;
  final EventsService _events;

  // --- observable state -----------------------------------------------------

  AuthPhase _phase = AuthPhase.loading;
  AuthPhase get phase => _phase;

  bool get isSignedIn => _phase == AuthPhase.signedIn;

  String _pendingEmail = '';
  String get pendingEmail => _pendingEmail;

  SupabaseSession? _session;
  String get email => _session?.email ?? _pendingEmail;
  String get userId => _session?.userId ?? '';

  String? _message;
  String? get message => _message;

  bool _busy = false;
  bool get busy => _busy;
  bool _authCallbackInProgress = false;

  List<interfaces.DeviceRecord> _deviceList = const [];
  List<interfaces.DeviceRecord> get devices => _deviceList;

  Entitlement _entitlement = Entitlement.free;
  Entitlement get entitlement => _entitlement;

  Set<String> _lockedDeviceIds = const {};
  Set<String> get lockedDeviceIds => _lockedDeviceIds;

  List<MfaFactor> _factors = const [];
  List<MfaFactor> get factors => _factors;

  List<interfaces.AcousticEvent> _events_ = const [];
  List<interfaces.AcousticEvent> get events => _events_;

  Future<void>? _refreshInFlight;

  // MFA challenge state during sign-in.
  String? _challengeFactorId;
  String? _challengeId;
  MfaFactor? get pendingChallengeFactor => _factors
      .where((f) => f.id == _challengeFactorId)
      .cast<MfaFactor?>()
      .firstOrNull;

  int get activeRecorderCount => activeRecorderDevices(_deviceList).length;

  /// Recorder devices unlocked under the current plan (limit honored).
  List<interfaces.DeviceRecord> get unlockedRecorders => activeRecorderDevices(
    _deviceList,
  ).where((d) => !_lockedDeviceIds.contains(d.deviceId)).toList();

  // --- lifecycle ------------------------------------------------------------

  /// Restores a stored session at startup and, if present and valid, lands the
  /// user straight in the console (after any needed refresh + MFA check).
  Future<void> bootstrap() async {
    final stored = await _store.readSession();
    if (stored == null || stored.isEmpty) {
      _setPhase(AuthPhase.signedOut);
      return;
    }
    if (!stored.hasPasswordlessFirstFactor) {
      await _store.clearSession();
      _setPhase(AuthPhase.signedOut);
      return;
    }
    _session = stored;
    try {
      await _ensureFreshToken();
      await _continueAfterFirstFactor();
    } catch (_) {
      // A stale/invalid stored session shouldn't strand the app on a spinner.
      await _clearSession();
      _setPhase(AuthPhase.signedOut);
    }
  }

  // --- passwordless sign-in -------------------------------------------------

  Future<void> sendEmailCode(String email) async {
    await _guard(() async {
      final redirect = _auth.magicLinkRedirectUri;
      if (redirect == null) {
        throw const FormatException(
          'Configure an HTTPS magic-link callback before signing in.',
        );
      }
      final verifier = AuthClient.createPkceVerifier();
      await _store.writePendingMagicLink(
        PendingMagicLink(
          codeVerifier: verifier,
          email: email.trim(),
          supabaseUrl: config.supabaseUrl.trim(),
          redirectUrl: redirect.toString(),
          requestedAtUtc: DateTime.now().toUtc(),
        ),
      );
      await _auth.sendEmailOtp(email, codeVerifier: verifier);
      _pendingEmail = email.trim();
      _message = 'We emailed a sign-in code to ${email.trim()}.';
      _phase = AuthPhase.codeSent;
    });
  }

  Future<void> resendEmailCode() async {
    if (_pendingEmail.isEmpty) return;
    await _guard(() async {
      final redirect = _auth.magicLinkRedirectUri;
      if (redirect == null) {
        throw const FormatException(
          'Configure an HTTPS magic-link callback before signing in.',
        );
      }
      final verifier = AuthClient.createPkceVerifier();
      await _store.writePendingMagicLink(
        PendingMagicLink(
          codeVerifier: verifier,
          email: _pendingEmail,
          supabaseUrl: config.supabaseUrl.trim(),
          redirectUrl: redirect.toString(),
          requestedAtUtc: DateTime.now().toUtc(),
        ),
      );
      await _auth.sendEmailOtp(_pendingEmail, codeVerifier: verifier);
      _message = 'Sent a fresh code to $_pendingEmail.';
    });
  }

  Future<void> verifyEmailCode(String code) async {
    await _guard(() async {
      final session = await _auth.verifyEmailOtp(
        email: _pendingEmail,
        code: code,
      );
      await _store.clearPendingMagicLink();
      await _acceptFirstFactorSession(session, expectedEmail: _pendingEmail);
    });
  }

  /// Completes passwordless sign-in from a verified operating-system deep link.
  /// The callback is never logged or persisted; only the resulting session is.
  Future<void> consumeMagicLink(Uri callback) async {
    await _guard(() async {
      final session = await _auth.consumeMagicLink(callback);
      await _acceptFirstFactorSession(session, expectedEmail: _pendingEmail);
    });
  }

  Future<bool> acceptMagicLink(Uri callback) async {
    // On web the plain page URL arrives on the same channel as a real callback.
    // Treat a URL with no sign-in material as "not mine" rather than reporting
    // a malformed link, which otherwise greets every visitor with an error.
    if (!_auth.isExpectedMagicLinkCallback(callback) ||
        !_auth.hasMagicLinkPayload(callback)) {
      return false;
    }
    if (_authCallbackInProgress) {
      return true;
    }
    _authCallbackInProgress = true;
    try {
      await _guard(() async {
        final code = _auth.authorizationCodeFromCallback(callback);
        final pending = await _store.readPendingMagicLink();
        final redirect = _auth.magicLinkRedirectUri;
        if (pending == null) {
          throw StateError(
            'This magic link was not requested in this browser. Request a fresh one.',
          );
        }
        if (pending.isExpired() ||
            pending.supabaseUrl != config.supabaseUrl.trim() ||
            redirect == null ||
            pending.redirectUrl != redirect.toString()) {
          await _store.clearPendingMagicLink();
          throw StateError(
            'This sign-in request expired. Request a fresh magic link.',
          );
        }
        final session = await _auth.exchangePkceCode(
          authorizationCode: code,
          codeVerifier: pending.codeVerifier,
        );
        await _store.clearPendingMagicLink();
        await _acceptFirstFactorSession(
          session,
          expectedEmail: pending.email,
          successMessage: 'Signed in with your magic link.',
        );
      });
      return true;
    } finally {
      _authCallbackInProgress = false;
    }
  }

  Future<void> _requireExpectedIdentity(
    SupabaseSession session,
    String expectedEmail,
  ) async {
    final expected = expectedEmail.trim().toLowerCase();
    final verified = session.email.trim().toLowerCase();
    if (expected.isNotEmpty && verified == expected) {
      return;
    }
    await _auth.signOut(session.accessToken);
    throw StateError(
      'The verified account did not match this sign-in request. '
      'Request a fresh link or code.',
    );
  }

  /// Restarts the sign-in from the email step.
  void backToEmail() {
    _challengeFactorId = null;
    _challengeId = null;
    _setPhase(AuthPhase.signedOut);
  }

  // --- MFA challenge (sign-in) ---------------------------------------------

  /// Selects which enrolled factor to challenge. For a phone factor this sends
  /// the SMS immediately.
  Future<void> beginMfaChallenge(String factorId) async {
    await _guard(() async {
      _challengeFactorId = factorId;
      _challengeId = await _auth.challengeFactor(_accessToken, factorId);
      final factor = _factors.where((f) => f.id == factorId).firstOrNull;
      _message = factor?.isPhone == true
          ? 'We texted a code to your phone.'
          : 'Enter the code from your authenticator app.';
    });
  }

  Future<void> submitMfaChallenge(String code) async {
    await _guard(() async {
      final factorId = _challengeFactorId;
      final challengeId = _challengeId;
      if (factorId == null || challengeId == null) {
        throw const FormatException('Start a verification challenge first.');
      }
      final session = await _auth.verifyFactor(
        _accessToken,
        factorId: factorId,
        challengeId: challengeId,
        code: code,
      );
      if (!session.isPasswordlessAal2) {
        await _expireSession();
        throw StateError(
          'Supabase did not preserve passwordless sign-in after MFA. '
          'Sign in again.',
        );
      }
      _session = session;
      await _store.writeSession(session);
      _challengeFactorId = null;
      _challengeId = null;
      await _enterConsole();
    });
  }

  Future<void> signOut() async {
    final token = _session?.accessToken ?? '';
    if (token.isNotEmpty) {
      await _auth.signOut(token);
    }
    await _clearSession();
    await _store.clearPendingMagicLink();
    _dropAccountData();
    _factors = const [];
    _pendingEmail = '';
    _message = 'Signed out.';
    _setPhase(AuthPhase.signedOut);
  }

  // --- console data ---------------------------------------------------------

  Future<void> refreshAll() async {
    await Future.wait([refreshDevicesAndEntitlements(), refreshEvents()]);
  }

  Future<void> refreshDevicesAndEntitlements() async {
    if (!isSignedIn) return;
    await _ensureFreshToken();
    final token = _accessToken;
    final entitlementResult = await _entitlementsService.fetch(token);
    _entitlement = entitlementResult.entitlement;
    final listing = await _devices.listDevices(token);
    if (listing.error != null) {
      _message = listing.error;
    }
    _deviceList = listing.devices;
    _lockedDeviceIds = overLimitDeviceIds(
      _deviceList,
      _entitlement.deviceLimit,
    );
    notifyListeners();
  }

  Future<void> refreshEvents({String? deviceId}) async {
    if (!isSignedIn) return;
    await _ensureFreshToken();
    final result = await _events.list(_accessToken, deviceId: deviceId);
    if (result.error != null) {
      _message = result.error;
    }
    // Only show events from unlocked devices (locked ones are gated behind the
    // plan). A null/blank device_id row is always shown.
    final unlocked = unlockedRecorders.map((d) => d.deviceId).toSet();
    _events_ = result.events
        .where(
          (e) => e.deviceId.trim().isEmpty || unlocked.contains(e.deviceId),
        )
        .toList();
    notifyListeners();
  }

  Future<void> renameDevice(String deviceId, String name) async {
    await _guard(() async {
      final err = await _devices.rename(
        accessToken: _accessToken,
        deviceId: deviceId,
        displayName: name,
      );
      if (err != null) throw StateError(err);
    });
    await refreshDevicesAndEntitlements();
  }

  Future<void> revokeDevice(String deviceId) async {
    await _guard(() async {
      final err = await _devices.revoke(
        accessToken: _accessToken,
        deviceId: deviceId,
      );
      if (err != null) throw StateError(err);
    });
    await refreshDevicesAndEntitlements();
  }

  // --- MFA management (Account screen) --------------------------------------

  Future<void> refreshFactors() async {
    if (!isSignedIn &&
        _phase != AuthPhase.mfaRequired &&
        _phase != AuthPhase.mfaEnrollmentRequired) {
      return;
    }
    final nextPhase = await _refreshMfaState();
    // `_refreshMfaState` returns the only safe state for the current token, and
    // every other caller acts on it. Adopt it here too whenever it is a
    // downgrade: if the last verified factor disappears (removed from another
    // session, or revoked by an admin) the console must leave the signed-in
    // surface instead of continuing to stream account-scoped devices/events.
    // Upgrades still go through `_enterConsole`, which re-checks aal2.
    if (_phase == AuthPhase.signedIn && nextPhase != AuthPhase.signedIn) {
      _dropAccountData();
      _message =
          'Two-factor verification is required again before accessing your '
          'account.';
      _setPhase(nextPhase);
      return;
    }
    notifyListeners();
  }

  Future<TotpEnrollment?> enrollTotp({String? name}) async {
    return _guardValue(
      () => _auth.enrollTotp(_accessToken, friendlyName: name),
    );
  }

  Future<PhoneEnrollment?> enrollPhone(String phone, {String? name}) async {
    return _guardValue(
      () => _auth.enrollPhone(_accessToken, phone: phone, friendlyName: name),
    );
  }

  Future<String?> startFactorChallenge(String factorId) async {
    return _guardValue(() => _auth.challengeFactor(_accessToken, factorId));
  }

  /// Verifies a freshly-enrolled factor (not the sign-in challenge). Adopts the
  /// returned aal2 session.
  Future<bool> confirmFactorEnrollment({
    required String factorId,
    required String challengeId,
    required String code,
  }) async {
    final ok = await _guard(() async {
      final session = await _auth.verifyFactor(
        _accessToken,
        factorId: factorId,
        challengeId: challengeId,
        code: code,
      );
      if (!session.isPasswordlessAal2) {
        await _expireSession();
        throw StateError(
          'Supabase did not preserve passwordless sign-in after MFA. '
          'Sign in again.',
        );
      }
      _session = session;
      await _store.writeSession(session);
      final nextPhase = await _refreshMfaState();
      if (nextPhase != AuthPhase.signedIn) {
        throw StateError(
          'The second factor was not activated. Start enrollment again.',
        );
      }
      _message = 'Two-factor authentication is on.';
      if (_phase == AuthPhase.mfaEnrollmentRequired) {
        await _enterConsole();
      }
    });
    return ok;
  }

  Future<void> removeFactor(String factorId) async {
    await _guard(() async {
      final verified = _factors.where((factor) => factor.isVerified).toList();
      if (verified.length <= 1 &&
          verified.any((factor) => factor.id == factorId)) {
        throw StateError(
          'Two-factor authentication is mandatory. Add and verify another '
          'method before removing this one.',
        );
      }
      await _auth.unenrollFactor(_accessToken, factorId);
      await _refreshMfaState();
      _message = 'Removed a two-factor method.';
    });
  }

  // --- internals ------------------------------------------------------------

  String get _accessToken => _session?.accessToken ?? '';

  /// Adopts a first-factor session (email code or magic link): verifies it is
  /// passwordless and belongs to the identity that requested sign-in, persists
  /// it, then continues to enrollment, the MFA challenge, or the console.
  Future<void> _acceptFirstFactorSession(
    SupabaseSession session, {
    String? expectedEmail,
    String? successMessage,
  }) async {
    if (!session.hasPasswordlessFirstFactor) {
      throw StateError(
        'Supabase did not return a passwordless session. Sign in again.',
      );
    }
    await _requireExpectedIdentity(session, expectedEmail ?? _pendingEmail);
    _session = session;
    _pendingEmail = session.email;
    await _store.writeSession(session);
    await _continueAfterFirstFactor(successMessage: successMessage);
  }

  Future<void> _continueAfterFirstFactor({String? successMessage}) async {
    final nextPhase = await _refreshMfaState();
    switch (nextPhase) {
      case AuthPhase.mfaEnrollmentRequired:
        _message =
            'Set up an authenticator app or verified phone to finish creating '
            'your account.';
        _setPhase(AuthPhase.mfaEnrollmentRequired);
        return;
      case AuthPhase.mfaRequired:
        _message = 'Enter your two-factor code to finish signing in.';
        _setPhase(AuthPhase.mfaRequired);
        return;
      default:
        await _enterConsole();
        if (successMessage != null) {
          _message = successMessage;
        }
        return;
    }
  }

  Future<void> _enterConsole() async {
    final hasVerifiedFactor = _factors.any((factor) => factor.isVerified);
    if (!hasVerifiedFactor || !(_session?.isPasswordlessAal2 ?? false)) {
      throw StateError(
        'Passwordless sign-in and a verified second factor are required.',
      );
    }
    _setPhase(AuthPhase.signedIn);
    // Register this console as a viewer device, then load data.
    unawaited(_registerSelf());
    await refreshAll();
  }

  Future<void> _registerSelf() async {
    try {
      final deviceId = await _store.deviceInstallId();
      await _devices.registerSelf(
        accessToken: _accessToken,
        deviceId: deviceId,
        displayName: defaultConsoleName(),
        platform: platformWire(),
        appVersion: kConsoleVersion,
      );
    } catch (_) {
      // Non-fatal: the console still works without its own row listed.
    }
  }

  /// Loads factors and returns the only safe next authentication state. Fails
  /// closed unless the session has both an enrolled factor and the `aal2`
  /// claim issued after verifying it.
  Future<AuthPhase> _refreshMfaState() async {
    if (_accessToken.isEmpty) {
      throw StateError('The Supabase access token is missing.');
    }
    _factors = await _auth.listFactors(_accessToken);
    final hasVerified = _factors.any((f) => f.isVerified);
    if (!hasVerified) {
      _challengeFactorId = null;
      _challengeId = null;
      return AuthPhase.mfaEnrollmentRequired;
    }
    if (!(_session?.isPasswordlessAal2 ?? false)) {
      if (_challengeFactorId == null ||
          !_factors.any(
            (factor) => factor.id == _challengeFactorId && factor.isVerified,
          )) {
        // Default to the first verified factor for the challenge screen.
        _challengeFactorId = _factors.firstWhere((f) => f.isVerified).id;
      }
      return AuthPhase.mfaRequired;
    }
    _challengeFactorId = null;
    _challengeId = null;
    return AuthPhase.signedIn;
  }

  Future<void> _ensureFreshToken() async {
    final session = _session;
    if (session == null || !session.needsRefresh()) {
      return;
    }
    if (session.refreshToken.trim().isEmpty) {
      await _expireSession();
      throw StateError('Your secure session expired. Sign in again.');
    }
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final future = _refreshCurrentSession(session);
    _refreshInFlight = future;
    try {
      await future;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<void> _refreshCurrentSession(SupabaseSession previous) async {
    try {
      var refreshed = await _auth.refreshSession(previous.refreshToken);
      if (refreshed.userId != previous.userId) {
        await _expireSession();
        throw StateError(
          'Supabase returned a session for another account. Sign in again.',
        );
      }
      if (!refreshed.hasPasswordlessFirstFactor) {
        await _expireSession();
        throw StateError(
          'Supabase did not preserve passwordless sign-in. Sign in again.',
        );
      }
      if (refreshed.refreshToken.trim().isEmpty) {
        refreshed = refreshed.copyWith(refreshToken: previous.refreshToken);
      }
      _session = refreshed;
      await _store.writeSession(refreshed);
      if (_phase == AuthPhase.signedIn && !refreshed.isPasswordlessAal2) {
        final nextPhase = await _refreshMfaState();
        _setPhase(nextPhase);
        throw StateError(
          'Your session needs passwordless sign-in and two-factor verification '
          'before accessing data.',
        );
      }
    } catch (_) {
      if (!previous.expiresAtUtc.isAfter(DateTime.now().toUtc())) {
        await _expireSession();
      }
      rethrow;
    }
  }

  /// Drops everything loaded under an authenticated session. Kept separate from
  /// [_clearSession] so a phase downgrade can discard account-scoped data
  /// without throwing away the first-factor session the user still needs to
  /// finish verifying.
  void _dropAccountData() {
    _deviceList = const [];
    _events_ = const [];
    _entitlement = Entitlement.free;
    _lockedDeviceIds = const {};
  }

  Future<void> _expireSession() async {
    await _clearSession();
    _dropAccountData();
    _factors = const [];
    _setPhase(AuthPhase.signedOut);
  }

  Future<void> _clearSession() async {
    _session = null;
    await _store.clearSession();
  }

  void _setPhase(AuthPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// Runs [action] with the busy flag + error capture, returning success.
  Future<bool> _guard(Future<void> Function() action) async {
    _busy = true;
    _message = null;
    notifyListeners();
    var ok = false;
    try {
      await action();
      ok = true;
    } catch (error) {
      _message = _errorText(error);
    } finally {
      _busy = false;
      notifyListeners();
    }
    return ok;
  }

  Future<T?> _guardValue<T>(Future<T> Function() action) async {
    _busy = true;
    _message = null;
    notifyListeners();
    T? value;
    try {
      value = await action();
    } catch (error) {
      _message = _errorText(error);
    } finally {
      _busy = false;
      notifyListeners();
    }
    return value;
  }

  String _errorText(Object error) {
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return '$error';
  }

  @override
  void dispose() {
    _auth.close();
    _devices.close();
    _entitlementsService.close();
    _events.close();
    super.dispose();
  }
}
