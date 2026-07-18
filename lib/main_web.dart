// Browser entrypoint for the Sonus Auris account and diagnostic surface.
//
// The audio recorder deliberately remains native-only: browser microphones do
// not provide the background-capture and encrypted local-file guarantees of the
// Android, iOS, and desktop clients. This surface still uses the same Supabase
// authentication, redaction, durable telemetry, and Realtime Broadcast protocol
// as every signed-in client.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'src/models/app_config.dart';
import 'src/models/client_telemetry_event.dart';
import 'src/models/cloud_secrets.dart';
import 'src/models/supabase_session.dart';
import 'src/services/supabase_auth_client.dart';
import 'src/services/supabase_rest_client.dart';
import 'src/services/supabase_telemetry_realtime_client.dart';
import 'src/widgets/supabase_auth_form.dart';

const _authRedirectUrl = String.fromEnvironment(
  'SONUS_SUPABASE_AUTH_REDIRECT_URL',
);

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
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _supabaseUrl = TextEditingController(
    text: AppConfig.defaultSupabaseUrl,
  );
  final _supabaseKey = TextEditingController(
    text: AppConfig.defaultSupabaseAnonKey,
  );
  final _deviceId = 'web-${const Uuid().v4()}';
  final _sessionId = const Uuid().v4();

  AppConfig? _config;
  SupabaseSession? _session;
  Timer? _refreshTimer;
  FlutterExceptionHandler? _previousFlutterOnError;
  ui.ErrorCallback? _previousPlatformOnError;
  String _status = 'Sign in to enable account-scoped diagnostic streaming.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _realtime.close();
    _auth.close();
    _rest.close();
    _email.dispose();
    _password.dispose();
    _supabaseUrl.dispose();
    _supabaseKey.dispose();
    super.dispose();
  }

  AppConfig _currentConfig() => AppConfig(
    deviceId: _deviceId,
    supabaseUrl: _supabaseUrl.text.trim(),
    supabaseAnonKey: _supabaseKey.text.trim(),
  );

  Future<void> _signIn(String email, String password) async {
    final config = _currentConfig();
    final session = await _auth.signInWithPassword(
      config: config,
      email: email,
      password: password,
    );
    await _adoptSession(config, session, status: 'Signed in.');
  }

  Future<void> _signUp(String email, String password) async {
    final config = _currentConfig();
    final session = await _auth.signUp(
      config: config,
      email: email,
      password: password,
    );
    if (session == null) {
      if (mounted) {
        setState(() {
          _config = config;
          _status = 'Account created. Confirm the email, then sign in.';
        });
      }
      return;
    }
    await _adoptSession(
      config,
      session,
      status: 'Account created and signed in.',
    );
  }

  Future<void> _resetPassword(String email) async {
    final config = _currentConfig();
    await _auth.sendPasswordResetEmail(
      config: config,
      email: email,
      redirectTo: _authRedirectUrl,
    );
    if (mounted) {
      setState(() => _status = 'Password-reset email sent.');
    }
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
    _realtime.close();
    if (mounted) {
      setState(() {
        _session = null;
        _status = 'Signed out. Diagnostic streaming stopped.';
      });
    }
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
                    passwordController: _password,
                    supabaseUrlController: _supabaseUrl,
                    supabaseAnonKeyController: _supabaseKey,
                    showProjectConfiguration: true,
                    onSignIn: _signIn,
                    onSignUp: _signUp,
                    onPasswordReset: _resetPassword,
                  )
                else
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
                Semantics(liveRegion: true, child: Text(_status)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
