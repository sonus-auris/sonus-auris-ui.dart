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
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';

import 'src/app/app_controller.dart';
import 'src/app/app_view_model.dart';
import 'src/platform/desktop_autostart.dart';

const _green = Color(0xFF1FAA6C);
const _greenBright = Color(0xFF34C585);
const _orange = Color(0xFFFD7E14);
const _bg = Color(0xFF0A241C);
const _panel = Color(0xFF0C2A22);
const _paper = Color(0xFFFFFDF8);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SonusDesktopApp());
}

class SonusDesktopApp extends StatefulWidget {
  const SonusDesktopApp({super.key});

  @override
  State<SonusDesktopApp> createState() => _SonusDesktopAppState();
}

class _SonusDesktopAppState extends State<SonusDesktopApp> {
  late final AppController _controller;
  late final Future<void> _ready;
  FlutterExceptionHandler? _previousFlutterOnError;
  ui.ErrorCallback? _previousPlatformOnError;

  @override
  void initState() {
    super.initState();
    DesktopAutostart.setup();
    _controller = AppController();
    _installTelemetryErrorHooks(_controller);
    // On desktop, behave like an always-on recorder: register as a login item
    // (first run) and start capturing as soon as the app opens.
    _ready = _controller.init().then((_) async {
      await DesktopAutostart.enableByDefaultOnce();
      await _controller.startRecording();
    });
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
    FlutterError.onError = _previousFlutterOnError;
    ui.PlatformDispatcher.instance.onError = _previousPlatformOnError;
    unawaited(_controller.dispose());
    super.dispose();
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
          return _DesktopRoot(controller: _controller);
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

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppViewModel>(
      stream: widget.controller.viewModels,
      builder: (context, snapshot) {
        final vm = snapshot.data;
        if (vm == null || vm.isInitializing) {
          return const _Loading();
        }
        return Scaffold(
          body: Row(
            children: [
              _SideRail(
                selected: _section,
                signedInEmail: vm.signedInEmail,
                onSelect: (i) => setState(() => _section = i),
                onAccount: () => _accountAction(vm),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: _section == 0
                      ? _ThisDevicePanel(controller: widget.controller, vm: vm)
                      : _AllDevicesPanel(vm: vm),
                ),
              ),
            ],
          ),
        );
      },
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
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign in'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: email,
              decoration: const InputDecoration(labelText: 'Email'),
              autofocus: true,
            ),
            TextField(
              controller: pin,
              decoration: const InputDecoration(labelText: '6-digit PIN'),
              obscureText: true,
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.signInWithSupabase(
        email: email.text.trim(),
        password: pin.text.trim(),
      );
    }
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.selected,
    required this.signedInEmail,
    required this.onSelect,
    required this.onAccount,
  });

  final int selected;
  final String? signedInEmail;
  final ValueChanged<int> onSelect;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
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
          _NavItem(
            icon: Icons.mic,
            label: 'This Device',
            active: selected == 0,
            onTap: () => onSelect(0),
          ),
          _NavItem(
            icon: Icons.devices,
            label: 'All Devices',
            active: selected == 1,
            onTap: () => onSelect(1),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onAccount,
            icon: Icon(signedInEmail == null ? Icons.login : Icons.logout),
            label: Text(signedInEmail == null ? 'Sign in' : 'Sign out'),
          ),
          if (signedInEmail != null)
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: active ? _greenBright : Colors.white70,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: active ? _paper : Colors.white70,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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

class _AllDevicesPanel extends StatelessWidget {
  const _AllDevicesPanel({required this.vm});
  final AppViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.devices_other, size: 56, color: _greenBright),
            const SizedBox(height: 16),
            const Text(
              'All devices',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              vm.isSignedIn
                  ? 'As the master viewer, this app will browse and play audio '
                        'from every device on your account — decrypted on-device '
                        'with your account key, unlocked by your PIN. Coming next.'
                  : 'Sign in to use this desktop as your account’s master viewer '
                        'and browse audio from all your devices.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
