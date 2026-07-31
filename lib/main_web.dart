// Browser entrypoint for the Sonus Auris account and diagnostic surface.
//
// The audio recorder deliberately remains native-only: browser microphones do
// not provide the background-capture and encrypted local-file guarantees of the
// Android, iOS, and desktop clients. This surface still uses the same Supabase
// authentication, redaction, durable telemetry, and Realtime Broadcast protocol
// as every signed-in client.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import 'src/models/app_config.dart';
import 'src/models/client_telemetry_event.dart';
import 'src/models/cloud_secrets.dart';
import 'src/models/pending_supabase_auth.dart';
import 'src/models/supabase_session.dart';
import 'src/services/account_group_service.dart';
import 'src/services/device_registry.dart';
import 'src/services/supabase_auth_client.dart';
import 'src/services/supabase_device_presence_client.dart';
import 'src/services/supabase_rest_client.dart';
import 'src/services/supabase_telemetry_realtime_client.dart';
import 'src/widgets/supabase_auth_form.dart';

const _authRedirectUrl = String.fromEnvironment(
  'SONUS_SUPABASE_AUTH_REDIRECT_URL',
);
const _pendingAuthPreferenceKey = 'sonus_auris.web.pending_auth.v1';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SonusWebApp());
}

class SonusWebApp extends StatefulWidget {
  const SonusWebApp({super.key});

  @override
  State<SonusWebApp> createState() => _SonusWebAppState();
}

class _SonusWebAppState extends State<SonusWebApp> with WidgetsBindingObserver {
  final _auth = SupabaseAuthClient();
  final _rest = SupabaseRestClient();
  final _realtime = SupabaseTelemetryRealtimeClient();
  final _deviceRegistry = DeviceRegistry();
  final _accountGroups = AccountGroupService();
  final _devicePresenceClient = SupabaseDevicePresenceClient();
  final _email = TextEditingController();
<<<<<<< HEAD
=======
  final _code = TextEditingController();
>>>>>>> origin/main
  final _supabaseUrl = TextEditingController(
    text: AppConfig.defaultSupabaseUrl,
  );
  final _supabaseKey = TextEditingController(
    text: AppConfig.defaultSupabaseAnonKey,
  );
  String _deviceId = 'web-${const Uuid().v4()}';
  final _sessionId = const Uuid().v4();

  AppConfig? _config;
  SupabaseSession? _session;
  Timer? _refreshTimer;
  Timer? _deviceHeartbeatTimer;
  StreamSubscription<Uri>? _authLinkSubscription;
  StreamSubscription<DevicePresenceSnapshot>? _presenceSubscription;
  FlutterExceptionHandler? _previousFlutterOnError;
  ui.ErrorCallback? _previousPlatformOnError;
  String _status = 'Sign in to enable account-scoped diagnostic streaming.';
  List<interfaces.DeviceRecord> _devices = const [];
  DevicePresenceSnapshot _presence = const DevicePresenceSnapshot();
  bool _authCallbackInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authLinkSubscription = AppLinks().uriLinkStream.listen(
      (uri) => unawaited(_handleMagicLink(uri)),
      onError: (_) {},
    );
    _presenceSubscription = _devicePresenceClient.snapshots.listen((snapshot) {
      if (mounted) setState(() => _presence = snapshot);
    });
    unawaited(_initializeWebIdentity());
    _previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(
        _record(
          level: 'error',
          event: 'flutter_error',
          message: details.exceptionAsString(),
          stack: details.stack?.toString(),
        ),
      );
      _previousFlutterOnError?.call(details);
    };
    _previousPlatformOnError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        _record(
          level: 'fatal',
          event: 'platform_dispatcher_error',
          message: error.toString(),
          stack: stack.toString(),
        ),
      );
      return _previousPlatformOnError?.call(error, stack) ?? false;
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshIfNeeded());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterError.onError = _previousFlutterOnError;
    ui.PlatformDispatcher.instance.onError = _previousPlatformOnError;
    _refreshTimer?.cancel();
    _deviceHeartbeatTimer?.cancel();
    _authLinkSubscription?.cancel();
    _presenceSubscription?.cancel();
    _devicePresenceClient.close();
    _realtime.close();
    _auth.close();
    _rest.close();
    _email.dispose();
<<<<<<< HEAD
=======
    _code.dispose();
>>>>>>> origin/main
    _supabaseUrl.dispose();
    _supabaseKey.dispose();
    super.dispose();
  }

  Future<void> _initializeWebIdentity() async {
    final preferences = await SharedPreferences.getInstance();
    const key = 'sonus_auris.web_device_id.v1';
    var deviceId = preferences.getString(key)?.trim() ?? '';
    if (deviceId.isEmpty) {
      deviceId = 'web-${const Uuid().v4()}';
      await preferences.setString(key, deviceId);
    }
    _deviceId = deviceId;
    final initial = await AppLinks().getInitialLink();
    if (initial != null) await _handleMagicLink(initial);
  }

  AppConfig _currentConfig() => AppConfig(
    deviceId: _deviceId,
    supabaseUrl: _supabaseUrl.text.trim(),
    supabaseAnonKey: _supabaseKey.text.trim(),
  );

<<<<<<< HEAD
  String get _effectiveAuthRedirectUrl {
    if (_authRedirectUrl.trim().isNotEmpty) {
      return _authRedirectUrl.trim();
    }
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path,
    ).toString();
  }

  Future<bool> _sendMagicLink(String email) async {
    final config = _currentConfig();
    final codeVerifier = SupabaseAuthClient.createPkceVerifier();
    final pending = PendingSupabaseAuth(
      codeVerifier: codeVerifier,
      email: email.trim(),
      supabaseUrl: config.supabaseUrl.trim(),
      redirectUrl: _effectiveAuthRedirectUrl,
      requestedAtUtc: DateTime.now().toUtc(),
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _pendingAuthPreferenceKey,
      jsonEncode(pending.toJson()),
    );
    await _auth.sendEmailOtp(
      config: config,
      email: email,
      codeVerifier: codeVerifier,
      redirectTo: _effectiveAuthRedirectUrl,
    );
    if (mounted) {
      setState(() {
        _config = config;
        _status = 'Magic link sent. Check your email.';
=======
  Future<bool> _requestCode(String email) async {
    final config = _currentConfig();
    await _auth.sendEmailOtp(config: config, email: email);
    if (mounted) {
      setState(() {
        _config = config;
        _status = 'We emailed you a sign-in link and a 6-digit code.';
>>>>>>> origin/main
      });
    }
    return true;
  }

<<<<<<< HEAD
  Future<bool> _verifyEmailCode(String email, String code) async {
=======
  Future<void> _submitCode(String email, String code) async {
>>>>>>> origin/main
    final config = _currentConfig();
    final session = await _auth.verifyEmailOtp(
      config: config,
      email: email,
      code: code,
    );
<<<<<<< HEAD
    await _clearPendingAuth();
    await _requireExpectedIdentity(config, session, email);
    await _adoptSession(config, session, status: 'Signed in.');
    return true;
  }

  Future<void> _handleMagicLink(Uri uri) async {
    final expected = Uri.parse(_effectiveAuthRedirectUrl);
    if (!SupabaseAuthClient.isExpectedMagicLinkCallback(
      callbackUri: uri,
      expectedRedirectUri: expected,
    )) {
      return;
    }
    if (_authCallbackInProgress) {
      return;
    }
    _authCallbackInProgress = true;
    _clearBrowserAuthCallback();
    try {
      final config = _currentConfig();
      final authorizationCode =
          SupabaseAuthClient.authorizationCodeFromCallback(
            callbackUri: uri,
            expectedRedirectUri: expected,
          );
      final pending = await _loadPendingAuth();
      if (pending == null) {
        throw StateError(
          'This magic link was not requested in this browser. Request a fresh one.',
        );
      }
      if (pending.isExpired() ||
          pending.supabaseUrl != config.supabaseUrl.trim() ||
          pending.redirectUrl != _effectiveAuthRedirectUrl) {
        await _clearPendingAuth();
        throw StateError(
          'This sign-in request expired. Request a fresh magic link.',
        );
      }
      final session = await _auth.exchangePkceCode(
        config: config,
        authorizationCode: authorizationCode,
        codeVerifier: pending.codeVerifier,
      );
      await _clearPendingAuth();
      await _requireExpectedIdentity(config, session, pending.email);
      await _adoptSession(
        config,
        session,
        status: 'Signed in with your magic link.',
      );
    } catch (error) {
      if (mounted) {
        setState(() => _status = describeAuthError(error));
      }
    } finally {
      _authCallbackInProgress = false;
    }
  }

  Future<void> _requireExpectedIdentity(
    AppConfig config,
    SupabaseSession session,
    String expectedEmail,
  ) async {
    if (SupabaseAuthClient.sessionMatchesRequestedEmail(
      session: session,
      requestedEmail: expectedEmail,
    )) {
      return;
    }
    await _auth.signOut(config: config, accessToken: session.accessToken);
    throw StateError(
      'The verified account did not match this sign-in request. '
      'Request a fresh link or code.',
    );
  }

  Future<PendingSupabaseAuth?> _loadPendingAuth() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_pendingAuthPreferenceKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Pending sign-in state is invalid.');
      }
      return PendingSupabaseAuth.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      await preferences.remove(_pendingAuthPreferenceKey);
      return null;
    }
  }

  Future<void> _clearPendingAuth() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_pendingAuthPreferenceKey);
  }

  void _clearBrowserAuthCallback() {
    final location = web.window.location;
    web.window.history.replaceState(
      null,
      web.document.title,
      location.pathname,
    );
=======
    await _adoptSession(config, session, status: 'Signed in.');
>>>>>>> origin/main
  }

  Future<void> _adoptSession(
    AppConfig config,
    SupabaseSession incoming, {
    required String status,
  }) async {
    final prior = _session;
    final session = SupabaseSession(
      accessToken: incoming.accessToken,
      refreshToken: incoming.refreshToken.isEmpty
          ? (prior?.refreshToken ?? '')
          : incoming.refreshToken,
      expiresAtUtc: incoming.expiresAtUtc,
      userId: incoming.userId.isEmpty ? (prior?.userId ?? '') : incoming.userId,
      email: incoming.email.isEmpty ? (prior?.email ?? '') : incoming.email,
    );
    if (session.userId.isEmpty) {
      throw StateError('Supabase session did not contain a user identity.');
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _config = config;
      _session = session;
      _status = status;
    });
    _realtime.connect(
      config: config,
      accessToken: session.accessToken,
      userId: session.userId,
    );
    _scheduleRefresh();
    await _connectDevices();
    await _record(
      level: 'info',
      event: 'web.session_started',
      message: 'Signed-in browser diagnostic stream started.',
    );
  }

  Future<void> _signOut() async {
    final config = _config;
    final session = _session;
    if (config != null && session != null) {
      await _auth.signOut(config: config, accessToken: session.accessToken);
    }
    _refreshTimer?.cancel();
    _deviceHeartbeatTimer?.cancel();
    _realtime.close();
    _devicePresenceClient.close();
    if (mounted) {
      setState(() {
        _session = null;
        _devices = const [];
        _presence = const DevicePresenceSnapshot();
        _status = 'Signed out. Diagnostic streaming stopped.';
      });
    }
  }

  CloudSecrets get _deviceSecrets {
    final session = _session;
    if (session == null) return const CloudSecrets();
    return CloudSecrets(
      supabaseAccessToken: session.accessToken,
      supabaseUserId: session.userId,
    );
  }

  Future<void> _connectDevices() async {
    final config = _config;
    final session = _session;
    if (config == null || session == null) return;
    var groupId = session.userId;
    try {
      groupId = (await _accountGroups.load(
        config: config,
        secrets: _deviceSecrets,
      )).groupId;
    } catch (_) {
      // Same-user device visibility still works before the group migration.
    }
    await _refreshDevices(heartbeat: true);
    _devicePresenceClient.connect(
      config: config,
      accessToken: session.accessToken,
      userId: groupId,
      deviceId: _deviceId,
      platform: 'web',
    );
    _deviceHeartbeatTimer?.cancel();
    _deviceHeartbeatTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaited(_refreshDevices(heartbeat: true)),
    );
  }

  Future<void> _refreshDevices({bool heartbeat = false}) async {
    final config = _config;
    if (config == null || _session == null) return;
    final secrets = _deviceSecrets;
    if (heartbeat) {
      await _deviceRegistry.registerOrHeartbeat(
        config: config,
        secrets: secrets,
        platform: 'web',
        role: 'viewer',
      );
    }
    final listing = await _deviceRegistry.fetchDevices(
      config: config,
      secrets: secrets,
    );
    if (!mounted) return;
    if (listing.error != null) {
      setState(() => _status = listing.error!);
      return;
    }
    final sorted = [...listing.devices]
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    setState(() => _devices = List.unmodifiable(sorted));
  }

  String _deviceStatus(interfaces.DeviceRecord device) {
    if ((device.revokedAt ?? '').trim().isNotEmpty) return 'Revoked';
    if (_presence.onlineDeviceIds.contains(device.deviceId)) return 'Online';
    final seen = DateTime.tryParse(device.lastSeenAt)?.toLocal();
    return seen == null ? 'Offline' : 'Last seen ${seen.toString()}';
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    final session = _session;
    if (session == null || session.refreshToken.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    final target = session.expiresAtUtc.subtract(const Duration(minutes: 2));
    final delay = target.isAfter(now)
        ? target.difference(now)
        : const Duration(seconds: 5);
    _refreshTimer = Timer(delay, () => unawaited(_refreshIfNeeded()));
  }

  Future<void> _refreshIfNeeded() async {
    final config = _config;
    final session = _session;
    if (config == null || session == null || session.refreshToken.isEmpty) {
      return;
    }
    if (DateTime.now().toUtc().isBefore(
      session.expiresAtUtc.subtract(const Duration(minutes: 1)),
    )) {
      _scheduleRefresh();
      return;
    }
    try {
      final refreshed = await _auth.refreshSession(
        config: config,
        refreshToken: session.refreshToken,
      );
      await _adoptSession(config, refreshed, status: 'Signed in.');
    } catch (_) {
      // Keep the page usable and retry gently; no error message includes tokens.
      _refreshTimer = Timer(
        const Duration(minutes: 1),
        () => unawaited(_refreshIfNeeded()),
      );
    }
  }

  Future<void> _record({
    required String level,
    required String event,
    required String message,
    String? stack,
  }) async {
    final config = _config;
    final session = _session;
    if (config == null || session == null) {
      return;
    }
    final eventId = const Uuid().v4();
    final telemetry = ClientTelemetryEvent(
      clientEventId: eventId,
      level: level,
      event: event,
      message: message,
      stack: stack,
      occurredAtUtc: DateTime.now().toUtc(),
      platform: 'web',
      sessionId: _sessionId,
      source: 'web',
      transport: 'rest_outbox+realtime_broadcast',
      traceId: _sessionId,
      spanId: eventId,
      details: const {'surface': 'flutter_web'},
    );
    final secrets = CloudSecrets(
      supabaseAccessToken: session.accessToken,
      supabaseUserId: session.userId,
    );
    _realtime.publish(
      _rest.toOrganizationTelemetryEntry(
        _rest.sanitizeTelemetryRow(telemetry.toSupabaseRow(config.deviceId)),
      ),
    );
    final ingestError = await _rest.insertTelemetry(
      config: config,
      secrets: secrets,
      events: [telemetry],
    );
    if (ingestError == null) {
      unawaited(
        _rest.insertTelemetrySnapshot(
          config: config,
          secrets: secrets,
          events: [telemetry],
          trigger: level == 'error' || level == 'fatal' ? 'error' : 'interval',
          context: const {'surface': 'flutter_web'},
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _session != null;
    return MaterialApp(
      title: 'Sonus Auris Web',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF167D56)),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Sonus Auris'),
          actions: [
            if (signedIn)
              TextButton.icon(
                onPressed: () => unawaited(_signOut()),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Account & diagnostics',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Browser access is account-only. Audio capture stays in the native apps, '
                  'while signed-in web errors and diagnostics stream to your RLS-scoped '
                  'Supabase telemetry table and live Realtime channel.',
                ),
                const SizedBox(height: 20),
                if (!signedIn)
                  SupabaseAuthForm(
                    emailController: _email,
<<<<<<< HEAD
                    supabaseUrlController: _supabaseUrl,
                    supabaseAnonKeyController: _supabaseKey,
                    showProjectConfiguration: true,
                    onSendMagicLink: _sendMagicLink,
                    onVerifyCode: _verifyEmailCode,
=======
                    codeController: _code,
                    supabaseUrlController: _supabaseUrl,
                    supabaseAnonKeyController: _supabaseKey,
                    showProjectConfiguration: true,
                    onRequestCode: _requestCode,
                    onSubmitCode: _submitCode,
>>>>>>> origin/main
                  )
                else ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _session!.email,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Live diagnostic broadcast: connected when Realtime is available.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Devices',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh devices',
                        onPressed: () => unawaited(_refreshDevices()),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const Text(
                    'Realtime presence is the primary online signal; the last-seen time remains available when a device is background-throttled.',
                  ),
                  const SizedBox(height: 8),
                  if (_devices.isEmpty)
                    const Card(
                      child: ListTile(title: Text('No registered devices')),
                    )
                  else
                    for (final device in _devices)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            device.role == 'viewer'
                                ? Icons.visibility_outlined
                                : Icons.mic_outlined,
                          ),
                          title: Text(device.displayName),
                          subtitle: Text(
                            '${_deviceStatus(device)} · ${device.platform} · ${device.role}',
                          ),
                        ),
                      ),
                ],
                const SizedBox(height: 16),
                Semantics(liveRegion: true, child: Text(_status)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
