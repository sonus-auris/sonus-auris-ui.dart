import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'src/app/app_controller.dart';
import 'src/app/app_view_model.dart';
import 'src/platform/form_factor.dart';
import 'src/models/acoustic_detection.dart';
import 'src/models/app_config.dart';
import 'src/models/cloud_connection.dart';
import 'src/models/cloud_provider.dart';
import 'src/models/storage_estimate.dart';
import 'src/models/transfer_gate_status.dart';
import 'src/models/upload_network_policy.dart';
import 'src/theme/sonus_brand.dart';
import 'src/theme/sonus_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const AudioDashcamRoot());
}

class AudioDashcamRoot extends StatefulWidget {
  const AudioDashcamRoot({super.key});

  @override
  State<AudioDashcamRoot> createState() => _AudioDashcamRootState();
}

class _AudioDashcamRootState extends State<AudioDashcamRoot> {
  late final AppController _controller;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _controller = AppController();
    _initFuture = _controller.init();
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Sonus Auris',
        debugShowCheckedModeBanner: false,
        theme: buildSonusTheme(),
        home: FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LoadingPage();
            }
            if (snapshot.hasError) {
              return ErrorPage(error: snapshot.error.toString());
            }
            return SettingsPage(controller: _controller);
          },
        ),
      ),
    );
  }
}

class LoadingPage extends StatelessWidget {
  const LoadingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: SonusColors.paper,
      body: Center(
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
          child: Text(error, textAlign: TextAlign.center),
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
            child: Column(
              children: [
                if (viewModel.recordingConsentRequest != null)
                  MaterialBanner(
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(viewModel.recordingConsentRequest!.title),
                        Text(
                          viewModel.recordingConsentRequest!.detail,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                    leading: const Icon(Icons.sensors),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            widget.controller.dismissRecordingConsentRequest(
                              viewModel.recordingConsentRequest!.id,
                            ),
                        child: const Text('Not now'),
                      ),
                      FilledButton.icon(
                        onPressed: viewModel.isStarting
                            ? null
                            : () => widget.controller
                                  .approveRecordingConsentRequest(
                                    viewModel.recordingConsentRequest!.id,
                                  ),
                        icon: const Icon(Icons.mic),
                        label: const Text('Start'),
                      ),
                    ],
                  ),
                if (viewModel.message != null)
                  MaterialBanner(
                    content: Text(viewModel.message!),
                    leading: const Icon(Icons.info_outline),
                    actions: [
                      TextButton(
                        onPressed: widget.controller.clearMessage,
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                // Desktop ("recorder on a bigger screen"): same logic, but
                // centered and width-constrained so it reads as a desktop panel
                // rather than a stretched phone. See lib/src/platform/form_factor.
                Expanded(
                  child: Platforms.isDesktop
                      ? Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: Platforms.desktopContentMaxWidth,
                            ),
                            child: _selectedBody(viewModel),
                          ),
                        )
                      : _selectedBody(viewModel),
                ),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedIndex = index);
              _persistSelectedTab(index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.graphic_eq),
                selectedIcon: Icon(Icons.graphic_eq),
                label: 'Playback',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune),
                selectedIcon: Icon(Icons.tune),
                label: 'Configure',
              ),
            ],
          ),
        );
      },
    );
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
              onSignOut: widget.controller.signOutSupabase,
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

  int _parseInt(String value, int fallback) {
    return int.tryParse(value.trim()) ?? fallback;
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

/// Lists recent on-device acoustic detections (snoring, possible apnea patterns,
/// music, speech, keywords). Newest first.
class _DetectionsSection extends StatelessWidget {
  const _DetectionsSection({required this.detections});

  final List<AcousticDetection> detections;

  IconData _icon(AcousticDetectionKind kind) {
    switch (kind) {
      case AcousticDetectionKind.snore:
        return Icons.bedtime;
      case AcousticDetectionKind.apneaPattern:
        return Icons.warning_amber;
      case AcousticDetectionKind.music:
        return Icons.music_note;
      case AcousticDetectionKind.speech:
        return Icons.record_voice_over;
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
      default:
        return time;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Acoustic detections',
      child: detections.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No detections yet. The engine activates when sound '
                'is sustained.',
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
        _Section(
          title: 'Playback',
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        accountSection,
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            final children = [
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
            ];
            if (!wide) {
              return Column(
                children: [
                  children.first,
                  const SizedBox(height: 16),
                  children.last,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: children.first),
                const SizedBox(width: 16),
                Expanded(child: children.last),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _RecordingScheduleSection(
          config: viewModel.config,
          onChanged: onAudioConfigChanged,
        ),
        const SizedBox(height: 16),
        _TransferPolicySection(
          config: viewModel.config,
          status: viewModel.transferStatus,
          onChanged: onAudioConfigChanged,
        ),
        const SizedBox(height: 16),
        _AudioTuningSection(
          config: viewModel.config,
          onChanged: onAudioConfigChanged,
        ),
        const SizedBox(height: 16),
        _MusicMemoriesSection(
          config: viewModel.config,
          onChanged: onAudioConfigChanged,
          controller: controller,
        ),
        const SizedBox(height: 16),
        _AcousticSection(
          config: viewModel.config,
          onChanged: onAudioConfigChanged,
          sttApiKeyController: sttApiKeyController,
        ),
        if (viewModel.isDeviceRegistered) ...[
          const SizedBox(height: 16),
          _CloudLinkSection(controller: controller, viewModel: viewModel),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onSave,
          icon: const Icon(Icons.save),
          label: const Text('Save Configuration'),
        ),
      ],
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
    required this.onSignOut,
  });

  final bool isSignedIn;
  final String? signedInEmail;
  final bool isDeviceRegistered;
  final bool isAwaitingDeviceRegistration;
  final TextEditingController supabaseUrlController;
  final TextEditingController supabaseAnonKeyController;
  final Future<void> Function(String email, String password) onSignIn;
  final Future<void> Function(String email, String password) onSignUp;
  final VoidCallback onSignOut;

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

  Future<void> _run(Future<void> Function(String, String) action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action(_emailController.text.trim(), _passwordController.text);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.isSignedIn) {
      final status = widget.isDeviceRegistered
          ? 'Device registered.'
          : widget.isAwaitingDeviceRegistration
          ? 'Registering device…'
          : 'Set the backend URL to register this device.';
      return _Section(
        title: 'Account',
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
            OutlinedButton.icon(
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      );
    }
    return _Section(
      title: 'Account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sign in with Supabase to record under your account and back up to cloud storage.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.supabaseUrlController,
            decoration: const InputDecoration(
              labelText: 'Supabase URL',
              hintText: 'https://YOUR-PROJECT.supabase.co',
            ),
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.supabaseAnonKeyController,
            decoration: const InputDecoration(labelText: 'Supabase anon key'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailController,
            decoration: const InputDecoration(labelText: 'Email'),
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (_) => _run(widget.onSignIn),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _run(widget.onSignIn),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: const Text('Sign in'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => _run(widget.onSignUp),
                  child: const Text('Create account'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordingScheduleSection extends StatelessWidget {
  const _RecordingScheduleSection({
    required this.config,
    required this.onChanged,
  });

  final AppConfig config;
  final ValueChanged<AppConfig> onChanged;

  void _updateDay(RecordingDaySchedule updated) {
    final days = config.recordingSchedule.normalizedDays
        .map((day) => day.dayOfWeek == updated.dayOfWeek ? updated : day)
        .toList();
    onChanged(
      config.copyWith(recordingSchedule: WeeklyRecordingSchedule(days: days)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = config.recordingSchedule.normalizedDays;
    return _Section(
      title: 'Recording Schedule',
      child: Column(
        children: [
          for (var i = 0; i < days.length; i += 1) ...[
            _ScheduleDayRow(day: days[i], onChanged: _updateDay),
            if (i != days.length - 1) const Divider(height: 22),
          ],
        ],
      ),
    );
  }
}

class _ScheduleDayRow extends StatelessWidget {
  const _ScheduleDayRow({required this.day, required this.onChanged});

  final RecordingDaySchedule day;
  final ValueChanged<RecordingDaySchedule> onChanged;

  static const _labels = <int, String>{
    DateTime.monday: 'Mon',
    DateTime.tuesday: 'Tue',
    DateTime.wednesday: 'Wed',
    DateTime.thursday: 'Thu',
    DateTime.friday: 'Fri',
    DateTime.saturday: 'Sat',
    DateTime.sunday: 'Sun',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Text(
      _labels[day.dayOfWeek] ?? '',
      style: theme.textTheme.titleSmall,
    );
    final allDay = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: day.allDay,
          onChanged: (value) {
            onChanged(day.copyWith(allDay: value ?? false));
          },
        ),
        const Text('All day'),
      ],
    );
    final track = _ScheduleTrack(day: day, onChanged: onChanged);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(width: 56, child: label),
                  allDay,
                ],
              ),
              const SizedBox(height: 8),
              track,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 52, child: label),
            SizedBox(width: 118, child: allDay),
            const SizedBox(width: 12),
            Expanded(child: track),
          ],
        );
      },
    );
  }
}

enum _ScheduleDragKind { start, end, segment }

class _ScheduleDrag {
  const _ScheduleDrag({
    required this.index,
    required this.kind,
    this.minuteOffset = 0,
  });

  final int index;
  final _ScheduleDragKind kind;
  final int minuteOffset;
}

class _ScheduleTrack extends StatefulWidget {
  const _ScheduleTrack({required this.day, required this.onChanged});

  final RecordingDaySchedule day;
  final ValueChanged<RecordingDaySchedule> onChanged;

  @override
  State<_ScheduleTrack> createState() => _ScheduleTrackState();
}

class _ScheduleTrackState extends State<_ScheduleTrack> {
  static const _minWindowMinutes = 15;
  static const _snapMinutes = 15;

  RecordingDaySchedule? _draftDay;
  _ScheduleDrag? _drag;
  Offset? _doubleTapPosition;

  RecordingDaySchedule get _activeDay => _draftDay ?? widget.day;

  @override
  void didUpdateWidget(covariant _ScheduleTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_draftDay != null && widget.day == _draftDay) {
      _draftDay = null;
    } else if (_drag == null && oldWidget.day != widget.day) {
      _draftDay = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_activeDay.allDay;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Semantics(
            label: '${_weekdayName(_activeDay.dayOfWeek)} recording schedule',
            child: MouseRegion(
              cursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTapDown: enabled
                    ? (details) => _doubleTapPosition = details.localPosition
                    : null,
                onDoubleTap: enabled ? _splitOrCreateWindow : null,
                onPanStart: enabled ? _startDrag : null,
                onPanUpdate: enabled ? _updateDrag : null,
                onPanEnd: enabled ? (_) => _finishDrag() : null,
                onPanCancel: enabled ? _finishDrag : null,
                child: CustomPaint(
                  painter: _ScheduleTrackPainter(
                    windows: _activeDay.effectiveWindows,
                    disabled: !enabled,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Text('00'),
            Text('06'),
            Text('12'),
            Text('18'),
            Text('24'),
          ],
        ),
      ],
    );
  }

  void _splitOrCreateWindow() {
    final position = _doubleTapPosition;
    final width = context.size?.width ?? 0;
    if (position == null || width <= 0) {
      return;
    }
    final minute = _snapMinute(_minuteForX(position.dx, width));
    final windows = _activeDay.normalizedWindows.toList();
    final index = windows.indexWhere((window) => window.containsMinute(minute));
    if (index < 0) {
      final start = (minute - 30).clamp(0, RecordingWindow.minutesPerDay - 60);
      windows.add(RecordingWindow(startMinute: start, endMinute: start + 60));
      _setDraft(windows, commit: true);
      return;
    }
    final window = windows[index];
    if (window.endMinute - window.startMinute < _minWindowMinutes * 2) {
      return;
    }
    final split = minute.clamp(
      window.startMinute + _minWindowMinutes,
      window.endMinute - _minWindowMinutes,
    );
    windows
      ..removeAt(index)
      ..insertAll(index, [
        RecordingWindow(startMinute: window.startMinute, endMinute: split),
        RecordingWindow(startMinute: split, endMinute: window.endMinute),
      ]);
    _setDraft(windows, commit: true);
  }

  void _startDrag(DragStartDetails details) {
    final width = context.size?.width ?? 0;
    if (width <= 0) {
      return;
    }
    _drag = _dragFor(details.localPosition, width);
  }

  void _updateDrag(DragUpdateDetails details) {
    final drag = _drag;
    final width = context.size?.width ?? 0;
    if (drag == null || width <= 0) {
      return;
    }
    final windows = _activeDay.normalizedWindows.toList();
    if (drag.index >= windows.length) {
      return;
    }
    final window = windows[drag.index];
    final minute = _snapMinute(_minuteForX(details.localPosition.dx, width));
    switch (drag.kind) {
      case _ScheduleDragKind.start:
        windows[drag.index] = window.copyWith(
          startMinute: minute.clamp(0, window.endMinute - _minWindowMinutes),
        );
        break;
      case _ScheduleDragKind.end:
        windows[drag.index] = window.copyWith(
          endMinute: minute.clamp(
            window.startMinute + _minWindowMinutes,
            RecordingWindow.minutesPerDay,
          ),
        );
        break;
      case _ScheduleDragKind.segment:
        final length = window.endMinute - window.startMinute;
        final start = (minute - drag.minuteOffset).clamp(
          0,
          RecordingWindow.minutesPerDay - length,
        );
        windows[drag.index] = RecordingWindow(
          startMinute: start,
          endMinute: start + length,
        );
        break;
    }
    _setDraft(windows);
  }

  void _finishDrag() {
    final draft = _draftDay;
    _drag = null;
    if (draft != null) {
      widget.onChanged(draft);
    }
  }

  _ScheduleDrag? _dragFor(Offset position, double width) {
    final windows = _activeDay.normalizedWindows;
    _ScheduleDrag? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < windows.length; i += 1) {
      final window = windows[i];
      final startX = _xForMinute(window.startMinute, width);
      final endX = _xForMinute(window.endMinute, width);
      final startDistance = (position.dx - startX).abs();
      final endDistance = (position.dx - endX).abs();
      if (startDistance < bestDistance && startDistance <= 22) {
        best = _ScheduleDrag(index: i, kind: _ScheduleDragKind.start);
        bestDistance = startDistance;
      }
      if (endDistance < bestDistance && endDistance <= 22) {
        best = _ScheduleDrag(index: i, kind: _ScheduleDragKind.end);
        bestDistance = endDistance;
      }
      if (best == null && startX <= position.dx && position.dx <= endX) {
        final minute = _minuteForX(position.dx, width);
        best = _ScheduleDrag(
          index: i,
          kind: _ScheduleDragKind.segment,
          minuteOffset: minute - window.startMinute,
        );
      }
    }
    return best;
  }

  void _setDraft(List<RecordingWindow> windows, {bool commit = false}) {
    final day = _activeDay.copyWith(allDay: false, windows: windows);
    setState(() => _draftDay = day);
    if (commit) {
      widget.onChanged(day);
    }
  }

  int _minuteForX(double x, double width) {
    final ratio = (x / width).clamp(0.0, 1.0);
    return (ratio * RecordingWindow.minutesPerDay).round();
  }

  double _xForMinute(int minute, double width) {
    return width * (minute / RecordingWindow.minutesPerDay);
  }

  int _snapMinute(int minute) {
    final snapped = (minute / _snapMinutes).round() * _snapMinutes;
    return snapped.clamp(0, RecordingWindow.minutesPerDay);
  }

  String _weekdayName(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return 'Monday';
      case DateTime.tuesday:
        return 'Tuesday';
      case DateTime.wednesday:
        return 'Wednesday';
      case DateTime.thursday:
        return 'Thursday';
      case DateTime.friday:
        return 'Friday';
      case DateTime.saturday:
        return 'Saturday';
      case DateTime.sunday:
        return 'Sunday';
    }
    return 'Day';
  }
}

class _ScheduleTrackPainter extends CustomPainter {
  const _ScheduleTrackPainter({required this.windows, required this.disabled});

  final List<RecordingWindow> windows;
  final bool disabled;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackRect = Rect.fromLTWH(0, centerY - 5, size.width, 10);
    final trackRadius = Radius.circular(trackRect.height / 2);
    final basePaint = Paint()
      ..color = disabled ? SonusColors.green50 : const Color(0xFFE8F3EC);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, trackRadius),
      basePaint,
    );

    final tickPaint = Paint()
      ..color = SonusColors.hairline
      ..strokeWidth = 1;
    for (final hour in const [0, 6, 12, 18, 24]) {
      final x = size.width * (hour / 24);
      canvas.drawLine(
        Offset(x, centerY - 14),
        Offset(x, centerY + 14),
        tickPaint,
      );
    }

    for (final window in windows) {
      final left =
          size.width * (window.startMinute / RecordingWindow.minutesPerDay);
      final right =
          size.width * (window.endMinute / RecordingWindow.minutesPerDay);
      final rect = Rect.fromLTRB(left, centerY - 11, right, centerY + 11);
      final activePaint = Paint()
        ..shader = SonusColors.markGradient.createShader(rect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(11)),
        activePaint,
      );
      _paintHandle(canvas, Offset(left, centerY));
      _paintHandle(canvas, Offset(right, centerY));
    }
  }

  void _paintHandle(Canvas canvas, Offset center) {
    final fill = Paint()..color = Colors.white;
    final border = Paint()
      ..color = SonusColors.green700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas
      ..drawCircle(center, 8, fill)
      ..drawCircle(center, 8, border);
  }

  @override
  bool shouldRepaint(covariant _ScheduleTrackPainter oldDelegate) {
    return disabled != oldDelegate.disabled ||
        !_windowsEqual(windows, oldDelegate.windows);
  }

  bool _windowsEqual(List<RecordingWindow> a, List<RecordingWindow> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/// Battery + network controls for cloud streaming. These never affect local
/// capture (the rolling 50h+ window keeps recording); they only defer uploads,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable acoustic analysis'),
            subtitle: const Text(
              'On-device FFT. Activates only when sound is sustained.',
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
    return _Section(
      title: 'Cloud',
      child: Column(
        children: [
          DropdownButtonFormField<CloudProvider>(
            initialValue: selectedProvider,
            decoration: const InputDecoration(labelText: 'Provider'),
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
          const SizedBox(height: 12),
          if (selectedProvider.requiresBackend)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'This provider uploads through the sound recorder backend.',
              ),
            ),
          if (selectedProvider.requiresBackend) const SizedBox(height: 12),
          TextFormField(
            controller: backendUrlController,
            decoration: const InputDecoration(labelText: 'Backend URL'),
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: backendDeviceTokenController,
            decoration: const InputDecoration(
              labelText: 'Backend device token',
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3BucketController,
            decoration: const InputDecoration(labelText: 'S3 bucket'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3RegionController,
            decoration: const InputDecoration(labelText: 'S3 region'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3PrefixController,
            decoration: const InputDecoration(labelText: 'S3 prefix'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3EndpointController,
            decoration: const InputDecoration(
              labelText: 'S3-compatible endpoint',
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3AccessKeyController,
            decoration: const InputDecoration(labelText: 'S3 access key ID'),
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3SecretKeyController,
            decoration: const InputDecoration(
              labelText: 'S3 secret access key',
            ),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: s3SessionTokenController,
            decoration: const InputDecoration(labelText: 'S3 session token'),
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            maxLines: 1,
          ),
        ],
      ),
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
        borderRadius: BorderRadius.circular(8),
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
        borderRadius: BorderRadius.circular(8),
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
        borderRadius: BorderRadius.circular(8),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: SonusColors.hairline),
        borderRadius: BorderRadius.circular(24),
        boxShadow: kSonusShadowSm,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  decoration: BoxDecoration(
                    gradient: SonusColors.markGradient,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 14),
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
          borderRadius: BorderRadius.circular(8),
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
