// Desktop entrypoint for Sonus Auris.
//
// Run with:  flutter run -d macos -t lib/main_desktop.dart
//        or: flutter build macos -t lib/main_desktop.dart   (windows / linux)
//
// This is a *separate entrypoint* from the phone app (`main.dart`). The mobile
// and desktop builds share the entire core — `AppController`, all services,
// crypto, and models — but present completely different UIs and emphasise
// different roles:
//
//   * phone   (main.dart)         → touch UI, records THIS device.
//   * desktop (main_desktop.dart) → windowed UI; records this device today and
//     is the home of the future "All devices" master viewer (browse + decrypt
//     every device's audio with the account private key — see MULTI_DEVICE.md;
//     the pure-Rust `desktop.app.rs` owns that role too).
//
// Keeping them as distinct entrypoints means desktop look *and* logic can
// diverge freely without leaking the phone layout onto the desktop.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show FlutterExceptionHandler, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:record/record.dart' show InputDevice;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart'
    as interfaces;
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/app_controller.dart';
import 'src/app/app_view_model.dart';
import 'src/models/cloud_connection.dart';
import 'src/models/cloud_provider.dart';
import 'src/models/consent.dart';
import 'src/platform/desktop_autostart.dart';
import 'src/services/cloud_oauth_flow.dart';
import 'src/services/supabase_device_presence_client.dart';
import 'src/widgets/supabase_auth_form.dart';
import 'src/widgets/mandatory_mfa_gate.dart';

const _green = Color(0xFF1FAA6C);
const _greenBright = Color(0xFF34C585);
const _orange = Color(0xFFFD7E14);
const _bg = Color(0xFF0A241C);
const _panel = Color(0xFF0C2A22);
const _paper = Color(0xFFFFFDF8);
const _desktopPreferredInputKey = 'desktop.preferred_input.v1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  runApp(const SonusDesktopApp());
}

class SonusDesktopApp extends StatefulWidget {
  const SonusDesktopApp({super.key});

  @override
  State<SonusDesktopApp> createState() => _SonusDesktopAppState();
}

class _SonusDesktopAppState extends State<SonusDesktopApp>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  late final AppController _controller;
  late final Future<void> _ready;
  Future<void>? _controllerDisposal;
  FlutterExceptionHandler? _previousFlutterOnError;
  ui.ErrorCallback? _previousPlatformOnError;
  bool _trayReady = false;
  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DesktopAutostart.setup();
    _controller = AppController();
    _installTelemetryErrorHooks(_controller);
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_configureDesktopBackgroundMode());
    // On desktop, behave like an always-on recorder only after the user has
    // accepted the current recording disclosure. The controller independently
    // enforces the same rule for every manual/scheduled start.
    _ready = _controller.init();
    unawaited(_startAlwaysOnRecorderAfterInit());
  }

  Future<void> _startAlwaysOnRecorderAfterInit() async {
    try {
      await _ready;
      if (_controller.hasValidRecordingConsent) {
        await _startAlwaysOnRecorder();
      }
    } catch (error, stack) {
      _controller.recordUnhandledError(
        error,
        stack,
        event: 'desktop_startup_recording_error',
      );
    }
  }

  Future<void> _configureDesktopBackgroundMode() async {
    await windowManager.setPreventClose(true);
    try {
      final icon = defaultTargetPlatform == TargetPlatform.windows
          ? 'windows/runner/resources/app_icon.ico'
          : 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png';
      await trayManager.setIcon(icon);
      await trayManager.setToolTip('Sonus Auris — background recorder');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open Sonus Auris'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Sonus Auris'),
          ],
        ),
      );
      _trayReady = true;
    } catch (error, stack) {
      _controller.recordUnhandledError(
        error,
        stack,
        event: 'desktop_tray_setup_error',
      );
      // Close falls back to minimizing so the app never becomes unreachable.
      _trayReady = false;
    }
  }

  Future<void> _showDesktopWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quitDesktopApp() async {
    if (_quitting) return;
    _quitting = true;
    await windowManager.setPreventClose(false);
    await trayManager.destroy();
    await _disposeController();
    await windowManager.destroy();
  }

  Future<void> _disposeController() {
    return _controllerDisposal ??= _controller.dispose();
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_trayReady) {
      unawaited(
        windowManager.hide().then((_) => windowManager.setSkipTaskbar(true)),
      );
    } else {
      unawaited(windowManager.minimize());
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showDesktopWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(_showDesktopWindow());
      case 'quit':
        unawaited(_quitDesktopApp());
    }
  }

  Future<void> _startAlwaysOnRecorder() async {
    await DesktopAutostart.enableByDefaultOnce();
    final prefs = await SharedPreferences.getInstance();
    final preferredInput = prefs.getString(_desktopPreferredInputKey);
    try {
      await _controller.selectInputDevice(preferredInput);
    } catch (_) {
      // A disconnected USB/Bluetooth microphone must not prevent capture.
      await _controller.selectInputDevice(null);
    }
    await _controller.startRecording();
  }

  Future<void> _acceptDesktopConsent() async {
    final record = ConsentRecord(
      consentVersion: kConsentVersion,
      acceptedAtUtc: DateTime.now().toUtc(),
      platform: _desktopPlatformName(),
      grants: {for (final item in ConsentItem.values) item.key: item.required},
    );
    await _controller.completeOnboarding(record);
    await _startAlwaysOnRecorder();
  }

  void _installTelemetryErrorHooks(AppController controller) {
    _previousFlutterOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      controller.recordFlutterError(details);
      _previousFlutterOnError?.call(details);
    };
    _previousPlatformOnError = ui.PlatformDispatcher.instance.onError;
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
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    FlutterError.onError = _previousFlutterOnError;
    ui.PlatformDispatcher.instance.onError = _previousPlatformOnError;
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller.refreshSupabaseSessionForAppResume());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _green,
      brightness: Brightness.dark,
    ).copyWith(surface: _bg, secondary: _orange);
    return MaterialApp(
      title: 'Sonus Auris',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: _bg,
        useMaterial3: true,
      ),
      home: FutureBuilder<void>(
        future: _ready,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Loading();
          }
          return ValueListenableBuilder<bool>(
            valueListenable: _controller.onboardingComplete,
            builder: (context, consented, _) => consented
                ? _DesktopRoot(controller: _controller)
                : _DesktopConsentGate(onAccept: _acceptDesktopConsent),
          );
        },
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _DesktopRoot extends StatefulWidget {
  const _DesktopRoot({required this.controller});
  final AppController controller;

  @override
  State<_DesktopRoot> createState() => _DesktopRootState();
}

class _DesktopRootState extends State<_DesktopRoot> {
  int _section = 0;
  bool _accountRailExpanded = true;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppViewModel>(
      stream: widget.controller.viewModels,
      builder: (context, snapshot) {
        final vm = snapshot.data;
        if (vm == null || vm.isInitializing) {
          return const _Loading();
        }
        if (vm.hasSupabaseSession && !vm.isSignedIn) {
          return MandatoryMfaGate(controller: widget.controller);
        }
        return Scaffold(
          body: Row(
            children: [
              _AccountRail(
                expanded: _accountRailExpanded,
                signedInEmail: vm.signedInEmail,
                onToggle: () => setState(
                  () => _accountRailExpanded = !_accountRailExpanded,
                ),
                onSettings: () => setState(() => _section = 2),
                onInfo: _showInfo,
                onAccount: () => _accountAction(vm),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: _body(vm),
                ),
              ),
              const VerticalDivider(width: 1),
              _DesktopTabRail(
                selected: _section,
                onSelect: (i) => setState(() => _section = i),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _body(AppViewModel vm) {
    switch (_section) {
      case 1:
        return _DesktopPlaybackPanel(controller: widget.controller, vm: vm);
      case 2:
        return _DesktopConfigurePanel(controller: widget.controller, vm: vm);
      case 3:
        return _DesktopConnectionsPanel(controller: widget.controller, vm: vm);
      case 4:
        return _DesktopDevicesPanel(controller: widget.controller, vm: vm);
      default:
        return _ThisDevicePanel(controller: widget.controller, vm: vm);
    }
  }

  Future<void> _showInfo() {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Sonus Auris'),
        content: const Text(
          'This desktop recorder keeps a rolling local audio window and can '
          'continue while the window is minimized. Cloud backup is optional.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _accountAction(AppViewModel vm) async {
    if (vm.isSignedIn) {
      await widget.controller.signOutSupabase();
      return;
    }
    await _showSignInDialog();
  }

  Future<void> _showSignInDialog() async {
    final email = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in'),
        content: SizedBox(
          width: 440,
          child: SupabaseAuthForm(
            emailController: email,
            onSendMagicLink: (email) =>
                widget.controller.requestSupabaseEmailOtp(email: email),
            onVerifyCode: (email, code) => widget.controller
                .confirmSupabaseEmailOtp(email: email, code: code),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    email.dispose();
  }
}

class _AccountRail extends StatelessWidget {
  const _AccountRail({
    required this.expanded,
    required this.signedInEmail,
    required this.onToggle,
    required this.onSettings,
    required this.onInfo,
    required this.onAccount,
  });

  final bool expanded;
  final String? signedInEmail;
  final VoidCallback onToggle;
  final VoidCallback onSettings;
  final VoidCallback onInfo;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: expanded ? 232 : 68,
      color: _panel,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _green,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.graphic_eq, size: 20, color: _bg),
              ),
              const SizedBox(width: 10),
              if (expanded)
                const Expanded(
                  child: Text(
                    'Sonus Auris',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: _paper,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          IconButton(
            tooltip: expanded
                ? 'Collapse account sidebar'
                : 'Expand account sidebar',
            onPressed: onToggle,
            icon: Icon(expanded ? Icons.chevron_left : Icons.chevron_right),
          ),
          if (expanded) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: const Text('Profile'),
              subtitle: Text(signedInEmail ?? 'Signed out'),
            ),
            TextButton.icon(
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Settings'),
            ),
            TextButton.icon(
              onPressed: onInfo,
              icon: const Icon(Icons.info_outline),
              label: const Text('Info & privacy'),
            ),
          ],
          const Spacer(),
          if (expanded)
            OutlinedButton.icon(
              onPressed: onAccount,
              icon: Icon(signedInEmail == null ? Icons.login : Icons.logout),
              label: Text(signedInEmail == null ? 'Sign in' : 'Sign out'),
            )
          else
            IconButton(
              tooltip: signedInEmail == null ? 'Sign in' : 'Sign out',
              onPressed: onAccount,
              icon: Icon(signedInEmail == null ? Icons.login : Icons.logout),
            ),
          if (expanded && signedInEmail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                signedInEmail!,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopTabRail extends StatelessWidget {
  const _DesktopTabRail({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (Icons.home_outlined, 'Home'),
      (Icons.play_circle_outline, 'Playback'),
      (Icons.tune_outlined, 'Configure'),
      (Icons.cloud_outlined, 'Connections'),
      (Icons.devices_other_outlined, 'Devices'),
    ];
    return Container(
      width: 176,
      color: _panel,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Workspace',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < tabs.length; index += 1)
            _NavItem(
              icon: tabs[index].$1,
              label: tabs[index].$2,
              active: selected == index,
              onTap: () => onSelect(index),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: active ? _green.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: active ? _greenBright : Colors.white70,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? _paper : Colors.white70,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThisDevicePanel extends StatelessWidget {
  const _ThisDevicePanel({required this.controller, required this.vm});

  final AppController controller;
  final AppViewModel vm;

  @override
  Widget build(BuildContext context) {
    final recording = vm.recorder.isRecording;
    final peak = ((vm.recorder.peakDb + 60) / 60).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          recording ? 'Recording' : 'Stopped',
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        Text(
          'This device · ${vm.config.deviceId.substring(0, vm.config.deviceId.length.clamp(0, 8))}…',
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: recording || vm.recorder.isStarting
                  ? null
                  : controller.startRecording,
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('Record'),
              style: FilledButton.styleFrom(backgroundColor: _greenBright),
            ),
            OutlinedButton.icon(
              onPressed: recording ? controller.stopRecording : null,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            OutlinedButton.icon(
              onPressed: recording ? controller.restartRecording : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Restart'),
            ),
            FilledButton.tonalIcon(
              onPressed: controller.toggleHighQualityRecording,
              icon: const Icon(Icons.high_quality),
              label: Text(
                controller.isHighQualityRecording
                    ? 'High quality: On'
                    : 'High quality: Off',
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Card(
          color: _panel,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Input level',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: peak,
                    minHeight: 10,
                    color: _orange,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _statsGrid(),
      ],
    );
  }

  Widget _statsGrid() {
    String fmt(Duration d) {
      final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
      return h > 0
          ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
          : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    final rows = <(String, String)>[
      ('Local window', fmt(vm.localWindowDuration)),
      ('Retention', '${vm.config.deviceRetentionHours} h'),
      ('Pending uploads', vm.pendingUploads.toString()),
      ('Sample rate', '${vm.config.sampleRate} Hz'),
    ];
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        for (final (label, value) in rows)
          Container(
            width: 168,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DesktopPlaybackPanel extends StatelessWidget {
  const _DesktopPlaybackPanel({required this.controller, required this.vm});

  final AppController controller;
  final AppViewModel vm;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Text(
          'Playback',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const Text(
          'Listen to the rolling window captured on this computer.',
          style: TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: vm.segments.isEmpty
                  ? null
                  : controller.playLocalWindow,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play local window'),
            ),
            OutlinedButton.icon(
              onPressed: vm.playback.isPlaying
                  ? controller.pausePlayback
                  : null,
              icon: const Icon(Icons.pause),
              label: const Text('Pause'),
            ),
            OutlinedButton.icon(
              onPressed: controller.stopPlayback,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          color: _panel,
          child: ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: Text('${vm.segments.length} local segments'),
            subtitle: Text(
              vm.segments.isEmpty
                  ? 'Record some audio to make playback available.'
                  : 'The rolling retention policy removes older segments automatically.',
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopConfigurePanel extends StatefulWidget {
  const _DesktopConfigurePanel({required this.controller, required this.vm});

  final AppController controller;
  final AppViewModel vm;

  @override
  State<_DesktopConfigurePanel> createState() => _DesktopConfigurePanelState();
}

class _DesktopConfigurePanelState extends State<_DesktopConfigurePanel> {
  List<InputDevice> _devices = const [];
  String? _selectedInput;
  bool _launchAtLogin = false;
  late bool _phraseDetectionEnabled;
  late int _phraseBoostMinutes;
  late final TextEditingController _keywordsController;
  late final TextEditingController _safeWordsController;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = widget.vm.config;
    _phraseDetectionEnabled =
        config.acousticAnalysisEnabled && config.speechDetectionEnabled;
    _phraseBoostMinutes = config.keywordQualityBoostMinutes;
    _keywordsController = TextEditingController(
      text: config.keywords.join(', '),
    );
    _safeWordsController = TextEditingController(
      text: config.safeWords.join(', '),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _keywordsController.dispose();
    _safeWordsController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final devices = await widget.controller.listInputDevices();
      final saved = prefs.getString(_desktopPreferredInputKey);
      final selected = devices.any((device) => device.id == saved)
          ? saved
          : null;
      await widget.controller.selectInputDevice(selected);
      final launch = await DesktopAutostart.isEnabled();
      if (mounted) {
        setState(() {
          _devices = devices;
          _selectedInput = selected;
          _launchAtLogin = launch;
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _select(String? value) async {
    setState(() => _busy = true);
    try {
      await widget.controller.selectInputDevice(value);
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_desktopPreferredInputKey);
      } else {
        await prefs.setString(_desktopPreferredInputKey, value);
      }
      if (mounted) setState(() => _selectedInput = value);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setLaunchAtLogin(bool value) async {
    await DesktopAutostart.setEnabled(value);
    final actual = await DesktopAutostart.isEnabled();
    if (mounted) setState(() => _launchAtLogin = actual);
  }

  List<String> _phrases(TextEditingController controller) => controller.text
      .split(',')
      .map((phrase) => phrase.trim())
      .where((phrase) => phrase.isNotEmpty)
      .toList(growable: false);

  Future<void> _saveRecognitionPhrases() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final current = widget.vm.config;
      await widget.controller.saveConfig(
        current.copyWith(
          acousticAnalysisEnabled:
              _phraseDetectionEnabled || current.acousticAnalysisEnabled,
          speechDetectionEnabled: _phraseDetectionEnabled,
          keywords: _phrases(_keywordsController),
          safeWords: _phrases(_safeWordsController),
          keywordQualityBoostMinutes: _phraseBoostMinutes,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recording = widget.vm.recorder.isRecording;
    final phraseWindowOptions = <int>{
      15,
      30,
      60,
      90,
      120,
      180,
      360,
      _phraseBoostMinutes,
    }.toList()..sort();
    return ListView(
      children: [
        const Text(
          'Configure',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const Text(
          'Desktop capture and background behavior',
          style: TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 24),
        Card(
          color: _panel,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Microphone input',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: _selectedInput,
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('System default microphone'),
                    ),
                    for (final device in _devices)
                      DropdownMenuItem<String?>(
                        value: device.id,
                        child: Text(device.label),
                      ),
                  ],
                  onChanged: _busy || recording ? null : _select,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.mic_external_on_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  recording
                      ? 'Stop recording before switching microphones.'
                      : '${_devices.length} connected microphone input(s) detected.',
                  style: const TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh microphones'),
                ),
              ],
            ),
          ),
        ),
        Card(
          color: _panel,
          child: SwitchListTile(
            value: _launchAtLogin,
            onChanged: _setLaunchAtLogin,
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('Launch at login'),
            subtitle: const Text(
              'After recording consent is granted, Sonus Auris starts capture '
              'at login and continues while minimized.',
            ),
          ),
        ),
        Card(
          color: _panel,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recognition phrases',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Keywords and priority safety words are recognized on-device '
                  'when available. A match dings, marks the moment, and keeps '
                  'the rolling recorder at full quality.',
                  style: TextStyle(color: Colors.white54),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable spoken phrase detection'),
                  value: _phraseDetectionEnabled,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _phraseDetectionEnabled = value),
                ),
                TextField(
                  controller: _keywordsController,
                  enabled: !_busy && _phraseDetectionEnabled,
                  decoration: const InputDecoration(
                    labelText: 'Keywords (comma-separated)',
                    hintText: 'contract, chorus, important note',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _safeWordsController,
                  enabled: !_busy && _phraseDetectionEnabled,
                  decoration: const InputDecoration(
                    labelText: 'Safety words (comma-separated)',
                    hintText: 'help, emergency',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: _phraseBoostMinutes,
                  items: [
                    for (final minutes in phraseWindowOptions)
                      DropdownMenuItem(
                        value: minutes,
                        child: Text('$minutes-minute full-quality window'),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _phraseBoostMinutes = value);
                          }
                        },
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveRecognitionPhrases,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save recognition phrases'),
                ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      ],
    );
  }
}

class _DesktopDevicesPanel extends StatefulWidget {
  const _DesktopDevicesPanel({required this.controller, required this.vm});

  final AppController controller;
  final AppViewModel vm;

  @override
  State<_DesktopDevicesPanel> createState() => _DesktopDevicesPanelState();
}

class _DesktopDevicesPanelState extends State<_DesktopDevicesPanel> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.vm.isSignedIn) {
      unawaited(widget.controller.refreshAccountDevices());
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await widget.controller.refreshAccountDevices();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _revoke(interfaces.DeviceRecord device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke device access?'),
        content: Text(
          '${device.displayName} will stop syncing on its next heartbeat. '
          'Its local recordings are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await widget.controller.revokeAccountDevice(device.deviceId);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.vm.isSignedIn) {
      return const Center(
        child: Text('Sign in from the profile sidebar to manage devices.'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Devices',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Supabase live presence with a durable 10-minute heartbeat.',
                    style: TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh devices',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: StreamBuilder<List<interfaces.DeviceRecord>>(
            stream: widget.controller.accountDevices,
            initialData: widget.controller.accountDevicesValue,
            builder: (context, devicesSnapshot) {
              return StreamBuilder<DevicePresenceSnapshot>(
                stream: widget.controller.devicePresence,
                initialData: widget.controller.devicePresenceValue,
                builder: (context, presenceSnapshot) {
                  final devices =
                      devicesSnapshot.data ?? const <interfaces.DeviceRecord>[];
                  final presence =
                      presenceSnapshot.data ?? const DevicePresenceSnapshot();
                  if (devices.isEmpty) {
                    return const Center(child: Text('No devices found.'));
                  }
                  return ListView(
                    children: [
                      for (final device in devices)
                        Card(
                          color: _panel,
                          child: ListTile(
                            leading: Icon(
                              device.platform == 'web'
                                  ? Icons.language
                                  : device.platform == 'android' ||
                                        device.platform == 'ios'
                                  ? Icons.phone_android
                                  : Icons.computer,
                            ),
                            title: Text(device.displayName),
                            subtitle: Text(
                              (device.revokedAt ?? '').trim().isNotEmpty
                                  ? 'Revoked'
                                  : presence.isOnline(device.deviceId)
                                  ? '● Online now · ${device.platform}'
                                  : 'Offline · last seen ${_desktopLastSeen(device.lastSeenAt)}',
                            ),
                            trailing: (device.revokedAt ?? '').trim().isNotEmpty
                                ? null
                                : TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _revoke(device),
                                    child: const Text('Revoke'),
                                  ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

String _desktopLastSeen(String raw) {
  final seen = DateTime.tryParse(raw)?.toLocal();
  if (seen == null) return 'unknown';
  final age = DateTime.now().difference(seen).abs();
  if (age < const Duration(minutes: 2)) return 'just now';
  if (age < const Duration(hours: 1)) return '${age.inMinutes}m ago';
  if (age < const Duration(days: 1)) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

class _DesktopConnectionsPanel extends StatefulWidget {
  const _DesktopConnectionsPanel({required this.controller, required this.vm});

  final AppController controller;
  final AppViewModel vm;

  @override
  State<_DesktopConnectionsPanel> createState() =>
      _DesktopConnectionsPanelState();
}

class _DesktopConnectionsPanelState extends State<_DesktopConnectionsPanel> {
  Future<List<CloudConnection>>? _connections;
  bool _busy = false;
  String? _s3Error;
  bool _showS3Credentials = false;
  late final TextEditingController _s3BucketController;
  late final TextEditingController _s3RegionController;
  late final TextEditingController _s3PrefixController;
  late final TextEditingController _s3EndpointController;
  late final TextEditingController _s3AccessKeyController;
  late final TextEditingController _s3SecretKeyController;
  late final TextEditingController _s3SessionTokenController;

  @override
  void initState() {
    super.initState();
    final config = widget.vm.config;
    final secrets = widget.vm.secrets;
    _s3BucketController = TextEditingController(text: config.s3Bucket);
    _s3RegionController = TextEditingController(text: config.s3Region);
    _s3PrefixController = TextEditingController(text: config.s3Prefix);
    _s3EndpointController = TextEditingController(text: config.s3Endpoint);
    _s3AccessKeyController = TextEditingController(text: secrets.s3AccessKeyId);
    _s3SecretKeyController = TextEditingController(
      text: secrets.s3SecretAccessKey,
    );
    _s3SessionTokenController = TextEditingController(
      text: secrets.s3SessionToken,
    );
    _connections = _loadConnections();
  }

  @override
  void dispose() {
    for (final controller in [
      _s3BucketController,
      _s3RegionController,
      _s3PrefixController,
      _s3EndpointController,
      _s3AccessKeyController,
      _s3SecretKeyController,
      _s3SessionTokenController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<List<CloudConnection>> _loadConnections() {
    if (!widget.vm.isDeviceRegistered) {
      return Future.value(const <CloudConnection>[]);
    }
    return widget.controller.loadCloudConnections();
  }

  void _refresh() {
    setState(() {
      _connections = _loadConnections();
    });
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

  Future<void> _runLocal(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validateS3() {
    final bucket = _s3BucketController.text.trim();
    final accessKey = _s3AccessKeyController.text.trim();
    final secretKey = _s3SecretKeyController.text.trim();
    if (bucket.isEmpty || bucket.contains('/')) {
      return 'Enter a bucket name without slashes.';
    }
    if (accessKey.isEmpty || secretKey.isEmpty) {
      return 'Access key ID and secret access key are both required.';
    }
    final endpoint = _s3EndpointController.text.trim();
    if (endpoint.isNotEmpty) {
      final uri = Uri.tryParse(endpoint);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.trim().isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        return 'The custom endpoint must be a clean HTTPS URL.';
      }
    }
    return null;
  }

  Future<void> _saveS3() async {
    final error = _validateS3();
    if (error != null) {
      setState(() => _s3Error = error);
      return;
    }
    await _run(() async {
      setState(() => _s3Error = null);
      final endpoint = _s3EndpointController.text.trim();
      final looksLikeR2 = endpoint.toLowerCase().contains(
        '.r2.cloudflarestorage.com',
      );
      final region = looksLikeR2
          ? 'auto'
          : (_s3RegionController.text.trim().isEmpty
                ? 'us-east-1'
                : _s3RegionController.text.trim());
      final secrets = widget.vm.secrets.copyWith(
        s3AccessKeyId: _s3AccessKeyController.text,
        s3SecretAccessKey: _s3SecretKeyController.text,
        s3SessionToken: _s3SessionTokenController.text,
      );
      final config = widget.vm.config.copyWith(
        uploadEnabled: true,
        cloudProvider: CloudProvider.s3,
        s3Bucket: _s3BucketController.text,
        s3Region: region,
        s3Prefix: _s3PrefixController.text.trim().isEmpty
            ? 'audio-dashcam'
            : _s3PrefixController.text,
        s3Endpoint: endpoint,
      );
      await widget.controller.saveSecrets(secrets);
      await widget.controller.saveConfig(config);
      await widget.controller.syncDirectStorageConnection();
      if (mounted) _s3RegionController.text = region;
    });
  }

  Future<void> _forgetS3() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget S3/R2 credentials?'),
        content: const Text(
          'This removes the credentials from this device and stops direct '
          'uploads. Existing objects in the bucket are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget credentials'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runLocal(() async {
      await widget.controller.saveSecrets(
        widget.vm.secrets.copyWith(
          s3AccessKeyId: '',
          s3SecretAccessKey: '',
          s3SessionToken: '',
        ),
      );
      await widget.controller.saveConfig(
        widget.vm.config.copyWith(
          uploadEnabled: widget.vm.config.cloudProvider == CloudProvider.s3
              ? false
              : widget.vm.config.uploadEnabled,
          s3Bucket: '',
          s3Endpoint: '',
        ),
      );
      _s3BucketController.clear();
      _s3EndpointController.clear();
      _s3AccessKeyController.clear();
      _s3SecretKeyController.clear();
      _s3SessionTokenController.clear();
      if (mounted) setState(() => _s3Error = null);
      await widget.controller.unlinkDirectStorageConnections();
      if (mounted) _refresh();
    });
  }

  Future<void> _link(CloudProvider provider) => _run(() async {
    if ((Platform.isWindows || Platform.isLinux) &&
        provider != CloudProvider.iCloudDrive) {
      await _linkWithAuthorizationCode(provider);
      return;
    }
    await widget.controller.linkCloudProvider(provider);
  });

  Future<void> _linkWithAuthorizationCode(CloudProvider provider) async {
    final redirect = hostedCloudOAuthManualRedirect(
      widget.vm.config.backendBaseUrl,
    );
    if (redirect == null) {
      _showConnectionMessage(
        '${provider.label} linking needs the production HTTPS backend.',
      );
      return;
    }
    final start = await widget.controller.startProviderLink(
      provider,
      redirectUri: redirect.toString(),
    );
    if (start == null) {
      return;
    }
    final authorizationUrl = Uri.tryParse(start.authorizationUrl ?? '');
    if (authorizationUrl == null ||
        authorizationUrl.scheme != 'https' ||
        authorizationUrl.host.trim().isEmpty) {
      _showConnectionMessage(
        '${provider.label} returned an invalid authorization address.',
      );
      return;
    }
    final opened = await launchUrl(
      authorizationUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!opened || !mounted) {
      _showConnectionMessage('Could not open the ${provider.label} sign-in.');
      return;
    }
    final code = await _requestAuthorizationCode(provider);
    if (code == null || code.trim().isEmpty) {
      return;
    }
    await widget.controller.completeProviderLink(
      provider: provider,
      state: start.state,
      authorizationCode: code.trim(),
      redirectUri: redirect.toString(),
    );
  }

  Future<String?> _requestAuthorizationCode(CloudProvider provider) async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text('Finish linking ${provider.label}'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Approve access in your browser. The Sonus Auris callback '
                  'page will show a one-time authorization code. Paste only '
                  'that code here.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'One-time authorization code',
                  ),
                  onSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      Navigator.pop(dialogContext, value.trim());
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) {
                  Navigator.pop(dialogContext, value);
                }
              },
              child: const Text('Finish linking'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _showConnectionMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmCloudRevoke(CloudConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect cloud backup?'),
        content: Text(
          'Sonus Auris will stop sending new recordings to '
          '${_desktopCloudProviderLabel(connection.provider)}. Existing '
          'files in that cloud account are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() => widget.controller.revokeCloudConnection(connection.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    const providers = [
      CloudProvider.googleDrive,
      CloudProvider.oneDrive,
      CloudProvider.iCloudDrive,
      CloudProvider.dropbox,
    ];
    return ListView(
      children: [
        const Text(
          'Connections',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const Text(
          'Optional user-owned destinations for private backups',
          style: TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 20),
        if (!widget.vm.isDeviceRegistered)
          const Card(
            color: _panel,
            child: ListTile(
              leading: Icon(Icons.cloud_off_outlined),
              title: Text('Sign in and register this device first'),
              subtitle: Text(
                'Cloud OAuth links are attached to your Sonus Auris account.',
              ),
            ),
          )
        else ...[
          FutureBuilder<List<CloudConnection>>(
            future: _connections,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: LinearProgressIndicator(),
                );
              }
              if (snapshot.hasError) {
                return Card(
                  color: _panel,
                  child: ListTile(
                    leading: const Icon(
                      Icons.cloud_off_outlined,
                      color: Colors.orangeAccent,
                    ),
                    title: const Text('Cloud connections are unavailable'),
                    subtitle: Text('${snapshot.error}'),
                    trailing: IconButton(
                      onPressed: _busy ? null : _refresh,
                      tooltip: 'Retry',
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                );
              }
              final linked = snapshot.data ?? const <CloudConnection>[];
              return Column(
                children: [
                  for (final provider in providers)
                    _providerCard(
                      provider,
                      linked
                          .where(
                            (item) =>
                                item.provider == _providerWireName(provider),
                          )
                          .firstOrNull,
                    ),
                ],
              );
            },
          ),
        ],
        _s3ConfigurationCard(),
      ],
    );
  }

  Widget _s3ConfigurationCard() {
    final configured =
        widget.vm.config.s3TargetReady && widget.vm.secrets.hasS3Credentials;
    return Card(
      color: _panel,
      child: ExpansionTile(
        leading: Icon(
          configured ? Icons.cloud_done_outlined : Icons.storage_outlined,
          color: configured ? Colors.greenAccent : Colors.white54,
        ),
        title: const Text('Amazon S3 / Cloudflare R2'),
        subtitle: FutureBuilder<List<CloudConnection>>(
          future: _connections,
          builder: (context, snapshot) {
            final accountConnection = snapshot.data
                ?.where(
                  (item) =>
                      item.provider == 'amazon_s3' ||
                      item.provider == 'cloudflare_r2',
                )
                .firstOrNull;
            final accountLinked = accountConnection?.status == 'active';
            return Text(
              configured && accountLinked
                  ? 'Connected on this device and synced to your Sonus Auris account'
                  : configured
                  ? 'Configured on this device; sign in or retry to sync account status'
                  : accountLinked
                  ? 'Connected to your account; add this device’s credentials to upload'
                  : 'Direct storage works without a Sonus Auris server account',
            );
          },
        ),
        childrenPadding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'For Cloudflare R2, enter the account endpoint; the region is '
              'set to “auto” automatically. Credentials stay in this device’s '
              'secure credential store.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _s3BucketController,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Bucket'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _s3RegionController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Region',
                    hintText: 'us-east-1 or auto',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _s3PrefixController,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Object prefix',
                    hintText: 'audio-dashcam',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _s3EndpointController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Custom HTTPS endpoint (R2)',
              hintText: 'https://<account>.r2.cloudflarestorage.com',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _s3AccessKeyController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: !_showS3Credentials,
            decoration: const InputDecoration(labelText: 'Access key ID'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _s3SecretKeyController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: !_showS3Credentials,
            decoration: const InputDecoration(labelText: 'Secret access key'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _s3SessionTokenController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: !_showS3Credentials,
            decoration: const InputDecoration(
              labelText: 'Session token (optional)',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _showS3Credentials,
            onChanged: _busy
                ? null
                : (value) =>
                      setState(() => _showS3Credentials = value ?? false),
            title: const Text('Show credentials'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          if (_s3Error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _s3Error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _saveS3,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save and use S3/R2'),
              ),
              if (configured)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _forgetS3,
                  icon: const Icon(Icons.key_off_outlined),
                  label: const Text('Forget credentials'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _providerCard(CloudProvider provider, CloudConnection? connection) {
    final linked = connection?.status == 'active';
    final canLinkOnThisDevice =
        provider != CloudProvider.iCloudDrive || Platform.isMacOS;
    final detail = <String>[
      if (linked) 'Connected' else 'Not connected',
      if (connection != null && !linked) 'Status: ${connection.status}',
      if (!linked && !canLinkOnThisDevice)
        'Link from the Sonus Auris app on an Apple device',
      if (connection?.displayName case final displayName?
          when displayName.isNotEmpty)
        displayName,
      if (connection?.folderPath case final folder? when folder.isNotEmpty)
        folder,
      if (connection?.lastSyncAtUtc case final syncedAt?)
        'Last backup ${_desktopLastSeen(syncedAt.toIso8601String())}',
    ].join(' · ');
    return Card(
      color: _panel,
      child: ListTile(
        leading: Icon(
          linked ? Icons.cloud_done_outlined : Icons.cloud_outlined,
          color: linked ? Colors.greenAccent : Colors.white54,
        ),
        title: Text(provider.label),
        subtitle: Text(detail),
        trailing: linked
            ? OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _confirmCloudRevoke(connection!),
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              )
            : FilledButton.tonalIcon(
                onPressed: _busy || !canLinkOnThisDevice
                    ? null
                    : () => _link(provider),
                icon: const Icon(Icons.link),
                label: const Text('Connect'),
              ),
      ),
    );
  }
}

String _providerWireName(CloudProvider provider) {
  switch (provider) {
    case CloudProvider.googleDrive:
      return 'google_drive';
    case CloudProvider.oneDrive:
      return 'microsoft_onedrive';
    case CloudProvider.iCloudDrive:
      return 'apple_icloud';
    case CloudProvider.dropbox:
      return 'dropbox';
    case CloudProvider.s3:
      return 's3';
  }
}

String _desktopCloudProviderLabel(String provider) {
  return switch (provider) {
    'google_drive' => 'Google Drive',
    'microsoft_onedrive' => 'Microsoft OneDrive',
    'apple_icloud' => 'Apple iCloud Drive',
    'dropbox' => 'Dropbox',
    _ => 'this cloud destination',
  };
}

String _desktopPlatformName() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    default:
      return 'desktop';
  }
}

class _DesktopConsentGate extends StatefulWidget {
  const _DesktopConsentGate({required this.onAccept});

  final Future<void> Function() onAccept;

  @override
  State<_DesktopConsentGate> createState() => _DesktopConsentGateState();
}

class _DesktopConsentGateState extends State<_DesktopConsentGate> {
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_accepted || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAccept();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Before Sonus Auris records',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This desktop recorder keeps a rolling local audio buffer. '
                    'It can continue while the app is open and will request '
                    'microphone access from your operating system. Audio is '
                    'encrypted before any optional cloud backup.',
                    style: TextStyle(height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    value: _accepted,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _accepted = value ?? false),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'I consent to microphone audio recording',
                    ),
                    subtitle: const Text(
                      'Required. You can stop recording or revoke microphone access at any time.',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: _accepted && !_busy ? _submit : null,
                      child: Text(
                        _busy ? 'Preparing recorder…' : 'Accept and continue',
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
