// Mobile entrypoint: boots Flutter, wires up the AppController and services, and runs the Sonus Auris app UI.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
// `show DateFormat` so intl's TextDirection enum doesn't shadow dart:ui's.
import 'package:intl/intl.dart' show DateFormat;
import 'package:url_launcher/url_launcher.dart';

import 'src/app/app_controller.dart';
import 'src/app/app_view_model.dart';
import 'src/platform/form_factor.dart';
import 'src/models/acoustic_detection.dart';
import 'src/models/app_config.dart';
import 'src/models/cloud_connection.dart';
import 'src/models/cloud_provider.dart';
import 'src/models/consent.dart';
import 'src/models/context_trigger.dart';
import 'src/models/recording_schedule.dart';
import 'src/models/storage_estimate.dart';
import 'src/models/transfer_gate_status.dart';
import 'src/models/upload_network_policy.dart';
import 'src/services/voice_id/voice_profile_service.dart';
import 'src/theme/sonus_brand.dart';
import 'src/theme/sonus_theme.dart';
import 'src/widgets/supabase_auth_form.dart';

const String _privacyPolicyUrl = 'https://sonusauris.app/privacy/';
const String _accountDeletionUrl = 'https://sonusauris.app/account-deletion/';
const String _supportUrl = 'https://sonusauris.app/support/';

Future<void> _openPublicPage(BuildContext context, String url) async {
  final opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the Sonus Auris website.')),
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }
  // Native alarm-manager readiness is owned by PluginSchedulePlatform's
  // bounded gate. Never hold the first Flutter frame behind a plugin channel:
  // Android services can legitimately lag just after a cold reboot.
  runApp(const AudioDashcamRoot());
}

class AudioDashcamRoot extends StatefulWidget {
  const AudioDashcamRoot({
    super.key,
    this.controllerFactory,
    this.controllerBootstrapDelay = Duration.zero,
  });

  final AppController Function()? controllerFactory;
  final Duration controllerBootstrapDelay;

  @override
  State<AudioDashcamRoot> createState() => _AudioDashcamRootState();
}

class _AudioDashcamRootState extends State<AudioDashcamRoot>
    with WidgetsBindingObserver {
  Timer? _controllerBootstrapTimer;
  AppController? _controller;
  Future<void>? _initFuture;
  Object? _startupError;
  FlutterExceptionHandler? _previousFlutterOnError;
  ui.ErrorCallback? _previousPlatformOnError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Build and submit the branded loading frame before constructing plugin-
    // backed services. A zero-delay event from a post-frame callback guarantees
    // this frame can leave the Dart UI isolate first, even when Android is still
    // bringing native services online after a reboot.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _controllerBootstrapTimer = Timer(
        widget.controllerBootstrapDelay,
        _startController,
      );
    });
  }

  void _startController() {
    if (!mounted || _controller != null) {
      return;
    }
    try {
      final controller = widget.controllerFactory?.call() ?? AppController();
      _controller = controller;
      _installTelemetryErrorHooks(controller);
      final initFuture = controller.init();
      if (!mounted) {
        unawaited(controller.dispose());
        return;
      }
      setState(() {
        _initFuture = initFuture;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _startupError = error;
        });
      }
    }
  }

  void _installTelemetryErrorHooks(AppController controller) {
    _previousFlutterOnError ??= FlutterError.onError;
    FlutterError.onError = (details) {
      controller.recordFlutterError(details);
      _previousFlutterOnError?.call(details);
    };
    _previousPlatformOnError ??= ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      controller.recordUnhandledError(
        error,
        stack,
        event: 'platform_dispatcher_error',
      );
      return _previousPlatformOnError?.call(error, stack) ?? false;
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controllerBootstrapTimer?.cancel();
    if (_previousFlutterOnError != null) {
      FlutterError.onError = _previousFlutterOnError;
    }
    if (_previousPlatformOnError != null) {
      ui.PlatformDispatcher.instance.onError = _previousPlatformOnError;
    }
    final controller = _controller;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final controller = _controller;
      if (controller != null) {
        unawaited(controller.refreshSupabaseSessionForAppResume());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Sonus Auris',
        debugShowCheckedModeBanner: false,
        theme: buildSonusTheme(),
        home: _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    final startupError = _startupError;
    if (startupError != null) {
      return ErrorPage(error: startupError.toString());
    }
    final controller = _controller;
    final initFuture = _initFuture;
    if (controller == null || initFuture == null) {
      return const LoadingPage();
    }
    return FutureBuilder<void>(
      future: initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingPage();
        }
        if (snapshot.hasError) {
          return ErrorPage(error: snapshot.error.toString());
        }
        // Gate the app behind onboarding/consent until it's completed for the
        // current consent version.
        return ValueListenableBuilder<bool>(
          valueListenable: controller.onboardingComplete,
          builder: (context, complete, _) => complete
              ? SettingsPage(controller: controller)
              : OnboardingFlow(controller: controller),
        );
      },
    );
  }
}

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SonusColors.paper,
      body: Semantics(
        label: 'Loading Sonus Auris',
        liveRegion: true,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SonusLogoMark(size: 64),
              SizedBox(height: 22),
              Text(
                'Sonus Auris',
                style: TextStyle(
                  fontFamily: kSonusFontFamily,
                  color: SonusColors.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                  letterSpacing: -0.3,
                ),
              ),
              SizedBox(height: 18),
              SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorPage extends StatelessWidget {
  const ErrorPage({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonusWordmark()),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(error, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

/// First-run onboarding: welcome → Supabase account (built-in auth) → granular
/// data-capture consent → OS permission requests. Blocks the main app until the
/// user accepts the required consents; the accepted [ConsentRecord] is stored
/// locally and synced to Supabase.
class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, required this.controller});

  final AppController controller;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  int _step = 0;
  bool _busy = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _supabaseUrlController = TextEditingController();
  final _supabaseAnonKeyController = TextEditingController();
  bool _supabaseProjectSeeded = false;
  late final Map<ConsentItem, bool> _grants = {
    for (final item in ConsentItem.values) item: item.required,
  };

  static const int _lastStep = 3;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _supabaseUrlController.dispose();
    _supabaseAnonKeyController.dispose();
    super.dispose();
  }

  bool get _requiredAccepted =>
      ConsentItem.values.where((i) => i.required).every((i) => _grants[i]!);

  Future<void> _auth(Future<void> Function() run) async {
    setState(() => _busy = true);
    try {
      await run();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final record = ConsentRecord(
      consentVersion: kConsentVersion,
      acceptedAtUtc: DateTime.now().toUtc(),
      platform: Platform.isAndroid
          ? 'android'
          : Platform.isIOS
          ? 'ios'
          : Platform.operatingSystem,
      grants: {for (final e in _grants.entries) e.key.key: e.value},
    );
    await widget.controller.completeOnboarding(record);
    // The root's ValueListenableBuilder swaps to the main app once complete.
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppViewModel>(
      stream: widget.controller.viewModels,
      builder: (context, snapshot) {
        final vm = snapshot.data;
        _seedSupabaseProject(vm);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const SonusWordmark(),
            automaticallyImplyLeading: false,
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    _ProgressDots(step: _step, total: _lastStep + 1),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        children: [_buildStep(context, vm)],
                      ),
                    ),
                    if (vm?.message != null)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            vm!.message!,
                            style: const TextStyle(color: SonusColors.inkSoft),
                          ),
                        ),
                      ),
                    _buildNav(vm),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStep(BuildContext context, AppViewModel? vm) {
    switch (_step) {
      case 1:
        return _accountStep(vm);
      case 2:
        return _consentStep(context);
      case 3:
        return _permissionsStep();
      default:
        return _welcomeStep(context);
    }
  }

  Widget _welcomeStep(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Icon(Icons.hearing, size: 48, color: SonusColors.orange500),
        const SizedBox(height: 16),
        Text('Welcome to Sonus Auris', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Text(
          'Sonus Auris keeps a rolling, on-device audio buffer and can analyze '
          'it privately — snoring, sleep cycles, and more. Audio is encrypted on '
          'your device before anything is backed up.\n\n'
          "Next we'll create your account and ask permission for exactly the "
          'data the app captures. You stay in control of every item.',
          style: TextStyle(color: SonusColors.inkSoft, height: 1.4),
        ),
      ],
    );
  }

  Widget _accountStep(AppViewModel? vm) {
    final theme = Theme.of(context);
    final signedIn = vm?.isSignedIn ?? false;
    final configured =
        (vm?.hasSupabaseAuthConfig ?? false) &&
        validateSupabaseAnonKey(vm?.config.supabaseAnonKey) == null;
    if (signedIn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Icon(
            Icons.verified_user,
            size: 40,
            color: SonusColors.orange500,
          ),
          const SizedBox(height: 12),
          Text('Signed in', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Signed in as ${vm?.signedInEmail ?? 'your account'}. Your consent '
            'will be saved to your account.',
            style: const TextStyle(color: SonusColors.inkSoft),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Create your account', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Sign up or sign in to securely store your settings and consent.',
          style: TextStyle(color: SonusColors.inkSoft),
        ),
        const SizedBox(height: 16),
        SupabaseAuthForm(
          emailController: _emailController,
          passwordController: _passwordController,
          supabaseUrlController: _supabaseUrlController,
          supabaseAnonKeyController: _supabaseAnonKeyController,
          showProjectConfiguration: !configured,
          enabled: !_busy && vm != null,
          onSignIn: (email, password) =>
              _auth(() => _signIn(vm, email, password)),
          onSignUp: (email, password) =>
              _auth(() => _signUp(vm, email, password)),
          onPasswordReset: (email) => _auth(() => _resetPassword(vm, email)),
        ),
      ],
    );
  }

  void _seedSupabaseProject(AppViewModel? viewModel) {
    if (_supabaseProjectSeeded || viewModel == null) {
      return;
    }
    _supabaseUrlController.text = viewModel.config.supabaseUrl;
    _supabaseAnonKeyController.text = viewModel.config.supabaseAnonKey;
    _supabaseProjectSeeded = true;
  }

  Future<void> _saveSupabaseProject(AppViewModel viewModel) {
    return widget.controller.saveConfig(
      viewModel.config.copyWith(
        supabaseUrl: _supabaseUrlController.text.trim(),
        supabaseAnonKey: _supabaseAnonKeyController.text.trim(),
      ),
    );
  }

  Future<void> _signUp(
    AppViewModel? viewModel,
    String email,
    String password,
  ) async {
    if (viewModel == null) {
      return;
    }
    await _saveSupabaseProject(viewModel);
    await widget.controller.signUpWithSupabase(
      email: email,
      password: password,
    );
  }

  Future<void> _signIn(
    AppViewModel? viewModel,
    String email,
    String password,
  ) async {
    if (viewModel == null) {
      return;
    }
    await _saveSupabaseProject(viewModel);
    await widget.controller.signInWithSupabase(
      email: email,
      password: password,
    );
  }

  Future<void> _resetPassword(AppViewModel? viewModel, String email) async {
    if (viewModel == null) {
      return;
    }
    await _saveSupabaseProject(viewModel);
    await widget.controller.sendSupabasePasswordReset(email: email);
  }

  Widget _consentStep(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('What you consent to', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Choose what Sonus Auris may capture. Required items keep the core '
          'recorder working; everything else is optional and off by default.',
          style: TextStyle(color: SonusColors.inkSoft),
        ),
        const SizedBox(height: 12),
        const _RecordingDisclosure(),
        const SizedBox(height: 8),
        for (final item in ConsentItem.values)
          Card(
            elevation: 0,
            color: SonusColors.green50,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: SwitchListTile(
              title: Text(
                item.required ? '${item.title} (required)' : item.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(item.rationale),
              isThreeLine: true,
              value: _grants[item]!,
              onChanged: item.required
                  ? null
                  : (v) => setState(() => _grants[item] = v),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => _openPublicPage(context, _privacyPolicyUrl),
              icon: const Icon(Icons.privacy_tip_outlined),
              label: const Text('Privacy policy'),
            ),
            TextButton.icon(
              onPressed: () => _openPublicPage(context, _accountDeletionUrl),
              icon: const Icon(Icons.manage_accounts_outlined),
              label: const Text('Account & data deletion'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _permissionsStep() {
    final theme = Theme.of(context);
    final granted = ConsentItem.values
        .where((i) => _grants[i]!)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('Device permissions', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          "When you finish, your device will ask for the permissions behind the "
          'items you allowed. You can change any of these later in Settings or '
          "your phone's settings.",
          style: TextStyle(color: SonusColors.inkSoft),
        ),
        const SizedBox(height: 12),
        for (final item in granted)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 18,
                  color: SonusColors.orange500,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(item.title)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildNav(AppViewModel? vm) {
    final isLast = _step == _lastStep;
    final onAccountStep = _step == 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_step > 0)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step -= 1),
              child: const Text('Back'),
            ),
          if (onAccountStep && !(vm?.isSignedIn ?? false))
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step += 1),
              child: const Text('Skip for now'),
            ),
          FilledButton(
            onPressed: _busy || (_step == 2 && !_requiredAccepted)
                ? null
                : () {
                    if (isLast) {
                      _finish();
                    } else {
                      setState(() => _step += 1);
                    }
                  },
            child: Text(isLast ? 'Finish' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Onboarding step ${step + 1} of $total',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < total; i++)
                Container(
                  width: i == step ? 22 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i <= step
                        ? SonusColors.orange500
                        : SonusColors.hairline,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingDisclosure extends StatelessWidget {
  const _RecordingDisclosure();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Important recording disclosure',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFFFF5EA),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: SonusColors.orange200),
        ),
        child: const Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.mic_outlined, color: SonusColors.orange600),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Recording begins only after you tap Start, accept a prompt, '
                  'or arm a schedule. Once active, it can continue in the '
                  'background or while your phone is locked until you stop it '
                  'or the scheduled window ends. Your phone always shows its '
                  'system recording indicator or persistent notification.',
                  style: TextStyle(color: SonusColors.ink, height: 1.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _deviceRetentionController = TextEditingController();
  final _cloudRetentionController = TextEditingController();
  final _segmentMinutesController = TextEditingController();
  final _overlapSecondsController = TextEditingController();
  final _sampleRateController = TextEditingController();
  final _channelsController = TextEditingController();
  final _backendUrlController = TextEditingController();
  final _backendDeviceTokenController = TextEditingController();
  final _s3BucketController = TextEditingController();
  final _s3RegionController = TextEditingController();
  final _s3PrefixController = TextEditingController();
  final _s3EndpointController = TextEditingController();
  final _s3AccessKeyController = TextEditingController();
  final _s3SecretKeyController = TextEditingController();
  final _s3SessionTokenController = TextEditingController();
  final _supabaseUrlController = TextEditingController();
  final _supabaseAnonKeyController = TextEditingController();
  final _sttApiKeyController = TextEditingController();

  String? _syncedDeviceId;
  CloudProvider _selectedProvider = CloudProvider.s3;
  bool _uploadEnabled = true;
  int _selectedIndex = 0;

  /// Persisted so an OS-kill + relaunch (e.g. the low-memory killer reclaiming
  /// the backgrounded app, which `flutter_foreground_task` then restarts) lands
  /// back on the tab you were last on instead of resetting to Home.
  static const _kLastTabKey = 'last_tab_index';

  @override
  void initState() {
    super.initState();
    _restoreSelectedTab();
  }

  Future<void> _restoreSelectedTab() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_kLastTabKey);
    if (saved != null && saved >= 0 && saved <= 2 && mounted) {
      setState(() => _selectedIndex = saved);
    }
  }

  Future<void> _persistSelectedTab(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastTabKey, index);
  }

  @override
  void dispose() {
    for (final controller in [
      _deviceRetentionController,
      _cloudRetentionController,
      _segmentMinutesController,
      _overlapSecondsController,
      _sampleRateController,
      _channelsController,
      _backendUrlController,
      _backendDeviceTokenController,
      _s3BucketController,
      _s3RegionController,
      _s3PrefixController,
      _s3EndpointController,
      _s3AccessKeyController,
      _s3SecretKeyController,
      _s3SessionTokenController,
      _supabaseUrlController,
      _supabaseAnonKeyController,
      _sttApiKeyController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppViewModel>(
      stream: widget.controller.viewModels,
      builder: (context, snapshot) {
        final viewModel = snapshot.data;
        if (viewModel == null || viewModel.isInitializing) {
          return const LoadingPage();
        }
        _syncForm(viewModel);
        final useNavigationRail = MediaQuery.sizeOf(context).width >= 840;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: const SonusWordmark(),
            actions: [
              IconButton(
                tooltip: 'Retry uploads',
                onPressed: viewModel.isUploading
                    ? null
                    : widget.controller.requestUploadDrain,
                icon: const Icon(Icons.cloud_sync),
              ),
            ],
          ),
          body: SafeArea(
            child: Row(
              children: [
                if (useNavigationRail)
                  _TopLevelNavigationRail(
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: _selectDestination,
                  ),
                Expanded(
                  child: Column(
                    children: [
                      if (viewModel.message != null)
                        Semantics(
                          liveRegion: true,
                          child: MaterialBanner(
                            content: Text(viewModel.message!),
                            leading: const Icon(Icons.info_outline),
                            actions: [
                              TextButton(
                                onPressed: widget.controller.clearMessage,
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ),
                        ),
                      // Context-trigger consent: a meaningful event fired inside
                      // a scheduled window while idle — ask before recording.
                      if (viewModel.consentRequest != null)
                        MaterialBanner(
                          backgroundColor: SonusColors.green50,
                          content: Text(
                            '${viewModel.consentRequest!.event.description} during '
                            'your recording window. Start recording?',
                          ),
                          leading: const Icon(
                            Icons.fiber_manual_record,
                            color: SonusColors.orange500,
                          ),
                          actions: [
                            TextButton(
                              onPressed:
                                  widget.controller.dismissContextConsent,
                              child: const Text('Not now'),
                            ),
                            FilledButton(
                              onPressed: widget.controller.acceptContextConsent,
                              child: const Text('Start recording'),
                            ),
                          ],
                        ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: Platforms.isDesktop
                                  ? Platforms.desktopContentMaxWidth
                                  : 1040,
                            ),
                            child: _selectedBody(viewModel),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: useNavigationRail
              ? null
              : NavigationBar(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _selectDestination,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard),
                      label: 'Home',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.graphic_eq_outlined),
                      selectedIcon: Icon(Icons.graphic_eq),
                      label: 'Playback',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.tune_outlined),
                      selectedIcon: Icon(Icons.tune),
                      label: 'Configure',
                    ),
                  ],
                ),
        );
      },
    );
  }

  void _selectDestination(int index) {
    setState(() => _selectedIndex = index);
    _persistSelectedTab(index);
  }

  Widget _selectedBody(AppViewModel viewModel) {
    switch (_selectedIndex) {
      case 1:
        return _PlaybackView(
          viewModel: viewModel,
          onPlay: widget.controller.playLocalWindow,
          onPausePlayback: widget.controller.pausePlayback,
          onStopPlayback: widget.controller.stopPlayback,
          onSendAlert: widget.controller.sendManualAlert,
          earliestLocalUtc: widget.controller.earliestLocalSegmentUtc,
          onPlayRange: (startUtc, endUtc, loop) => widget.controller.playRange(
            startUtc: startUtc,
            endUtc: endUtc,
            loop: loop,
          ),
          onSaveRangePermanently: (startedAtUtc, endedAtUtc) =>
              widget.controller.saveRangePermanently(
                startedAtUtc: startedAtUtc,
                endedAtUtc: endedAtUtc,
              ),
        );
      case 2:
        return Form(
          key: _formKey,
          child: _ConfigureView(
            viewModel: viewModel,
            accountSection: _AccountSection(
              isSignedIn: viewModel.isSignedIn,
              signedInEmail: viewModel.signedInEmail,
              isDeviceRegistered: viewModel.isDeviceRegistered,
              isAwaitingDeviceRegistration:
                  viewModel.isAwaitingDeviceRegistration,
              supabaseUrlController: _supabaseUrlController,
              supabaseAnonKeyController: _supabaseAnonKeyController,
              onSignIn: (email, password) =>
                  _signIn(viewModel, email, password),
              onSignUp: (email, password) =>
                  _signUp(viewModel, email, password),
              onPasswordReset: (email) => _resetPassword(viewModel, email),
              onSignOut: widget.controller.signOutSupabase,
              onDeleteAccount: widget.controller.deleteAccount,
            ),
            selectedProvider: _selectedProvider,
            uploadEnabled: _uploadEnabled,
            onUploadEnabledChanged: (value) =>
                setState(() => _uploadEnabled = value),
            onProviderChanged: (provider) =>
                setState(() => _selectedProvider = provider),
            onSave: () => _save(viewModel),
            onAudioConfigChanged: (updated) =>
                widget.controller.saveConfig(updated),
            controller: widget.controller,
            deviceRetentionController: _deviceRetentionController,
            cloudRetentionController: _cloudRetentionController,
            segmentMinutesController: _segmentMinutesController,
            overlapSecondsController: _overlapSecondsController,
            sampleRateController: _sampleRateController,
            channelsController: _channelsController,
            backendUrlController: _backendUrlController,
            backendDeviceTokenController: _backendDeviceTokenController,
            s3BucketController: _s3BucketController,
            s3RegionController: _s3RegionController,
            s3PrefixController: _s3PrefixController,
            s3EndpointController: _s3EndpointController,
            s3AccessKeyController: _s3AccessKeyController,
            s3SecretKeyController: _s3SecretKeyController,
            s3SessionTokenController: _s3SessionTokenController,
            sttApiKeyController: _sttApiKeyController,
          ),
        );
      default:
        return _HomeView(
          viewModel: viewModel,
          onStart: widget.controller.startRecording,
          onStop: widget.controller.stopRecording,
          onRestart: widget.controller.restartRecording,
          onToggleHighQuality: widget.controller.toggleHighQualityRecording,
          onSendAlert: widget.controller.sendManualAlert,
          onConfirm: widget.controller.confirmRecording,
        );
    }
  }

  void _syncForm(AppViewModel viewModel) {
    if (_syncedDeviceId == viewModel.config.deviceId) {
      return;
    }
    final config = viewModel.config;
    final secrets = viewModel.secrets;
    _deviceRetentionController.text = config.deviceRetentionHours.toString();
    _cloudRetentionController.text = config.cloudRetentionHours.toString();
    _segmentMinutesController.text = config.segmentMinutes.toString();
    _overlapSecondsController.text = config.overlapSeconds.toString();
    _sampleRateController.text = config.sampleRate.toString();
    _channelsController.text = config.channels.toString();
    _backendUrlController.text = config.backendBaseUrl;
    _backendDeviceTokenController.text = secrets.backendDeviceToken;
    _s3BucketController.text = config.s3Bucket;
    _s3RegionController.text = config.s3Region;
    _s3PrefixController.text = config.s3Prefix;
    _s3EndpointController.text = config.s3Endpoint;
    _s3AccessKeyController.text = secrets.s3AccessKeyId;
    _s3SecretKeyController.text = secrets.s3SecretAccessKey;
    _s3SessionTokenController.text = secrets.s3SessionToken;
    _supabaseUrlController.text = config.supabaseUrl;
    _supabaseAnonKeyController.text = config.supabaseAnonKey;
    _sttApiKeyController.text = secrets.sttApiKey;
    _selectedProvider = config.cloudProvider;
    _uploadEnabled = config.uploadEnabled;
    _syncedDeviceId = config.deviceId;
  }

  Future<void> _save(AppViewModel viewModel) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final config = viewModel.config.copyWith(
      deviceRetentionHours: _parseInt(_deviceRetentionController.text, 50),
      cloudRetentionHours: _parseInt(_cloudRetentionController.text, 500),
      segmentMinutes: _parseInt(_segmentMinutesController.text, 1),
      overlapSeconds: _parseInt(_overlapSecondsController.text, 2),
      sampleRate: _parseInt(_sampleRateController.text, 16000),
      channels: _parseInt(_channelsController.text, 1),
      uploadEnabled: _uploadEnabled,
      cloudProvider: _selectedProvider,
      backendBaseUrl: _backendUrlController.text,
      s3Bucket: _s3BucketController.text,
      s3Region: _s3RegionController.text,
      s3Prefix: _s3PrefixController.text,
      s3Endpoint: _s3EndpointController.text,
      supabaseUrl: _supabaseUrlController.text.trim(),
      supabaseAnonKey: _supabaseAnonKeyController.text.trim(),
    );
    // copyWith preserves the Supabase session fields (access/refresh/expiry/
    // email) that have no form field, so saving settings never erases identity.
    final secrets = viewModel.secrets.copyWith(
      s3AccessKeyId: _s3AccessKeyController.text,
      s3SecretAccessKey: _s3SecretKeyController.text,
      s3SessionToken: _s3SessionTokenController.text,
      backendDeviceToken: _backendDeviceTokenController.text,
      sttApiKey: _sttApiKeyController.text,
    );
    await widget.controller.saveConfig(config);
    await widget.controller.saveSecrets(secrets);
    _syncedDeviceId = null;
  }

  Future<void> _persistSupabaseConfig(AppViewModel viewModel) async {
    await widget.controller.saveConfig(
      viewModel.config.copyWith(
        supabaseUrl: _supabaseUrlController.text.trim(),
        supabaseAnonKey: _supabaseAnonKeyController.text.trim(),
      ),
    );
  }

  Future<void> _signIn(
    AppViewModel viewModel,
    String email,
    String password,
  ) async {
    await _persistSupabaseConfig(viewModel);
    await widget.controller.signInWithSupabase(
      email: email,
      password: password,
    );
  }

  Future<void> _signUp(
    AppViewModel viewModel,
    String email,
    String password,
  ) async {
    await _persistSupabaseConfig(viewModel);
    await widget.controller.signUpWithSupabase(
      email: email,
      password: password,
    );
  }

  Future<void> _resetPassword(AppViewModel viewModel, String email) async {
    await _persistSupabaseConfig(viewModel);
    await widget.controller.sendSupabasePasswordReset(email: email);
  }

  int _parseInt(String value, int fallback) {
    return int.tryParse(value.trim()) ?? fallback;
  }
}

class _TopLevelNavigationRail extends StatelessWidget {
  const _TopLevelNavigationRail({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        labelType: NavigationRailLabelType.all,
        groupAlignment: -0.72,
        useIndicator: true,
        destinations: const [
          NavigationRailDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: Text('Home'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq),
            label: Text('Playback'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: Text('Configure'),
          ),
        ],
      ),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView({
    required this.viewModel,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onToggleHighQuality,
    required this.onSendAlert,
    required this.onConfirm,
  });

  final AppViewModel viewModel;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onToggleHighQuality;
  final VoidCallback onSendAlert;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _PageHeader(
          eyebrow: 'Overview',
          title: 'Your audio timeline',
          description:
              'Monitor capture health, local retention, and cloud transfer at a glance.',
          icon: Icons.dashboard_outlined,
        ),
        const SizedBox(height: 16),
        if (!viewModel.isSignedIn) ...[
          const _SignInNotice(),
          const SizedBox(height: 12),
        ],
        _StatusSection(
          viewModel: viewModel,
          onStart: onStart,
          onStop: onStop,
          onRestart: onRestart,
          onToggleHighQuality: onToggleHighQuality,
          onSendAlert: onSendAlert,
        ),
        if (viewModel.isUploadGatePaused) ...[
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: SonusColors.orange200.withValues(alpha: 0.45),
              border: Border.all(color: SonusColors.orange400),
              borderRadius: BorderRadius.circular(20),
            ),
            child: ListTile(
              leading: const Icon(
                Icons.cloud_off,
                color: SonusColors.orange600,
              ),
              title: Text(
                '${viewModel.pendingUploads} segment(s) waiting to upload',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: SonusColors.ink,
                ),
              ),
              subtitle: Text(
                viewModel.transferStatus.detail ??
                    'Uploads are paused. Recording continues on device.',
                style: const TextStyle(color: SonusColors.inkSoft),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onConfirm,
          icon: const Icon(Icons.verified_outlined),
          label: const Text("Confirm it's working"),
        ),
        if (viewModel.config.acousticAnalysisEnabled) ...[
          const SizedBox(height: 16),
          _DetectionsSection(detections: viewModel.detections),
        ],
        const SizedBox(height: 16),
        _DiagnosticsSection(entries: viewModel.diagnosticEntries),
      ],
    );
  }
}

/// Lists recent on-device acoustic detections, including conservative safety
/// sound patterns. Newest first.
class _DetectionsSection extends StatelessWidget {
  const _DetectionsSection({required this.detections});

  final List<AcousticDetection> detections;

  IconData _icon(AcousticDetectionKind kind) {
    switch (kind) {
      case AcousticDetectionKind.snore:
        return Icons.bedtime;
      case AcousticDetectionKind.apneaPattern:
        return Icons.warning_amber;
      case AcousticDetectionKind.sleepCycle:
        return Icons.nights_stay;
      case AcousticDetectionKind.sleepCycleAlarm:
        return Icons.alarm;
      case AcousticDetectionKind.music:
        return Icons.music_note;
      case AcousticDetectionKind.speech:
        return Icons.record_voice_over;
      case AcousticDetectionKind.suddenLoudNoise:
        return Icons.notification_important_outlined;
      case AcousticDetectionKind.raisedVoice:
        return Icons.campaign_outlined;
      case AcousticDetectionKind.possibleArgumentPattern:
        return Icons.groups_outlined;
      case AcousticDetectionKind.keyword:
        return Icons.flag;
    }
  }

  String _subtitle(AcousticDetection d) {
    final time = d.startedAtUtc.toLocal().toString().split('.').first;
    switch (d.kind) {
      case AcousticDetectionKind.music:
        final title = d.details['title'];
        final artist = d.details['artist'];
        if (title is String && title.isNotEmpty) {
          return '$time · $title${artist is String && artist.isNotEmpty ? ' — $artist' : ''}';
        }
        return '$time · music detected';
      case AcousticDetectionKind.keyword:
        return '$time · "${d.details['keyword'] ?? ''}"';
      case AcousticDetectionKind.apneaPattern:
        return '$time · gap ${d.details['gapSeconds'] ?? '?'}s (not a diagnosis)';
      case AcousticDetectionKind.sleepCycle:
        return '$time · cycle ${d.details['cycleIndex'] ?? '?'} · ${d.details['estimatedCycleMinutes'] ?? '?'} min';
      case AcousticDetectionKind.sleepCycleAlarm:
        return '$time · wake after cycle ${d.details['cycleIndex'] ?? '?'}';
      case AcousticDetectionKind.suddenLoudNoise:
        return '$time · ${d.details['db'] ?? '?'} dBFS · sudden onset';
      case AcousticDetectionKind.raisedVoice:
        return '$time · max ${d.details['maxDb'] ?? '?'} dBFS · heuristic';
      case AcousticDetectionKind.possibleArgumentPattern:
        return '$time · ${d.details['raisedVoiceBursts'] ?? '?'} raised-voice bursts · not proof';
      default:
        return time;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Acoustic detections',
      icon: Icons.hearing_outlined,
      child: detections.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No detections yet. Sustained sound or a sudden transient can activate the engine.',
              ),
            )
          : Column(
              children: [
                for (final d in detections.take(20))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(_icon(d.kind)),
                    title: Text(d.kind.label),
                    subtitle: Text(_subtitle(d)),
                    trailing: Text('${(d.confidence * 100).round()}%'),
                  ),
              ],
            ),
    );
  }
}

class _PlaybackView extends StatefulWidget {
  const _PlaybackView({
    required this.viewModel,
    required this.onPlay,
    required this.onPausePlayback,
    required this.onStopPlayback,
    required this.onSendAlert,
    required this.earliestLocalUtc,
    required this.onPlayRange,
    required this.onSaveRangePermanently,
  });

  final AppViewModel viewModel;
  final VoidCallback onPlay;
  final VoidCallback onPausePlayback;
  final VoidCallback onStopPlayback;
  final VoidCallback onSendAlert;

  /// Earliest local audio available, for clamping the range picker.
  final DateTime? earliestLocalUtc;

  /// Play a chosen wall-clock window (loop optional) across the rolling buffer.
  final void Function(DateTime startUtc, DateTime endUtc, bool loop)
  onPlayRange;
  final Future<void> Function(DateTime startedAtUtc, DateTime endedAtUtc)
  onSaveRangePermanently;

  @override
  State<_PlaybackView> createState() => _PlaybackViewState();
}

class _PlaybackViewState extends State<_PlaybackView> {
  final _saveStartController = TextEditingController();
  final _saveEndController = TextEditingController();

  bool _rangeSeeded = false;
  bool _isSavingRange = false;

  // Range-playback picker state.
  DateTime? _playStart;
  DateTime? _playEnd;
  bool _loopRange = true;

  @override
  void initState() {
    super.initState();
    _syncDefaultRange();
  }

  @override
  void didUpdateWidget(covariant _PlaybackView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDefaultRange();
  }

  @override
  void dispose() {
    _saveStartController.dispose();
    _saveEndController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final playback = viewModel.playback;
    final recent = viewModel.localSegments.reversed.take(12).toList();
    final canSubmitRange = !_isSavingRange && viewModel.segments.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _PageHeader(
          eyebrow: 'Review',
          title: 'Playback & saves',
          description:
              'Listen across the rolling window and preserve important ranges.',
          icon: Icons.graphic_eq_outlined,
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Player',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: viewModel.localSegments.isEmpty
                        ? null
                        : widget.onPlay,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play Local Window'),
                  ),
                  if (playback.isPlaying)
                    IconButton.outlined(
                      tooltip: 'Pause playback',
                      onPressed: widget.onPausePlayback,
                      icon: const Icon(Icons.pause),
                    ),
                  IconButton.outlined(
                    tooltip: 'Stop playback',
                    onPressed: playback.isLoaded ? widget.onStopPlayback : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onSendAlert,
                    icon: const Icon(Icons.notification_important_outlined),
                    label: const Text('Send Alert'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricChip(
                    icon: Icons.timer_outlined,
                    label: 'Position',
                    value: _formatDuration(playback.position),
                  ),
                  _MetricChip(
                    icon: Icons.timeline,
                    label: 'Gaps',
                    value: viewModel.continuityGapCount.toString(),
                  ),
                  _MetricChip(
                    icon: Icons.join_inner,
                    label: 'Overlapped',
                    value: viewModel.overlappedSegments.toString(),
                  ),
                  _MetricChip(
                    icon: Icons.lock_outline,
                    label: 'Permanent',
                    value: viewModel.permanentSegmentCount.toString(),
                  ),
                ],
              ),
              if (playback.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  playback.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Range Playback',
          child: _buildRangePlayback(context, viewModel),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Permanent Save',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      controller: _saveStartController,
                      decoration: const InputDecoration(
                        labelText: 'Start timestamp',
                        prefixIcon: Icon(Icons.first_page),
                      ),
                      keyboardType: TextInputType.datetime,
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    child: TextField(
                      controller: _saveEndController,
                      decoration: const InputDecoration(
                        labelText: 'End timestamp',
                        prefixIcon: Icon(Icons.last_page),
                      ),
                      keyboardType: TextInputType.datetime,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: canSubmitRange ? _saveRange : null,
                    icon: _isSavingRange
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_outline),
                    label: Text(_isSavingRange ? 'Saving' : 'Save Permanently'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Local Segments',
          child: Column(
            children: [
              if (recent.isEmpty)
                _InlineState(
                  icon: Icons.hourglass_empty,
                  text: viewModel.recorder.isRecording
                      ? 'First segment is still recording.'
                      : 'No local segments yet.',
                )
              else
                for (final segment in recent)
                  _SegmentListItem(
                    title: segment.startedAtUtc.toLocal().toString(),
                    subtitle:
                        '${_formatDuration(segment.canonicalDuration)}'
                        ' / overlap ${_formatDuration(segment.trimStart)}',
                    trailing: StorageEstimate.formatBytes(segment.byteSize),
                    statusIcon: segment.isPermanentlySaved
                        ? Icons.lock_outline
                        : null,
                    statusTooltip: segment.isPermanentlySaved
                        ? 'Permanently saved'
                        : null,
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _saveRange() async {
    final startedAtUtc = _parseTimestamp(_saveStartController.text);
    final endedAtUtc = _parseTimestamp(_saveEndController.text);
    if (startedAtUtc == null) {
      _showSnack('Use a start timestamp.');
      return;
    }
    if (endedAtUtc == null) {
      _showSnack('Use an end timestamp.');
      return;
    }
    if (!endedAtUtc.isAfter(startedAtUtc)) {
      _showSnack('End timestamp must be after start timestamp.');
      return;
    }
    setState(() => _isSavingRange = true);
    try {
      await widget.onSaveRangePermanently(startedAtUtc, endedAtUtc);
    } finally {
      if (mounted) {
        setState(() => _isSavingRange = false);
      }
    }
  }

  Widget _buildRangePlayback(BuildContext context, AppViewModel viewModel) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final earliest =
        widget.earliestLocalUtc?.toLocal() ??
        now.subtract(Duration(hours: viewModel.config.deviceRetentionHours));
    // Lazy seed: default to the last 10 minutes up to "now".
    _playEnd ??= now;
    _playStart ??= _maxDate(
      earliest,
      now.subtract(const Duration(minutes: 10)),
    );

    var domainMin = earliest;
    var domainMax = now;
    if (!domainMax.isAfter(domainMin)) {
      domainMax = domainMin.add(const Duration(seconds: 1));
    }
    final start = _clampDate(_playStart!, domainMin, domainMax);
    final end = _clampDate(_maxDate(_playEnd!, start), domainMin, domainMax);
    final minMs = domainMin.millisecondsSinceEpoch.toDouble();
    final maxMs = domainMax.millisecondsSinceEpoch.toDouble();
    final startMs = start.millisecondsSinceEpoch.toDouble().clamp(minMs, maxMs);
    final endMs = end.millisecondsSinceEpoch.toDouble().clamp(startMs, maxMs);
    final hasAudio = viewModel.localSegments.isNotEmpty;
    // Whether any local segment actually overlaps the chosen window — so we can
    // surface "nothing here" inline in *this* card (and disable Play) rather than
    // routing it through the shared playback snapshot, which renders up in the
    // Playback card.
    final rangeHasAudio = viewModel.segments.any(
      (s) =>
          s.localPath != null &&
          s.endedAtUtc.isAfter(start.toUtc()) &&
          s.startedAtUtc.isBefore(end.toUtc()),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pick a window from the last ${viewModel.config.deviceRetentionHours} h '
          'up to now, then play it — or loop it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        RangeSlider(
          min: minMs,
          max: maxMs,
          values: RangeValues(startMs, endMs),
          labels: RangeLabels(_clockLabel(start), _clockLabel(end)),
          onChanged: hasAudio
              ? (v) => setState(() {
                  _playStart = DateTime.fromMillisecondsSinceEpoch(
                    v.start.round(),
                  );
                  _playEnd = DateTime.fromMillisecondsSinceEpoch(v.end.round());
                })
              : null,
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickDateTime(true, domainMin, domainMax),
                icon: const Icon(Icons.first_page, size: 16),
                label: Text(
                  'Start  ${_clockLabel(start)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickDateTime(false, domainMin, domainMax),
                icon: const Icon(Icons.last_page, size: 16),
                label: Text(
                  'End  ${_clockLabel(end)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final preset in const [
              (label: 'Last 1m', minutes: 1),
              (label: 'Last 10m', minutes: 10),
              (label: 'Last 1h', minutes: 60),
            ])
              ActionChip(
                label: Text(preset.label),
                onPressed: hasAudio
                    ? () => setState(() {
                        final e = DateTime.now();
                        _playEnd = e;
                        _playStart = _maxDate(
                          earliest,
                          e.subtract(Duration(minutes: preset.minutes)),
                        );
                      })
                    : null,
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Loop this range'),
          value: _loopRange,
          onChanged: (v) => setState(() => _loopRange = v),
        ),
        Row(
          children: [
            FilledButton.icon(
              onPressed: hasAudio && rangeHasAudio
                  ? () => widget.onPlayRange(
                      start.toUtc(),
                      end.toUtc(),
                      _loopRange,
                    )
                  : null,
              icon: Icon(_loopRange ? Icons.repeat : Icons.play_arrow),
              label: Text(_loopRange ? 'Play range (loop)' : 'Play range'),
            ),
            if (hasAudio && !rangeHasAudio) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No local audio in that time range.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Future<void> _pickDateTime(bool isStart, DateTime lo, DateTime hi) async {
    final current = _clampDate((isStart ? _playStart : _playEnd) ?? hi, lo, hi);
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: lo,
      lastDate: hi,
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) {
      return;
    }
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isStart) {
        _playStart = picked;
      } else {
        _playEnd = picked;
      }
    });
  }

  DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  DateTime _clampDate(DateTime v, DateTime lo, DateTime hi) =>
      v.isBefore(lo) ? lo : (v.isAfter(hi) ? hi : v);

  String _clockLabel(DateTime d) =>
      '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  DateTime? _parseTimestamp(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final parsed =
        DateTime.tryParse(trimmed) ??
        DateTime.tryParse(trimmed.replaceFirst(' ', 'T'));
    return parsed?.toUtc();
  }

  void _syncDefaultRange() {
    if (_rangeSeeded) {
      return;
    }
    final segments = [...widget.viewModel.segments]
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (segments.isEmpty) {
      return;
    }
    final end = segments.last.endedAtUtc.toLocal();
    final earliest = segments.first.startedAtUtc.toLocal();
    var start = end.subtract(const Duration(minutes: 10));
    if (start.isBefore(earliest)) {
      start = earliest;
    }
    _saveStartController.text = _formatTimestamp(start);
    _saveEndController.text = _formatTimestamp(end);
    _rangeSeeded = true;
  }

  String _formatTimestamp(DateTime value) {
    return value
        .toLocal()
        .toIso8601String()
        .substring(0, 19)
        .replaceFirst('T', ' ');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _ConfigureView extends StatelessWidget {
  const _ConfigureView({
    required this.viewModel,
    required this.accountSection,
    required this.selectedProvider,
    required this.uploadEnabled,
    required this.onUploadEnabledChanged,
    required this.onProviderChanged,
    required this.onSave,
    required this.onAudioConfigChanged,
    required this.controller,
    required this.deviceRetentionController,
    required this.cloudRetentionController,
    required this.segmentMinutesController,
    required this.overlapSecondsController,
    required this.sampleRateController,
    required this.channelsController,
    required this.backendUrlController,
    required this.backendDeviceTokenController,
    required this.s3BucketController,
    required this.s3RegionController,
    required this.s3PrefixController,
    required this.s3EndpointController,
    required this.s3AccessKeyController,
    required this.s3SecretKeyController,
    required this.s3SessionTokenController,
    required this.sttApiKeyController,
  });

  final AppViewModel viewModel;
  final Widget accountSection;
  final CloudProvider selectedProvider;
  final bool uploadEnabled;
  final ValueChanged<bool> onUploadEnabledChanged;
  final ValueChanged<CloudProvider> onProviderChanged;
  final VoidCallback onSave;
  final ValueChanged<AppConfig> onAudioConfigChanged;
  final AppController controller;
  final TextEditingController deviceRetentionController;
  final TextEditingController cloudRetentionController;
  final TextEditingController segmentMinutesController;
  final TextEditingController overlapSecondsController;
  final TextEditingController sampleRateController;
  final TextEditingController channelsController;
  final TextEditingController backendUrlController;
  final TextEditingController backendDeviceTokenController;
  final TextEditingController s3BucketController;
  final TextEditingController s3RegionController;
  final TextEditingController s3PrefixController;
  final TextEditingController s3EndpointController;
  final TextEditingController s3AccessKeyController;
  final TextEditingController s3SecretKeyController;
  final TextEditingController s3SessionTokenController;
  final TextEditingController sttApiKeyController;

  @override
  Widget build(BuildContext context) {
    return _SettingsTabbedPane(
      onSave: onSave,
      tabs: [
        _SettingsTab(
          label: 'Account',
          icon: Icons.account_circle_outlined,
          child: _SettingsPane(
            storageKey: 'configure-account',
            children: [accountSection],
          ),
        ),
        _SettingsTab(
          label: 'Capture',
          icon: Icons.mic_none,
          child: _SettingsPane(
            storageKey: 'configure-capture',
            children: [
              _CaptureSection(
                deviceId: viewModel.config.deviceId,
                uploadEnabled: uploadEnabled,
                onUploadEnabledChanged: onUploadEnabledChanged,
                deviceRetentionController: deviceRetentionController,
                cloudRetentionController: cloudRetentionController,
                segmentMinutesController: segmentMinutesController,
                overlapSecondsController: overlapSecondsController,
                sampleRateController: sampleRateController,
                channelsController: channelsController,
              ),
              _TransferPolicySection(
                config: viewModel.config,
                status: viewModel.transferStatus,
                onChanged: onAudioConfigChanged,
              ),
              _AudioTuningSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
              ),
            ],
          ),
        ),
        _SettingsTab(
          label: 'Automation',
          icon: Icons.event_available_outlined,
          child: _SettingsPane(
            storageKey: 'configure-automation',
            children: [
              _ScheduleSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
              ),
              _ContextTriggersSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
                controller: controller,
              ),
            ],
          ),
        ),
        _SettingsTab(
          label: 'Cloud',
          icon: Icons.cloud_outlined,
          child: _SettingsPane(
            storageKey: 'configure-cloud',
            children: [
              _CloudSection(
                selectedProvider: selectedProvider,
                onProviderChanged: onProviderChanged,
                backendUrlController: backendUrlController,
                backendDeviceTokenController: backendDeviceTokenController,
                s3BucketController: s3BucketController,
                s3RegionController: s3RegionController,
                s3PrefixController: s3PrefixController,
                s3EndpointController: s3EndpointController,
                s3AccessKeyController: s3AccessKeyController,
                s3SecretKeyController: s3SecretKeyController,
                s3SessionTokenController: s3SessionTokenController,
              ),
              if (viewModel.isDeviceRegistered)
                _CloudLinkSection(controller: controller, viewModel: viewModel)
              else
                const _InlineState(
                  icon: Icons.cloud_off_outlined,
                  text:
                      'Sign in and register this device to link cloud destinations.',
                ),
            ],
          ),
        ),
        _SettingsTab(
          label: 'Intelligence',
          icon: Icons.graphic_eq,
          child: _SettingsPane(
            storageKey: 'configure-intelligence',
            children: [
              _AcousticSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
                sttApiKeyController: sttApiKeyController,
              ),
              _VoiceIdSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
                controller: controller,
              ),
              _MusicMemoriesSection(
                config: viewModel.config,
                onChanged: onAudioConfigChanged,
                controller: controller,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsTab {
  const _SettingsTab({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;
}

class _SettingsTabbedPane extends StatefulWidget {
  const _SettingsTabbedPane({required this.tabs, required this.onSave});

  final List<_SettingsTab> tabs;
  final VoidCallback onSave;

  @override
  State<_SettingsTabbedPane> createState() => _SettingsTabbedPaneState();
}

class _SettingsTabbedPaneState extends State<_SettingsTabbedPane> {
  int _selectedIndex = 0;

  @override
  void didUpdateWidget(covariant _SettingsTabbedPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedIndex >= widget.tabs.length) {
      _selectedIndex = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: _PageHeader(
            eyebrow: 'Settings',
            title: 'Configure Sonus Auris',
            description:
                'Manage your account, capture policy, automation, storage, and intelligence.',
            icon: Icons.tune_outlined,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _SettingsTabStrip(
            tabs: widget.tabs,
            selectedIndex: _selectedIndex,
            onSelected: (index) => setState(() => _selectedIndex = index),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: IndexedStack(
            index: _selectedIndex,
            sizing: StackFit.expand,
            children: [for (final tab in widget.tabs) tab.child],
          ),
        ),
        _ConfigureActionBar(onSave: widget.onSave),
      ],
    );
  }
}

class _SettingsTabStrip extends StatelessWidget {
  const _SettingsTabStrip({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_SettingsTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              _SettingsTabButton(
                tab: tabs[i],
                selected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
              if (i != tabs.length - 1) const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsTabButton extends StatelessWidget {
  const _SettingsTabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _SettingsTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? theme.colorScheme.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 118),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tab.icon, size: 18, color: foreground),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsPane extends StatelessWidget {
  const _SettingsPane({required this.storageKey, required this.children});

  final String storageKey;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: PageStorageKey<String>(storageKey),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemBuilder: (context, index) => children[index],
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemCount: children.length,
    );
  }
}

class _ConfigureActionBar extends StatelessWidget {
  const _ConfigureActionBar({required this.onSave});

  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: SonusColors.paper,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: FilledButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save Configuration'),
          ),
        ),
      ),
    );
  }
}

/// Supabase identity: project config plus email/password sign-in. When signed
/// in, the controller registers the device and uploads run under the verified
/// account. The password is held only transiently in a local field.
class _AccountSection extends StatefulWidget {
  const _AccountSection({
    required this.isSignedIn,
    required this.signedInEmail,
    required this.isDeviceRegistered,
    required this.isAwaitingDeviceRegistration,
    required this.supabaseUrlController,
    required this.supabaseAnonKeyController,
    required this.onSignIn,
    required this.onSignUp,
    required this.onPasswordReset,
    required this.onSignOut,
    required this.onDeleteAccount,
  });

  final bool isSignedIn;
  final String? signedInEmail;
  final bool isDeviceRegistered;
  final bool isAwaitingDeviceRegistration;
  final TextEditingController supabaseUrlController;
  final TextEditingController supabaseAnonKeyController;
  final Future<void> Function(String email, String password) onSignIn;
  final Future<void> Function(String email, String password) onSignUp;
  final Future<void> Function(String email) onPasswordReset;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onDeleteAccount;

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _runAccountAction(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmDeleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This deletes your account, backend metadata, local recordings, and saved tokens on this device. Recordings copied to your own cloud storage must be removed there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _runAccountAction(widget.onDeleteAccount);
    }
  }

  Widget _legalLinks() {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton.icon(
          onPressed: () => _openPublicPage(context, _privacyPolicyUrl),
          icon: const Icon(Icons.privacy_tip_outlined),
          label: const Text('Privacy'),
        ),
        TextButton.icon(
          onPressed: () => _openPublicPage(context, _accountDeletionUrl),
          icon: const Icon(Icons.manage_accounts_outlined),
          label: const Text('Deletion help'),
        ),
        TextButton.icon(
          onPressed: () => _openPublicPage(context, _supportUrl),
          icon: const Icon(Icons.help_outline),
          label: const Text('Support'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBundledSupabaseConfig =
        AppConfig.defaultSupabaseUrl.trim().isNotEmpty &&
        validateSupabaseAnonKey(AppConfig.defaultSupabaseAnonKey) == null;
    if (widget.isSignedIn) {
      final status = widget.isDeviceRegistered
          ? 'Device registered.'
          : widget.isAwaitingDeviceRegistration
          ? 'Registering device…'
          : 'Set the backend URL to register this device.';
      return _Section(
        title: 'Account',
        icon: Icons.account_circle_outlined,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.signedInEmail ?? 'Signed in',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(status, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _runAccountAction(widget.onSignOut),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout),
                  label: Text(_busy ? 'Working…' : 'Sign out'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _confirmDeleteAccount,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Delete account'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _legalLinks(),
          ],
        ),
      );
    }
    return _Section(
      title: 'Account',
      icon: Icons.account_circle_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sign in to record under your account and back up to cloud storage.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          SupabaseAuthForm(
            emailController: _emailController,
            passwordController: _passwordController,
            supabaseUrlController: widget.supabaseUrlController,
            supabaseAnonKeyController: widget.supabaseAnonKeyController,
            showProjectConfiguration: !hasBundledSupabaseConfig,
            enabled: !_busy,
            onSignIn: widget.onSignIn,
            onSignUp: widget.onSignUp,
            onPasswordReset: widget.onPasswordReset,
          ),
          const SizedBox(height: 8),
          _legalLinks(),
        ],
      ),
    );
  }
}

/// Battery + network controls for cloud streaming. These never affect local
/// capture (the rolling 100h+ window keeps recording); they only defer uploads,
/// which catch up automatically once conditions allow. Changes persist
/// immediately via [onChanged]; [status] reflects the live gate decision.
class _TransferPolicySection extends StatefulWidget {
  const _TransferPolicySection({
    required this.config,
    required this.status,
    required this.onChanged,
  });

  final AppConfig config;
  final TransferGateStatus status;
  final ValueChanged<AppConfig> onChanged;

  @override
  State<_TransferPolicySection> createState() => _TransferPolicySectionState();
}

class _TransferPolicySectionState extends State<_TransferPolicySection> {
  String? _syncedDeviceId;
  late bool _pauseOnLowBattery;
  late double _threshold;
  late UploadNetworkPolicy _networkPolicy;

  void _seed(AppConfig config) {
    _pauseOnLowBattery = config.pauseUploadsOnLowBattery;
    _threshold = config.lowBatteryThresholdPercent.clamp(5, 80).toDouble();
    _networkPolicy = config.uploadNetworkPolicy;
    _syncedDeviceId = config.deviceId;
  }

  void _apply() {
    widget.onChanged(
      widget.config.copyWith(
        pauseUploadsOnLowBattery: _pauseOnLowBattery,
        lowBatteryThresholdPercent: _threshold.round(),
        uploadNetworkPolicy: _networkPolicy,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_syncedDeviceId != widget.config.deviceId) {
      _seed(widget.config);
    }
    final status = widget.status;
    return _Section(
      title: 'Battery & Network',
      icon: Icons.battery_charging_full_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Local recording always continues. These settings only pause cloud '
            'uploads, which catch up automatically once the battery recovers or '
            'an allowed network is available.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _pauseOnLowBattery,
            onChanged: (value) {
              setState(() => _pauseOnLowBattery = value);
              _apply();
            },
            title: const Text('Pause uploads on low battery'),
            subtitle: const Text(
              'Uploads stop below the threshold (unless charging).',
            ),
          ),
          if (_pauseOnLowBattery)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Low-battery threshold: ${_threshold.round()}%'),
                  Slider(
                    value: _threshold,
                    min: 5,
                    max: 80,
                    divisions: 15,
                    label: '${_threshold.round()}%',
                    onChanged: (v) => setState(() => _threshold = v),
                    onChangeEnd: (_) => _apply(),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<UploadNetworkPolicy>(
            initialValue: _networkPolicy,
            decoration: const InputDecoration(labelText: 'Upload over'),
            items: UploadNetworkPolicy.values
                .map(
                  (policy) => DropdownMenuItem(
                    value: policy,
                    child: Text(policy.label),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() => _networkPolicy = value);
              _apply();
            },
          ),
          const SizedBox(height: 8),
          _TransferStatusLine(status: status),
        ],
      ),
    );
  }
}

/// One-line live readout of the current gate: battery, network, and whether
/// uploads are paused (with the reason).
class _TransferStatusLine extends StatelessWidget {
  const _TransferStatusLine({required this.status});

  final TransferGateStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battery = status.batteryLevel >= 0
        ? '${status.batteryLevel}%${status.isCharging ? ' (charging)' : ''}'
        : 'unknown';
    final network = !status.isOnline
        ? 'offline'
        : status.onWifi
        ? 'Wi-Fi'
        : status.onCellular
        ? 'cellular'
        : 'connected';
    final paused = status.isPaused;
    return Row(
      children: [
        Icon(
          paused ? Icons.cloud_off : Icons.cloud_done,
          size: 18,
          color: paused ? theme.colorScheme.error : theme.colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            paused
                ? 'Uploads paused — ${status.detail ?? 'gated'} · battery $battery · $network'
                : 'Uploads allowed · battery $battery · $network',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Musician + sensitivity controls: capture intent, input gain, a 3-band tone
/// control, loudness-trigger sensitivity, and verbal confirmation cues. Changes
/// persist immediately (sliders on release) via [onChanged].
class _AudioTuningSection extends StatefulWidget {
  const _AudioTuningSection({required this.config, required this.onChanged});

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;

  @override
  State<_AudioTuningSection> createState() => _AudioTuningSectionState();
}

class _AudioTuningSectionState extends State<_AudioTuningSection> {
  static const _useCaseLabels = {
    'security': 'Security / dashcam',
    'music': 'Music / instrument',
    'meeting': 'Meeting',
    'voice_note': 'Voice note',
    'ambient': 'Ambient',
  };

  String? _syncedDeviceId;
  late String _useCase;
  late double _micSensitivity;
  late double _noiseTriggerSensitivity;
  late double _bass;
  late double _mid;
  late double _treble;
  late bool _autoGain;
  late bool _noiseSuppress;
  late bool _verbalCues;
  late bool _autoStart;
  late bool _locationTagging;

  void _seed(AppConfig config) {
    _useCase = config.useCase;
    _micSensitivity = config.micSensitivity;
    _noiseTriggerSensitivity = config.noiseTriggerSensitivity;
    _bass = config.bassGainDb;
    _mid = config.midGainDb;
    _treble = config.trebleGainDb;
    _autoGain = config.autoGain;
    _noiseSuppress = config.noiseSuppress;
    _verbalCues = config.verbalCuesEnabled;
    _autoStart = config.autoStartCaptureEnabled;
    _locationTagging = config.locationTaggingEnabled;
    _syncedDeviceId = config.deviceId;
  }

  void _apply() {
    widget.onChanged(
      widget.config.copyWith(
        useCase: _useCase,
        micSensitivity: _micSensitivity,
        noiseTriggerSensitivity: _noiseTriggerSensitivity,
        bassGainDb: _bass,
        midGainDb: _mid,
        trebleGainDb: _treble,
        autoGain: _autoGain,
        noiseSuppress: _noiseSuppress,
        verbalCuesEnabled: _verbalCues,
        autoStartCaptureEnabled: _autoStart,
        locationTaggingEnabled: _locationTagging,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_syncedDeviceId != widget.config.deviceId) {
      _seed(widget.config);
    }
    return _Section(
      title: 'Audio Tuning',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _useCase,
            decoration: const InputDecoration(labelText: 'Capture mode'),
            items: [
              for (final useCase in AppConfig.supportedUseCases)
                DropdownMenuItem(
                  value: useCase,
                  child: Text(_useCaseLabels[useCase] ?? useCase),
                ),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _useCase = value;
                // Music preserves dynamics: disable platform AGC + denoise.
                if (value == 'music') {
                  _autoGain = false;
                  _noiseSuppress = false;
                } else if (value == 'security') {
                  _autoGain = true;
                  _noiseSuppress = true;
                }
              });
              _apply();
            },
          ),
          _slider(
            label: 'Mic sensitivity',
            value: _micSensitivity,
            min: 0.25,
            max: 4.0,
            divisions: 15,
            display: '${_micSensitivity.toStringAsFixed(2)}x',
            onChanged: (v) => setState(() => _micSensitivity = v),
          ),
          _slider(
            label: 'Noise alert sensitivity',
            value: _noiseTriggerSensitivity,
            min: 0.0,
            max: 1.0,
            divisions: 20,
            display: '${(_noiseTriggerSensitivity * 100).round()}%',
            onChanged: (v) => setState(() => _noiseTriggerSensitivity = v),
          ),
          _slider(
            label: 'Bass',
            value: _bass,
            min: -12,
            max: 12,
            divisions: 24,
            display: '${_bass.toStringAsFixed(0)} dB',
            onChanged: (v) => setState(() => _bass = v),
          ),
          _slider(
            label: 'Mid',
            value: _mid,
            min: -12,
            max: 12,
            divisions: 24,
            display: '${_mid.toStringAsFixed(0)} dB',
            onChanged: (v) => setState(() => _mid = v),
          ),
          _slider(
            label: 'Treble',
            value: _treble,
            min: -12,
            max: 12,
            divisions: 24,
            display: '${_treble.toStringAsFixed(0)} dB',
            onChanged: (v) => setState(() => _treble = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto gain control'),
            subtitle: const Text('Off for music to keep dynamics'),
            value: _autoGain,
            onChanged: (value) {
              setState(() => _autoGain = value);
              _apply();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Noise suppression'),
            value: _noiseSuppress,
            onChanged: (value) {
              setState(() => _noiseSuppress = value);
              _apply();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Verbal cues'),
            subtitle: const Text('Speak "recording" / "saved" confirmations'),
            value: _verbalCues,
            onChanged: (value) {
              setState(() => _verbalCues = value);
              _apply();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Always-on (auto-start capture)'),
            subtitle: const Text(
              'Start recording automatically when the app opens and after a '
              'reboot — no need to press Start each time.',
            ),
            value: _autoStart,
            onChanged: (value) {
              setState(() => _autoStart = value);
              _apply();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Location evidence (GPS)'),
            subtitle: const Text(
              'Tag each clip with where it was recorded. Requires location '
              'permission.',
            ),
            value: _locationTagging,
            onChanged: (value) {
              setState(() => _locationTagging = value);
              _apply();
            },
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
              Text(display, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
            onChangeEnd: (_) => _apply(),
          ),
        ],
      ),
    );
  }
}

/// On-device acoustic intelligence: the FFT engine, its loudness gate, the
/// Links the user's SoundCloud / Spotify and toggles the opt-in "memories"
/// features: a daily "Day of My Life" SoundCloud archive and an auto-built
/// private Spotify playlist of songs heard. Both are off until linked + enabled.
/// "Knows your voice" + voice commands: enroll up to five on-device voice
/// samples (FFT/MFCC fingerprints, never uploaded) and control the hands-free
/// command pipeline that only obeys the enrolled voice.
class _VoiceIdSection extends StatefulWidget {
  const _VoiceIdSection({
    required this.config,
    required this.onChanged,
    required this.controller,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;
  final AppController controller;

  @override
  State<_VoiceIdSection> createState() => _VoiceIdSectionState();
}

class _VoiceIdSectionState extends State<_VoiceIdSection> {
  List<VoiceProfileSample> _samples = const [];
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final samples = await widget.controller.voiceProfiles.load();
    if (mounted) {
      setState(() => _samples = samples);
    }
  }

  Future<void> _addSample() async {
    setState(() => _busy = true);
    final message = await widget.controller.enrollVoiceSample();
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _status = message;
    });
    await _refresh();
  }

  Future<void> _removeSample(String id) async {
    await widget.controller.removeVoiceSample(id);
    if (mounted) {
      setState(() => _status = 'Voice sample removed.');
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return _Section(
      title: 'Knows Your Voice',
      icon: Icons.record_voice_over_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Recognize my voice'),
            subtitle: const Text(
              'Match speech against your enrolled samples so insights and '
              'commands are about you. Samples and voiceprints stay on this '
              'device.',
            ),
            value: config.voiceIdEnabled,
            onChanged: (v) =>
                widget.onChanged(config.copyWith(voiceIdEnabled: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Voice commands'),
            subtitle: const Text(
              'Say "Hey Sonus, confirm recording", "pause recording for 10 '
              'minutes", "start recording", "stop recording". With voice '
              'recognition on, only your enrolled voice is obeyed.',
            ),
            value: config.voiceCommandsEnabled,
            onChanged: (v) =>
                widget.onChanged(config.copyWith(voiceCommandsEnabled: v)),
          ),
          const SizedBox(height: 8),
          Text(
            'Voice samples (${_samples.length}/${VoiceProfileService.maxSamples})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (final sample in _samples)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.graphic_eq),
              title: Text(
                'Sample from '
                '${sample.createdAtUtc.toLocal().toString().split('.').first}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove this voice sample',
                onPressed: () => _removeSample(sample.id),
              ),
            ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed:
                _busy || _samples.length >= VoiceProfileService.maxSamples
                ? null
                : _addSample,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mic),
            label: const Text('Add voice sample (last 5 seconds)'),
          ),
          const SizedBox(height: 4),
          const Text(
            'While recording, speak normally for a few seconds, then tap. '
            'Three to five samples in different rooms give the best match.',
            style: TextStyle(fontSize: 12),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _status!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _MusicMemoriesSection extends StatefulWidget {
  const _MusicMemoriesSection({
    required this.config,
    required this.onChanged,
    required this.controller,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;
  final AppController controller;

  @override
  State<_MusicMemoriesSection> createState() => _MusicMemoriesSectionState();
}

class _MusicMemoriesSectionState extends State<_MusicMemoriesSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scLinked = widget.controller.isSoundCloudLinked;
    final spLinked = widget.controller.isSpotifyLinked;
    return _Section(
      title: 'Music memories',
      icon: Icons.music_note_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // SoundCloud — Day of My Life
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('SoundCloud'),
            subtitle: Text(scLinked ? 'Linked' : 'Not linked'),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      scLinked
                          ? widget.controller.unlinkSoundCloud
                          : widget.controller.linkSoundCloud,
                    ),
              child: Text(scLinked ? 'Unlink' : 'Link'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('“Day of My Life” daily archive'),
            subtitle: const Text(
              'Publish each day as a private 24-hour track with AI notes; keeps '
              'the last 100 days. Leaves the encrypted vault — your choice.',
            ),
            value: widget.config.soundCloudDailyArchive,
            onChanged: scLinked
                ? (v) => widget.onChanged(
                    widget.config.copyWith(soundCloudDailyArchive: v),
                  )
                : null,
          ),
          const Divider(),
          // Spotify — memories playlist
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Spotify'),
            subtitle: Text(spLinked ? 'Linked' : 'Not linked'),
            trailing: TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      spLinked
                          ? widget.controller.unlinkSpotify
                          : widget.controller.linkSpotify,
                    ),
              child: Text(spLinked ? 'Unlink' : 'Link'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-add songs to a private playlist'),
            subtitle: const Text(
              'Songs recognised on-device are added (de-duplicated) to a private '
              '“Sonus Auris Memories” playlist.',
            ),
            value: widget.config.spotifyAutoPlaylist,
            onChanged: spLinked
                ? (v) => widget.onChanged(
                    widget.config.copyWith(spotifyAutoPlaylist: v),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// snore/apnea/music/speech detectors, optional ShazamKit + cloud STT, and
/// adaptive recording quality. Detector/config toggles persist immediately via
/// [onChanged]; the STT API key (a secret) is held in [sttApiKeyController] and
/// saved with the main Save button.
class _AcousticSection extends StatefulWidget {
  const _AcousticSection({
    required this.config,
    required this.onChanged,
    required this.sttApiKeyController,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;
  final TextEditingController sttApiKeyController;

  @override
  State<_AcousticSection> createState() => _AcousticSectionState();
}

class _AcousticSectionState extends State<_AcousticSection> {
  static const _captureRates = [16000, 24000, 44100, 48000];
  static const _quietRates = [8000, 16000, 22050];

  String? _syncedDeviceId;
  late bool _enabled;
  late bool _snore;
  late bool _sleep;
  late bool _sleepAlarms;
  late bool _sleepMotionConsent;
  late bool _sleepAmbientLightConsent;
  late bool _sleepPhoneContextConsent;
  late bool _sleepCloudSyncConsent;
  late double _sleepCycleMinutes;
  late bool _music;
  late bool _speech;
  late bool _shazam;
  late double _activationDb;
  late bool _sttEnabled;
  late bool _adaptiveEnabled;
  late int _captureRate;
  late int _quietRate;
  late double _adaptiveLoudnessDb;
  final _keywordsController = TextEditingController();
  final _sttEndpointController = TextEditingController();

  void _seed(AppConfig config) {
    _enabled = config.acousticAnalysisEnabled;
    _snore = config.snoreDetectionEnabled;
    _sleep = config.sleepAnalysisEnabled;
    _sleepAlarms = config.sleepCycleAlarmsEnabled;
    _sleepMotionConsent = config.sleepMotionSensorConsent;
    _sleepAmbientLightConsent = config.sleepAmbientLightConsent;
    _sleepPhoneContextConsent = config.sleepPhoneContextConsent;
    _sleepCloudSyncConsent = config.sleepCloudSyncConsent;
    _sleepCycleMinutes = config.sleepCycleMinutesByIndex.isEmpty
        ? 90.0
        : config.sleepCycleMinutesByIndex.first;
    _music = config.musicDetectionEnabled;
    _speech = config.speechDetectionEnabled;
    _shazam = config.shazamEnabled;
    _activationDb = config.analysisActivationDb;
    _sttEnabled = config.sttEnabled;
    _adaptiveEnabled = config.adaptiveQualityEnabled;
    _captureRate = config.captureSampleRate;
    _quietRate = config.quietSampleRate;
    _adaptiveLoudnessDb = config.adaptiveLoudnessDb;
    _keywordsController.text = config.keywords.join(', ');
    _sttEndpointController.text = config.sttEndpoint;
    _syncedDeviceId = config.deviceId;
  }

  @override
  void dispose() {
    _keywordsController.dispose();
    _sttEndpointController.dispose();
    super.dispose();
  }

  void _apply() {
    final keywords = _keywordsController.text
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    widget.onChanged(
      widget.config.copyWith(
        acousticAnalysisEnabled: _enabled,
        snoreDetectionEnabled: _snore,
        sleepAnalysisEnabled: _sleep,
        sleepCycleAlarmsEnabled: _sleepAlarms,
        sleepCycleMinutesByIndex: _sleepCycleVector(),
        sleepMotionSensorConsent: _sleepMotionConsent,
        sleepAmbientLightConsent: _sleepAmbientLightConsent,
        sleepPhoneContextConsent: _sleepPhoneContextConsent,
        sleepCloudSyncConsent: _sleepCloudSyncConsent,
        musicDetectionEnabled: _music,
        speechDetectionEnabled: _speech,
        shazamEnabled: _shazam,
        analysisActivationDb: _activationDb,
        sttEnabled: _sttEnabled,
        sttEndpoint: _sttEndpointController.text.trim(),
        keywords: keywords,
        adaptiveQualityEnabled: _adaptiveEnabled,
        captureSampleRate: _captureRate,
        quietSampleRate: _quietRate,
        adaptiveLoudnessDb: _adaptiveLoudnessDb,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_syncedDeviceId != widget.config.deviceId) {
      _seed(widget.config);
    }
    return _Section(
      title: 'Acoustic Intelligence',
      icon: Icons.graphic_eq,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable acoustic analysis'),
            subtitle: const Text(
              'On-device FFT. Sustained sounds and sudden transients can activate it.',
            ),
            value: _enabled,
            onChanged: (v) {
              setState(() => _enabled = v);
              _apply();
            },
          ),
          if (_enabled) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Snoring / apnea patterns'),
              subtitle: const Text('Non-diagnostic; not a medical device'),
              value: _snore,
              onChanged: (v) {
                setState(() => _snore = v);
                _apply();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sleep analysis'),
              subtitle: const Text('Breathing cadence and snoring cycles'),
              value: _sleep,
              onChanged: (v) {
                setState(() {
                  _sleep = v;
                  if (!v) {
                    _sleepAlarms = false;
                    _sleepMotionConsent = false;
                    _sleepAmbientLightConsent = false;
                    _sleepPhoneContextConsent = false;
                    _sleepCloudSyncConsent = false;
                  }
                });
                _apply();
              },
            ),
            if (_sleep) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Alarm after cycles 5 and 6'),
                subtitle: const Text('7.5h and 9h baseline; learned per user'),
                value: _sleepAlarms,
                onChanged: (v) {
                  setState(() => _sleepAlarms = v);
                  _apply();
                },
              ),
              _slider(
                label: 'Cycle seed',
                value: _sleepCycleMinutes,
                min: 75,
                max: 120,
                divisions: 45,
                display: '${_sleepCycleMinutes.toStringAsFixed(0)} min',
                onChanged: (v) {
                  setState(() => _sleepCycleMinutes = v);
                  _apply();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow motion signal'),
                subtitle: const Text('Stillness, tossing, getting up'),
                value: _sleepMotionConsent,
                onChanged: (v) {
                  setState(() => _sleepMotionConsent = v);
                  _apply();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow ambient light signal'),
                subtitle: const Text('Dark room and morning light changes'),
                value: _sleepAmbientLightConsent,
                onChanged: (v) {
                  setState(() => _sleepAmbientLightConsent = v);
                  _apply();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow phone context signal'),
                subtitle: const Text('Charging, idle time, usual bedtime'),
                value: _sleepPhoneContextConsent,
                onChanged: (v) {
                  setState(() => _sleepPhoneContextConsent = v);
                  _apply();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sync sleep cycles to cloud'),
                subtitle: const Text(
                  'Off: sleep detections stay on this device',
                ),
                value: _sleepCloudSyncConsent,
                onChanged: (v) {
                  setState(() => _sleepCloudSyncConsent = v);
                  _apply();
                },
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Music detection'),
              value: _music,
              onChanged: (v) {
                setState(() => _music = v);
                _apply();
              },
            ),
            if (_music)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Identify songs (ShazamKit, iOS only)'),
                subtitle: const Text('Sends an audio fingerprint to Apple'),
                value: _shazam,
                onChanged: (v) {
                  setState(() => _shazam = v);
                  _apply();
                },
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Speech detection'),
              value: _speech,
              onChanged: (v) {
                setState(() => _speech = v);
                _apply();
              },
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.health_and_safety_outlined),
              title: Text('Safety sound patterns'),
              subtitle: Text(
                'Classified on-device: sudden loud noise, raised voice, and repeated raised-voice patterns. Heuristic only; event metadata follows your configured sync.',
              ),
            ),
            _slider(
              label: 'Activation level',
              value: _activationDb,
              min: -90,
              max: 0,
              divisions: 90,
              display: '${_activationDb.toStringAsFixed(0)} dB',
              onChanged: (v) => setState(() => _activationDb = v),
            ),
            const Divider(),
            Text(
              'Keyword alerts (cloud speech-to-text)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Transcribe speech for keywords'),
              subtitle: const Text(
                'Opt-in. Sends short clips to your STT endpoint.',
              ),
              value: _sttEnabled,
              onChanged: (v) {
                setState(() => _sttEnabled = v);
                _apply();
              },
            ),
            if (_sttEnabled) ...[
              TextField(
                controller: _keywordsController,
                decoration: const InputDecoration(
                  labelText: 'Keywords (comma-separated)',
                ),
                onEditingComplete: _apply,
              ),
              TextField(
                controller: _sttEndpointController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'STT endpoint URL',
                ),
                onEditingComplete: _apply,
              ),
              TextField(
                controller: widget.sttApiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'STT API key (saved with Save Configuration)',
                ),
              ),
            ],
            const Divider(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Adaptive recording quality'),
              subtitle: const Text(
                'Capture high; store quiet stretches downsampled.',
              ),
              value: _adaptiveEnabled,
              onChanged: (v) {
                setState(() => _adaptiveEnabled = v);
                _apply();
              },
            ),
            if (_adaptiveEnabled) ...[
              DropdownButtonFormField<int>(
                initialValue: _captureRates.contains(_captureRate)
                    ? _captureRate
                    : 48000,
                decoration: const InputDecoration(
                  labelText: 'Loud capture rate',
                ),
                items: [
                  for (final r in _captureRates)
                    DropdownMenuItem(value: r, child: Text('$r Hz')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _captureRate = v);
                  _apply();
                },
              ),
              DropdownButtonFormField<int>(
                initialValue: _quietRates.contains(_quietRate)
                    ? _quietRate
                    : 16000,
                decoration: const InputDecoration(
                  labelText: 'Quiet storage rate',
                ),
                items: [
                  for (final r in _quietRates)
                    DropdownMenuItem(value: r, child: Text('$r Hz')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _quietRate = v);
                  _apply();
                },
              ),
              _slider(
                label: 'Loud/quiet threshold',
                value: _adaptiveLoudnessDb,
                min: -90,
                max: 0,
                divisions: 90,
                display: '${_adaptiveLoudnessDb.toStringAsFixed(0)} dB',
                onChanged: (v) => setState(() => _adaptiveLoudnessDb = v),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
              Text(display, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
            onChangeEnd: (_) => _apply(),
          ),
        ],
      ),
    );
  }

  List<double> _sleepCycleVector() {
    final existing = widget.config.sleepCycleMinutesByIndex;
    final vector = existing.isEmpty
        ? List<double>.filled(6, _sleepCycleMinutes)
        : existing.toList();
    while (vector.length < 6) {
      vector.add(vector.isEmpty ? _sleepCycleMinutes : vector.last);
    }
    vector[0] = _sleepCycleMinutes;
    return vector
        .map((minutes) => minutes.clamp(75.0, 120.0).toDouble())
        .toList(growable: false);
  }
}

String _cloudProviderLabel(String provider) {
  switch (provider) {
    case 'google_drive':
      return 'Google Drive';
    case 'microsoft_onedrive':
      return 'Microsoft OneDrive';
    case 'apple_icloud':
      return 'Apple iCloud';
    default:
      return provider;
  }
}

/// Lists linked cloud destinations and offers one-tap iCloud linking plus a
/// guided authorization-code flow for Google Drive / OneDrive.
class _CloudLinkSection extends StatefulWidget {
  const _CloudLinkSection({required this.controller, required this.viewModel});

  final AppController controller;
  final AppViewModel viewModel;

  @override
  State<_CloudLinkSection> createState() => _CloudLinkSectionState();
}

class _CloudLinkSectionState extends State<_CloudLinkSection> {
  Future<List<CloudConnection>>? _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() => _future = widget.controller.loadCloudConnections());
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
  }

  Future<void> _linkProvider(CloudProvider provider) async {
    final host = Uri.tryParse(widget.viewModel.config.backendBaseUrl.trim());
    final defaultRedirect = (host != null && host.host.isNotEmpty)
        ? '${host.scheme}://${host.host}/oauth/callback'
        : '';
    await showDialog<bool>(
      context: context,
      builder: (_) => _ProviderLinkDialog(
        provider: provider,
        controller: widget.controller,
        defaultRedirectUri: defaultRedirect,
      ),
    );
    if (mounted) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Cloud Backup Links',
      icon: Icons.cloud_sync_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mirror uploaded recordings to your own cloud storage.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<CloudConnection>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                );
              }
              if (snapshot.hasError) {
                return Text('Could not load links: ${snapshot.error}');
              }
              final connections = snapshot.data ?? const <CloudConnection>[];
              if (connections.isEmpty) {
                return const Text('No cloud destinations linked yet.');
              }
              return Column(children: [for (final c in connections) _tile(c)]);
            },
          ),
          const Divider(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(widget.controller.linkICloud),
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('Link iCloud'),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _linkProvider(CloudProvider.googleDrive),
                icon: const Icon(Icons.add_to_drive_outlined),
                label: const Text('Link Google Drive'),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _linkProvider(CloudProvider.oneDrive),
                icon: const Icon(Icons.cloud_sync_outlined),
                label: const Text('Link OneDrive'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(widget.controller.syncIcloudBackups),
              icon: const Icon(Icons.sync),
              label: const Text('Sync iCloud now'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(CloudConnection connection) {
    final detail = [
      connection.status,
      connection.folderPath,
      if (connection.displayName != null) connection.displayName!,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(_cloudProviderLabel(connection.provider)),
      subtitle: Text(detail),
      trailing: IconButton(
        icon: const Icon(Icons.link_off),
        tooltip: 'Remove',
        onPressed: _busy
            ? null
            : () => _run(
                () => widget.controller.revokeCloudConnection(connection.id),
              ),
      ),
    );
  }
}

/// Guided Google Drive / OneDrive link: fetch an authorization URL, let the user
/// authorize in a browser, then paste the returned `code` back to complete.
class _ProviderLinkDialog extends StatefulWidget {
  const _ProviderLinkDialog({
    required this.provider,
    required this.controller,
    required this.defaultRedirectUri,
  });

  final CloudProvider provider;
  final AppController controller;
  final String defaultRedirectUri;

  @override
  State<_ProviderLinkDialog> createState() => _ProviderLinkDialogState();
}

class _ProviderLinkDialogState extends State<_ProviderLinkDialog> {
  late final TextEditingController _redirect = TextEditingController(
    text: widget.defaultRedirectUri,
  );
  final TextEditingController _code = TextEditingController();
  CloudLinkStart? _start;
  bool _busy = false;

  @override
  void dispose() {
    _redirect.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _getLink() async {
    setState(() => _busy = true);
    final start = await widget.controller.startProviderLink(
      widget.provider,
      redirectUri: _redirect.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _start = start;
    });
  }

  Future<void> _complete() async {
    final start = _start;
    if (start == null) {
      return;
    }
    setState(() => _busy = true);
    final ok = await widget.controller.completeProviderLink(
      provider: widget.provider,
      state: start.state,
      authorizationCode: _code.text.trim(),
      redirectUri: _redirect.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = _start;
    final authUrl = start?.authorizationUrl;
    return AlertDialog(
      title: Text('Link ${widget.provider.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _redirect,
              decoration: const InputDecoration(
                labelText: 'Redirect URI',
                helperText:
                    'Must match the OAuth client registered on the server.',
              ),
            ),
            const SizedBox(height: 12),
            if (authUrl == null)
              FilledButton(
                onPressed: _busy ? null : _getLink,
                child: const Text('Get authorization link'),
              )
            else ...[
              const Text('1. Open this link and authorize:'),
              const SizedBox(height: 4),
              SelectableText(authUrl),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: authUrl)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy link'),
              ),
              const SizedBox(height: 8),
              const Text('2. Paste the authorization code from the redirect:'),
              TextField(
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Authorization code',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        if (authUrl != null)
          FilledButton(
            onPressed: _busy ? null : _complete,
            child: const Text('Complete link'),
          ),
      ],
    );
  }
}

class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.viewModel,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onToggleHighQuality,
    required this.onSendAlert,
  });

  final AppViewModel viewModel;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onToggleHighQuality;
  final VoidCallback onSendAlert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recorder = viewModel.recorder;
    // Drive the live bar from the *instantaneous* level (averageDb = the plugin's
    // amplitude.current), not peakDb (amplitude.max), which is monotonic
    // max-since-start and so latches at the top once you speak loudly once.
    final level = ((recorder.averageDb + 60) / 60).clamp(0.0, 1.0);
    final localCapacitySeconds = viewModel.config.deviceRetentionHours * 3600;
    final localProgress = localCapacitySeconds <= 0
        ? 0.0
        : (viewModel.localWindowDuration.inSeconds / localCapacitySeconds)
              .clamp(0.0, 1.0);
    // Live capture takes the site's orange "REC" accent; idle stays muted green.
    final statusColor = recorder.isRecording
        ? SonusColors.orange500
        : theme.colorScheme.outline;
    final isHighQuality =
        viewModel.config.sampleRate >= AppController.highQualitySampleRate;
    return _Section(
      title: 'Live Capture',
      icon: Icons.mic_none,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  recorder.isRecording ? Icons.mic : Icons.mic_off,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recorder.isRecording ? 'Recording' : 'Stopped',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      recorder.isRecording
                          ? _formatDuration(viewModel.activeRecordingDuration)
                          : '${viewModel.config.deviceRetentionHours} h local window',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (viewModel.isUploading)
                const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Input level', style: theme.textTheme.labelLarge),
              const Spacer(),
              Text(
                '${recorder.averageDb.toStringAsFixed(0)} dB',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: level,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 16),
          _RetentionBar(
            label: 'Local retention',
            value: localProgress,
            leadingValue: _formatDuration(viewModel.localWindowDuration),
            trailingValue: '${viewModel.config.deviceRetentionHours} h',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricChip(
                icon: Icons.phone_android,
                label: 'Local',
                value: StorageEstimate.formatBytes(viewModel.localWindowBytes),
              ),
              _MetricChip(
                icon: Icons.cloud_done,
                label: 'Cloud',
                value: StorageEstimate.formatBytes(viewModel.cloudBytes),
              ),
              _MetricChip(
                icon: Icons.schedule,
                label: 'Local window',
                value: StorageEstimate.formatDurationHours(
                  viewModel.localWindowDuration.inSeconds / 3600,
                ),
              ),
              _MetricChip(
                icon: Icons.pending_actions,
                label: 'Pending',
                value: viewModel.pendingUploads.toString(),
              ),
              _MetricChip(
                icon: Icons.sd_storage,
                label: '500 h estimate',
                value: StorageEstimate.formatBytes(
                  viewModel.estimate.cloudBytes,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // `viewModel.isStarting` spans the whole start flow — including the
              // wait while the OS permission prompts load — so the button shows a
              // spinner instead of looking unresponsive (recorder.isStarting only
              // flips once the mic stream itself begins, after permissions).
              if (viewModel.isStarting || recorder.isStarting)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SonusGradientButton(
                      label: 'Starting…',
                      icon: Icons.fiber_manual_record,
                      onPressed: null,
                    ),
                    SizedBox(width: 10),
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                )
              else
                SonusGradientButton(
                  label: 'Start',
                  icon: Icons.fiber_manual_record,
                  onPressed: recorder.isRecording ? null : onStart,
                ),
              OutlinedButton.icon(
                onPressed: recorder.isRecording || recorder.isStarting
                    ? onStop
                    : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              OutlinedButton.icon(
                onPressed: recorder.isRecording || recorder.isStarting
                    ? onRestart
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Restart'),
              ),
              // High-quality capture toggle. Speaks a spoken cue and, when
              // capture is live, re-opens the mic stream at the new sample rate.
              FilledButton.tonalIcon(
                onPressed: onToggleHighQuality,
                icon: Icon(
                  isHighQuality
                      ? Icons.high_quality
                      : Icons.high_quality_outlined,
                ),
                label: Text(
                  isHighQuality ? 'High quality: On' : 'High quality: Off',
                ),
              ),
              OutlinedButton.icon(
                onPressed: onSendAlert,
                icon: const Icon(Icons.notification_important_outlined),
                label: const Text('Send Alert'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isHighQuality
                ? 'Capturing at ${viewModel.config.sampleRate ~/ 1000} kHz — music-grade fidelity.'
                : 'Capturing at ${viewModel.config.sampleRate ~/ 1000} kHz — battery-friendly voice quality.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureSection extends StatelessWidget {
  const _CaptureSection({
    required this.deviceId,
    required this.uploadEnabled,
    required this.onUploadEnabledChanged,
    required this.deviceRetentionController,
    required this.cloudRetentionController,
    required this.segmentMinutesController,
    required this.overlapSecondsController,
    required this.sampleRateController,
    required this.channelsController,
  });

  final String deviceId;
  final bool uploadEnabled;
  final ValueChanged<bool> onUploadEnabledChanged;
  final TextEditingController deviceRetentionController;
  final TextEditingController cloudRetentionController;
  final TextEditingController segmentMinutesController;
  final TextEditingController overlapSecondsController;
  final TextEditingController sampleRateController;
  final TextEditingController channelsController;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Capture',
      icon: Icons.settings_voice_outlined,
      child: Column(
        children: [
          SelectableText('Device ID: $deviceId'),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: uploadEnabled,
            onChanged: onUploadEnabledChanged,
            title: const Text('Cloud upload'),
          ),
          _NumberField(
            controller: deviceRetentionController,
            label: 'Local retention hours',
          ),
          const SizedBox(height: 12),
          _NumberField(
            controller: cloudRetentionController,
            label: 'Cloud retention hours',
          ),
          const SizedBox(height: 12),
          _NumberField(
            controller: segmentMinutesController,
            label: 'Segment minutes',
          ),
          const SizedBox(height: 12),
          _NumberField(
            controller: overlapSecondsController,
            label: 'Overlap seconds',
            allowZero: true,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  controller: sampleRateController,
                  label: 'Sample rate',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  controller: channelsController,
                  label: 'Channels',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CloudSection extends StatelessWidget {
  const _CloudSection({
    required this.selectedProvider,
    required this.onProviderChanged,
    required this.backendUrlController,
    required this.backendDeviceTokenController,
    required this.s3BucketController,
    required this.s3RegionController,
    required this.s3PrefixController,
    required this.s3EndpointController,
    required this.s3AccessKeyController,
    required this.s3SecretKeyController,
    required this.s3SessionTokenController,
  });

  final CloudProvider selectedProvider;
  final ValueChanged<CloudProvider> onProviderChanged;
  final TextEditingController backendUrlController;
  final TextEditingController backendDeviceTokenController;
  final TextEditingController s3BucketController;
  final TextEditingController s3RegionController;
  final TextEditingController s3PrefixController;
  final TextEditingController s3EndpointController;
  final TextEditingController s3AccessKeyController;
  final TextEditingController s3SecretKeyController;
  final TextEditingController s3SessionTokenController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Section(
      title: 'Cloud storage',
      icon: Icons.cloud_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<CloudProvider>(
            initialValue: selectedProvider,
            decoration: const InputDecoration(
              labelText: 'Storage destination',
              prefixIcon: Icon(Icons.storage_outlined),
            ),
            items: CloudProvider.values
                .map(
                  (provider) => DropdownMenuItem(
                    value: provider,
                    child: Text(provider.label),
                  ),
                )
                .toList(),
            onChanged: (provider) {
              if (provider != null) {
                onProviderChanged(provider);
              }
            },
          ),
          const SizedBox(height: 18),
          Text('Sonus backend', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            selectedProvider.requiresBackend
                ? '${selectedProvider.label} transfers through your Sonus backend.'
                : 'Optional for S3-compatible storage; direct signed uploads are used as a fallback.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: backendUrlController,
            decoration: const InputDecoration(
              labelText: 'Backend URL',
              hintText: 'https://api.example.com',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            validator: _validateOptionalHttpsUrl,
          ),
          const SizedBox(height: 12),
          _SecretTextField(
            controller: backendDeviceTokenController,
            label: 'Backend device token',
            hint: 'Usually issued automatically after sign-in',
          ),
          if (selectedProvider == CloudProvider.s3) ...[
            const SizedBox(height: 18),
            const Divider(),
            const SizedBox(height: 18),
            Text(
              'Direct S3-compatible fallback',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              'For AWS S3, leave the endpoint empty and use its region. For '
              'Cloudflare R2, use region “auto” and the account endpoint '
              'https://<account-id>.r2.cloudflarestorage.com. R2 credentials '
              'must allow object read, write, and delete for this bucket.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: s3BucketController,
              decoration: const InputDecoration(
                labelText: 'Bucket',
                prefixIcon: Icon(Icons.inventory_2_outlined),
              ),
              validator: (value) {
                if ((value ?? '').contains('/')) {
                  return 'Enter the bucket name without slashes.';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: s3RegionController,
                    decoration: const InputDecoration(
                      labelText: 'Region',
                      hintText: 'auto for R2',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: s3PrefixController,
                    decoration: const InputDecoration(
                      labelText: 'Object prefix',
                      hintText: 'audio-dashcam',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: s3EndpointController,
              decoration: const InputDecoration(
                labelText: 'Custom endpoint',
                hintText: 'Required for Cloudflare R2',
                prefixIcon: Icon(Icons.link),
              ),
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              validator: _validateOptionalHttpsUrl,
            ),
            const SizedBox(height: 12),
            _SecretTextField(
              controller: s3AccessKeyController,
              label: 'Access key ID',
              initiallyObscured: false,
            ),
            const SizedBox(height: 12),
            _SecretTextField(
              controller: s3SecretKeyController,
              label: 'Secret access key',
            ),
            const SizedBox(height: 12),
            _SecretTextField(
              controller: s3SessionTokenController,
              label: 'Session token (optional)',
            ),
          ],
        ],
      ),
    );
  }

  String? _validateOptionalHttpsUrl(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty || !uri.hasScheme) {
      return 'Enter a complete URL.';
    }
    final local = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (uri.scheme != 'https' && !(local && uri.scheme == 'http')) {
      return 'Use HTTPS (HTTP is allowed only for localhost).';
    }
    return null;
  }
}

class _SecretTextField extends StatefulWidget {
  const _SecretTextField({
    required this.controller,
    required this.label,
    this.hint,
    this.initiallyObscured = true,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool initiallyObscured;

  @override
  State<_SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<_SecretTextField> {
  late bool _obscured = widget.initiallyObscured;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.key_outlined),
        suffixIcon: widget.initiallyObscured
            ? IconButton(
                tooltip: _obscured
                    ? 'Show ${widget.label}'
                    : 'Hide ${widget.label}',
                onPressed: () => setState(() => _obscured = !_obscured),
                icon: Icon(
                  _obscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              )
            : null,
      ),
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      maxLines: 1,
    );
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recent = entries.take(24).join('\n');
    final latest = entries.isEmpty ? 'No diagnostics yet.' : entries.first;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ExpansionTile(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        collapsedShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        leading: const Icon(Icons.terminal),
        title: const Text('Diagnostics'),
        subtitle: Text(latest, maxLines: 1, overflow: TextOverflow.ellipsis),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              recent.isEmpty ? 'No diagnostics yet.' : recent,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [],
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RetentionBar extends StatelessWidget {
  const _RetentionBar({
    required this.label,
    required this.value,
    required this.leadingValue,
    required this.trailingValue,
  });

  final String label;
  final double value;
  final String leadingValue;
  final String trailingValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const Spacer(),
            Text(
              '$leadingValue / $trailingValue',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 8,
            value: value,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

class _SegmentListItem extends StatelessWidget {
  const _SegmentListItem({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.statusIcon,
    this.statusTooltip,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final IconData? statusIcon;
  final String? statusTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.audio_file_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (statusIcon != null) ...[
            Tooltip(
              message: statusTooltip ?? '',
              child: Icon(
                statusIcon,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(trailing, style: theme.textTheme.labelLarge),
        ],
      ),
    );
  }
}

class _InlineState extends StatelessWidget {
  const _InlineState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.allowZero = false,
  });

  final TextEditingController controller;
  final String label;
  final bool allowZero;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      keyboardType: TextInputType.number,
      validator: (value) {
        final parsed = int.tryParse(value?.trim() ?? '');
        if (parsed == null || parsed < 0 || (!allowZero && parsed == 0)) {
          return allowZero
              ? 'Use zero or a positive number'
              : 'Use a positive number';
        }
        return null;
      },
    );
  }
}

/// Weekly recording schedule editor. Each day gets a horizontal 0–24h timeline
/// the user paints recording windows onto; pre-defining the windows is the
/// consent to record during them. [AppController] registers exact Android
/// alarms and iOS reminders at the barriers; iOS transitions are exact while
/// the app remains alive, while a suspended or terminated app requires the
/// user to reopen it from the reminder.
class _ScheduleSection extends StatefulWidget {
  const _ScheduleSection({required this.config, required this.onChanged});

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;

  @override
  State<_ScheduleSection> createState() => _ScheduleSectionState();
}

class _ScheduleSectionState extends State<_ScheduleSection> {
  late RecordingSchedule _schedule;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _schedule = widget.config.recordingSchedule;
  }

  @override
  void didUpdateWidget(covariant _ScheduleSection old) {
    super.didUpdateWidget(old);
    // Adopt an externally-changed config only when no local edit is pending, so
    // a debounced save round-trip doesn't clobber an in-progress drag.
    if (_debounce == null && widget.config.recordingSchedule != _schedule) {
      _schedule = widget.config.recordingSchedule;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _commit(RecordingSchedule next, {bool immediate = false}) {
    setState(() => _schedule = next);
    _debounce?.cancel();
    if (immediate) {
      _debounce = null;
      widget.onChanged(widget.config.copyWith(recordingSchedule: next));
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _debounce = null;
      widget.onChanged(widget.config.copyWith(recordingSchedule: _schedule));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Section(
      title: 'Recording Schedule',
      icon: Icons.event_available_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Record automatically during the windows you set for each day. '
            'Setting these times is your consent to record then; keep the app '
            'running so iOS can maintain the active audio session. On Android, '
            'Sonus Auris keeps a persistent notification while the schedule is '
            'armed so the microphone can start at the declared windows.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: SonusColors.inkSoft,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Scheduled recording'),
            value: _schedule.enabled,
            onChanged: (value) =>
                _commit(_schedule.copyWith(enabled: value), immediate: true),
          ),
          if (_schedule.enabled) ...[
            const SizedBox(height: 2),
            for (var i = 0; i < 7; i++) ...[
              _DayRow(
                label: RecordingSchedule.dayShortLabels[i],
                day: _schedule.days[i],
                onChanged: (day) => _commit(_schedule.withDay(i, day)),
              ),
              if (i < 6) const Divider(height: 20),
            ],
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.touch_app_outlined,
                  size: 16,
                  color: SonusColors.inkSoft,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Tap an empty area to add a window · double-tap a bar to '
                    'split it · drag a handle onto its neighbour to merge.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: SonusColors.inkSoft,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.label,
    required this.day,
    required this.onChanged,
  });

  final String label;
  final DaySchedule day;
  final ValueChanged<DaySchedule> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 40,
              child: Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Spacer(),
            Text('All day', style: theme.textTheme.bodySmall),
            Checkbox(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              value: day.allDay,
              onChanged: (value) =>
                  onChanged(day.copyWith(allDay: value ?? false)),
            ),
          ],
        ),
        _DayTimeline(day: day, enabled: !day.allDay, onChanged: onChanged),
      ],
    );
  }
}

const double _kTimelineBarHeight = 22;
const double _kTimelineLabelHeight = 14;
const double _kHandleHitRadius = 22;

/// A single day's 0–24h editable timeline. Pure widget (no app deps) so it stays
/// testable and reusable. Resize = drag a window edge handle; split = double-tap
/// a window; create = tap empty track; merge = drag a handle onto its neighbour
/// (overlapping windows fuse via [DaySchedule.normalize] on release).
class _DayTimeline extends StatefulWidget {
  const _DayTimeline({
    required this.day,
    required this.onChanged,
    this.enabled = true,
  });

  final DaySchedule day;
  final ValueChanged<DaySchedule> onChanged;
  final bool enabled;

  @override
  State<_DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<_DayTimeline> {
  // During a handle drag we hold a mutable working copy so the drag is smooth
  // and overlaps are allowed; the merge happens once on release.
  List<RecordingWindow>? _dragWindows;
  int _dragWindowIndex = -1;
  bool _dragIsStart = false;
  double _trackWidth = 1;

  List<RecordingWindow> get _windows =>
      _dragWindows ?? widget.day.normalizedWindows();

  int _minuteAt(double dx) {
    final raw = (dx / _trackWidth) * kMinutesPerDay;
    final snapped = (raw / kScheduleSnapMinutes).round() * kScheduleSnapMinutes;
    return snapped.clamp(0, kMinutesPerDay).toInt();
  }

  double _xFor(int minute) => (minute / kMinutesPerDay) * _trackWidth;

  ({int index, bool isStart})? _handleNear(double dx) {
    var best = _kHandleHitRadius;
    ({int index, bool isStart})? hit;
    final windows = _windows;
    for (var i = 0; i < windows.length; i++) {
      final startDist = (dx - _xFor(windows[i].startMinute)).abs();
      if (startDist <= best) {
        best = startDist;
        hit = (index: i, isStart: true);
      }
      final endDist = (dx - _xFor(windows[i].endMinute)).abs();
      if (endDist <= best) {
        best = endDist;
        hit = (index: i, isStart: false);
      }
    }
    return hit;
  }

  int? _windowIndexAt(double dx) {
    final minute = _minuteAt(dx);
    final windows = _windows;
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].contains(minute)) {
        return i;
      }
    }
    return null;
  }

  void _onPanStart(DragStartDetails details) {
    if (!widget.enabled) {
      return;
    }
    final hit = _handleNear(details.localPosition.dx);
    if (hit == null) {
      return;
    }
    setState(() {
      _dragWindows = List.of(widget.day.normalizedWindows());
      _dragWindowIndex = hit.index;
      _dragIsStart = hit.isStart;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragWindows == null) {
      return;
    }
    final minute = _minuteAt(details.localPosition.dx);
    final w = _dragWindows![_dragWindowIndex];
    setState(() {
      if (_dragIsStart) {
        // Allowed to slide left into a neighbour (→ merge on release); kept a
        // snap-step short of its own end so the window can't invert.
        final start = minute
            .clamp(0, w.endMinute - kScheduleSnapMinutes)
            .toInt();
        _dragWindows![_dragWindowIndex] = w.copyWith(startMinute: start);
      } else {
        final end = minute
            .clamp(w.startMinute + kScheduleSnapMinutes, kMinutesPerDay)
            .toInt();
        _dragWindows![_dragWindowIndex] = w.copyWith(endMinute: end);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    final windows = _dragWindows;
    setState(() {
      _dragWindows = null;
      _dragWindowIndex = -1;
    });
    if (windows != null) {
      widget.onChanged(widget.day.copyWith(windows: windows).normalize());
    }
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (!widget.enabled) {
      return;
    }
    final idx = _windowIndexAt(details.localPosition.dx);
    if (idx == null) {
      return;
    }
    final windows = widget.day.normalizedWindows();
    final w = windows[idx];
    final split = _minuteAt(details.localPosition.dx);
    final rightStart = split + kScheduleSnapMinutes;
    // Need a snap-step of room on each side and a visible gap between the halves.
    if (split - w.startMinute < kScheduleSnapMinutes ||
        w.endMinute - rightStart < kScheduleSnapMinutes) {
      return;
    }
    final next = List.of(windows);
    next[idx] = RecordingWindow(startMinute: w.startMinute, endMinute: split);
    next.insert(
      idx + 1,
      RecordingWindow(startMinute: rightStart, endMinute: w.endMinute),
    );
    widget.onChanged(widget.day.copyWith(windows: next));
  }

  void _onTapUp(TapUpDetails details) {
    if (!widget.enabled) {
      return;
    }
    if (_windowIndexAt(details.localPosition.dx) != null) {
      return; // tap inside an existing window does nothing
    }
    final center = _minuteAt(details.localPosition.dx);
    final start = (center - 30)
        .clamp(0, kMinutesPerDay - kScheduleSnapMinutes)
        .toInt();
    final end = (start + 60)
        .clamp(start + kScheduleSnapMinutes, kMinutesPerDay)
        .toInt();
    final next = List.of(widget.day.normalizedWindows())
      ..add(RecordingWindow(startMinute: start, endMinute: end));
    widget.onChanged(widget.day.copyWith(windows: next).normalize());
  }

  @override
  Widget build(BuildContext context) {
    final windows = widget.day.allDay
        ? const [RecordingWindow(startMinute: 0, endMinute: kMinutesPerDay)]
        : _windows;
    final dragMinute = _dragWindows != null
        ? (_dragIsStart
              ? _dragWindows![_dragWindowIndex].startMinute
              : _dragWindows![_dragWindowIndex].endMinute)
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        _trackWidth = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          onDoubleTapDown: _onDoubleTapDown,
          onHorizontalDragStart: _onPanStart,
          onHorizontalDragUpdate: _onPanUpdate,
          onHorizontalDragEnd: _onPanEnd,
          child: SizedBox(
            height: _kTimelineBarHeight + _kTimelineLabelHeight + 18,
            width: double.infinity,
            child: CustomPaint(
              painter: _TimelinePainter(
                windows: windows,
                enabled: widget.enabled,
                dragMinute: dragMinute,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.windows,
    required this.enabled,
    this.dragMinute,
  });

  final List<RecordingWindow> windows;
  final bool enabled;
  final int? dragMinute;

  static const _hourMarks = [0, 6, 12, 18, 24];

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final barTop = _kTimelineLabelHeight + 2;
    final barRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, barTop, width, _kTimelineBarHeight),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      barRect,
      Paint()..color = enabled ? SonusColors.green50 : const Color(0xFFEDEDED),
    );

    // Filled windows (clipped to the rounded track).
    canvas.save();
    canvas.clipRRect(barRect);
    final fill = Paint()
      ..color = enabled ? SonusColors.green500 : const Color(0xFFC4C4C4);
    for (final w in windows) {
      final sx = (w.startMinute / kMinutesPerDay) * width;
      final ex = (w.endMinute / kMinutesPerDay) * width;
      canvas.drawRect(
        Rect.fromLTRB(sx, barTop, ex, barTop + _kTimelineBarHeight),
        fill,
      );
    }
    canvas.restore();

    // Hour gridlines + labels.
    final tickPaint = Paint()
      ..color = SonusColors.hairline
      ..strokeWidth = 1;
    for (final h in _hourMarks) {
      final x = (h / 24) * width;
      canvas.drawLine(
        Offset(x.clamp(0.5, width - 0.5), barTop),
        Offset(x.clamp(0.5, width - 0.5), barTop + _kTimelineBarHeight),
        tickPaint,
      );
      final tp = TextPainter(
        text: TextSpan(text: _hourLabel(h), style: _tickStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = h == 0 ? 0.0 : (h == 24 ? width - tp.width : x - tp.width / 2);
      tp.paint(canvas, Offset(lx, barTop + _kTimelineBarHeight + 2));
    }

    // Edge handles.
    if (enabled) {
      final handlePaint = Paint()..color = SonusColors.green700;
      for (final w in windows) {
        for (final m in [w.startMinute, w.endMinute]) {
          final x = ((m / kMinutesPerDay) * width).clamp(3.0, width - 3.0);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(x, barTop + _kTimelineBarHeight / 2),
                width: 6,
                height: _kTimelineBarHeight + 8,
              ),
              const Radius.circular(3),
            ),
            handlePaint,
          );
        }
      }
    }

    // Empty-day hint.
    if (enabled && windows.isEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'Tap to add a recording window',
          style: _tickStyle.copyWith(color: SonusColors.inkSoft),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          (width - tp.width) / 2,
          barTop + (_kTimelineBarHeight - tp.height) / 2,
        ),
      );
    }

    // Floating time label on the handle being dragged.
    if (dragMinute != null) {
      final x = (dragMinute! / kMinutesPerDay) * width;
      final tp = TextPainter(
        text: TextSpan(
          text: _formatMinuteOfDay(dragMinute!),
          style: const TextStyle(
            color: SonusColors.paper,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (x - tp.width / 2 - 4).clamp(0.0, width - tp.width - 8);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(lx, 0, tp.width + 8, _kTimelineLabelHeight),
          const Radius.circular(4),
        ),
        Paint()..color = SonusColors.ink,
      );
      tp.paint(canvas, Offset(lx + 4, 1));
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      old.enabled != enabled ||
      old.dragMinute != dragMinute ||
      !_windowListEquals(old.windows, windows);
}

const TextStyle _tickStyle = TextStyle(
  color: SonusColors.inkSoft,
  fontSize: 9,
  fontWeight: FontWeight.w600,
);

bool _windowListEquals(List<RecordingWindow> a, List<RecordingWindow> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

String _hourLabel(int hour) {
  if (hour == 0 || hour == 24) {
    return '12a';
  }
  if (hour == 12) {
    return '12p';
  }
  return hour < 12 ? '${hour}a' : '${hour - 12}p';
}

String _formatMinuteOfDay(int minute) {
  final m = minute.clamp(0, kMinutesPerDay);
  // 1440 (end-of-day midnight) reads as 12:00 AM.
  final dt = DateTime(2020, 1, 1).add(Duration(minutes: m % kMinutesPerDay));
  return DateFormat.jm().format(dt);
}

/// Wake-on-event triggers: meaningful events (Bluetooth, Wi-Fi/network changes,
/// nearby devices) prompt for consent to record — only while idle and inside an
/// active [RecordingSchedule] window.
class _ContextTriggersSection extends StatelessWidget {
  const _ContextTriggersSection({
    required this.config,
    required this.onChanged,
    required this.controller,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;
  final AppController controller;

  void _setEnabled(bool value) {
    if (value) {
      // Make sure the permissions the armed triggers need are granted.
      unawaited(
        controller.requestContextTriggerPermissions(
          config.contextTriggerKindSet,
        ),
      );
    }
    onChanged(config.copyWith(contextTriggersEnabled: value));
  }

  void _toggleKind(ContextTriggerKind kind, bool on) {
    final kinds = config.contextTriggerKindSet;
    final next = {...kinds};
    if (on) {
      next.add(kind);
      // Request this trigger's permissions as soon as it's armed.
      unawaited(controller.requestContextTriggerPermissions(next));
    } else {
      next.remove(kind);
    }
    onChanged(
      config.copyWith(
        contextTriggerKinds: next.map((k) => k.wireName).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = config.contextTriggerKindSet;
    final scheduleOff = !config.recordingSchedule.enabled;
    return _Section(
      title: 'Wake-on-Event Triggers',
      icon: Icons.radar_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Let meaningful events ask you to start recording — but only when '
            'you are not already recording and only inside an active schedule '
            'window. Each prompt asks for your explicit consent first.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: SonusColors.inkSoft,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ask to record on events'),
            value: config.contextTriggersEnabled,
            onChanged: _setEnabled,
          ),
          if (config.contextTriggersEnabled) ...[
            if (scheduleOff)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: SonusColors.orange200,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: SonusColors.orange600,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Triggers only fire inside a scheduled window. Turn on '
                        'the Recording Schedule above and add a window.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            for (final kind in ContextTriggerKind.values)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(kind.label),
                value: selected.contains(kind),
                onChanged: (value) => _toggleKind(kind, value ?? false),
              ),
            const SizedBox(height: 4),
            Text(
              'Bluetooth and nearby-device detection request Bluetooth (and, for '
              'Wi-Fi names, location) permission. Nearby-device scanning uses more '
              'battery and only runs during your scheduled windows.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: SonusColors.inkSoft,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.icon,
  });

  final String eyebrow;
  final String title;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: SonusColors.markGradient,
              borderRadius: BorderRadius.circular(15),
              boxShadow: kSonusShadowSm,
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SonusEyebrow(eyebrow),
                const SizedBox(height: 7),
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.icon});

  final String title;
  final Widget child;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon == null)
                  Container(
                    width: 4,
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: SonusColors.markGradient,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  )
                else
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      icon,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SignInNotice extends StatelessWidget {
  const _SignInNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_circle,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Not signed in. Open the Configure tab to sign in with Supabase and back up recordings to your account.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 148, minHeight: 64),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
