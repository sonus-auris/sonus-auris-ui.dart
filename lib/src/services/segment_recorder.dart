import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';
import 'package:rxdart/rxdart.dart';
import 'package:uuid/uuid.dart';

import '../models/acoustic_detection.dart';
import '../models/audio_trigger_event.dart';
import '../models/app_config.dart';
import '../models/recorder_snapshot.dart';
import '../models/recording_segment.dart';
import 'acoustic/acoustic_pipeline.dart';
import 'acoustic/spectral_features.dart';
import 'acoustic_analyzer.dart';
import 'capture_resume_coordinator.dart';
import 'segment_index.dart';
import 'wav_segment_writer.dart';

/// Build-time gate. Pass `--dart-define=SONUS_DISABLE_INTERRUPTION_RESUME=true`
/// to make the auto-resume safety net a complete no-op (A/B / fallback).
const bool _kInterruptionResumeDisabled =
    bool.fromEnvironment('SONUS_DISABLE_INTERRUPTION_RESUME');

class SegmentRecorder {
  SegmentRecorder({
    AudioRecorder? recorder,
    required SegmentIndex segmentIndex,
    AcousticAnalyzer? analyzer,
    Uuid? uuid,
    bool? autoResumeAfterInterruption,
    CaptureResumeCoordinator? resumeCoordinator,
  }) : this._(
          recorder ?? AudioRecorder(),
          segmentIndex,
          analyzer ?? AcousticAnalyzer(),
          uuid ?? const Uuid(),
          resumeCoordinator ??
              CaptureResumeCoordinator(
                enabled: autoResumeAfterInterruption ??
                    !_kInterruptionResumeDisabled,
              ),
        );

  SegmentRecorder._(
    this._recorder,
    this._segmentIndex,
    this._analyzer,
    this._uuid,
    this._resume,
  );

  final AudioRecorder _recorder;
  final SegmentIndex _segmentIndex;
  final AcousticAnalyzer _analyzer;
  final Uuid _uuid;

  // Auto-resume safety net: keeps an unattended (overnight) capture alive across
  // phone calls, alarms, Siri, and media-services resets. See
  // [CaptureResumeCoordinator]. A no-op when disabled.
  final CaptureResumeCoordinator _resume;
  Timer? _resumeWatchdog;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  final BehaviorSubject<RecorderSnapshot> _snapshot = BehaviorSubject.seeded(
    const RecorderSnapshot.idle(),
  );
  final PublishSubject<RecordingSegment> _closedSegments = PublishSubject();
  final PublishSubject<AudioTriggerEvent> _triggerEvents = PublishSubject();

  StreamSubscription<void>? _recordStreamSubscription;
  StreamSubscription<dynamic>? _amplitudeSubscription;
  Completer<void>? _streamDone;
  AppConfig? _config;
  DateTime? _captureStartedAtUtc;
  String? _captureSessionId;
  WavSegmentWriter? _writer;
  DateTime? _writerStartedAtUtc;
  String? _writerPath;
  Uint8List _overlapBytes = Uint8List(0);
  Uint8List _remainderBytes = Uint8List(0);
  int _currentOverlapSamples = 0;
  int _currentUniqueSamples = 0;
  int _currentStartSample = 0;
  int _totalLiveSamples = 0;
  int _sequence = 0;
  int _commotionSamples = 0;
  DateTime? _lastCommotionAlertUtc;
  bool _running = false;
  bool _stopping = false;
  _AudioDsp? _dsp;

  // Capture-rate geometry. The mic may run faster than [AppConfig.sampleRate]
  // when adaptive quality is on, so all segmentation math uses these.
  int _captureRate = 16000;
  int _samplesPerSegment = 16000 * 60;
  int _overlapSamples = 0;

  /// When true, a sleep session is active: the acoustic engine runs the
  /// sleep-cycle detector and analysis is *continuous* (the loudness gate is held
  /// open), because sleep is mostly quiet and depth must be tracked through quiet
  /// stretches. Set by the controller before (re)starting capture.
  bool sleepModeActive = false;

  // Acoustic-analysis loudness gate ("kick in once decibels are sustained").
  bool _analysisActive = false;
  bool _sleepContinuous = false;
  bool _gateOpen = false;
  int _gateLoudSamples = 0;
  int _gateQuietSamples = 0;
  int _gateSustainSamples = 0;
  int _gateHoldSamples = 0;
  double _gateActivationDb = -40;
  int _analyzerDecimFactor = 1;
  _MonoDownsampler? _analyzerDownsampler;

  // Adaptive quality: the rate the *current* segment is being stored at, and the
  // decimator (null when storing at full capture rate).
  int _storeRate = 16000;
  int _storeFactor = 1;
  _Pcm16Downsampler? _storeDownsampler;
  int _storedOverlapSamples = 0;
  double? _recentDb; // EMA of slice loudness, drives the per-segment decision.

  // Rolling buffer of recently captured (processed) audio for Shazam / STT.
  final List<Uint8List> _recentChunks = [];
  int _recentBytes = 0;
  static const double _recentWindowSeconds = 8;

  ValueStream<RecorderSnapshot> get snapshots => _snapshot.stream;

  Stream<RecordingSegment> get closedSegments => _closedSegments.stream;

  Stream<AudioTriggerEvent> get triggerEvents => _triggerEvents.stream;

  /// Fires (with a short reason) when capture should be restarted to recover
  /// from an interruption or stall it could not resume on its own. The owner
  /// (app controller) decides whether to act, applying its own back-off.
  Stream<String> get resumeRequests => _resume.resumeRequests;

  /// Acoustic-intelligence detections from the on-device FFT engine.
  Stream<AcousticDetection> get detections => _analyzer.detections;

  bool get isRecording => _running;

  /// The most recent [window] of captured audio (processed PCM16), or null when
  /// nothing has been captured yet. Used to fingerprint music / transcribe
  /// speech without re-reading files.
  ({Uint8List bytes, int sampleRate, int channels})? recentAudio({
    Duration window = const Duration(seconds: 6),
  }) {
    if (_recentChunks.isEmpty) {
      return null;
    }
    final config = _config;
    final channels = config?.channels ?? 1;
    final wanted = (_captureRate * channels * 2 * window.inMilliseconds / 1000)
        .round();
    final builder = BytesBuilder(copy: false);
    for (final chunk in _recentChunks) {
      builder.add(chunk);
    }
    var bytes = builder.toBytes();
    if (bytes.length > wanted && wanted > 0) {
      bytes = Uint8List.sublistView(bytes, bytes.length - wanted);
    }
    return (bytes: bytes, sampleRate: _captureRate, channels: channels);
  }

  Future<void> start(AppConfig config) async {
    if (_running) {
      return;
    }
    _snapshot.add(_snapshot.value.copyWith(isStarting: true, error: null));
    try {
      await _configureAudioSession();
      final hasPermission = await _recorder.hasPermission(request: true);
      if (!hasPermission) {
        throw StateError('Microphone permission was not granted.');
      }
      final supported = await _recorder.isEncoderSupported(
        AudioEncoder.pcm16bits,
      );
      if (!supported) {
        throw StateError(
          'PCM16 stream recording is not supported on this device.',
        );
      }
      _resetCaptureState(config);
      _running = true;
      if (_analysisActive) {
        await _analyzer.start(
          sampleRate: config.analyzerSampleRate,
          fftSize: config.analyzerFftSize,
          flags: AcousticDetectorFlags(
            snore: config.snoreDetectionEnabled,
            // During a sleep session only the sleep (+snore) detectors run:
            // music/speech are off to save battery overnight and avoid attempting
            // any speech transcription while the user sleeps.
            music: sleepModeActive ? false : config.musicDetectionEnabled,
            speech: sleepModeActive ? false : config.speechDetectionEnabled,
            sleep: sleepModeActive,
          ),
          captureSessionId: _captureSessionId ?? '',
        );
      }
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _captureRate,
          numChannels: config.channels,
          // Music capture keeps dynamics: platform AGC/denoise default off.
          autoGain: config.autoGain,
          echoCancel: false,
          noiseSuppress: config.noiseSuppress,
          audioInterruption: AudioInterruptionMode.pauseResume,
          streamBufferSize: _streamBufferSize(config),
        ),
      );
      _streamDone = Completer<void>();
      _recordStreamSubscription = stream
          .asyncMap(_handlePcmBytes)
          .listen(
            (_) {},
            onError: (Object error) {
              // A stream error mid-recording (e.g. media services reset) is a
              // recoverable death, not a deliberate stop: ask to restart while
              // the coordinator still considers us recording.
              if (!_stopping) {
                _resume.onCaptureError(DateTime.now().toUtc());
              }
              _snapshot.add(
                _snapshot.value.copyWith(
                  isRecording: false,
                  isStarting: false,
                  error: error.toString(),
                ),
              );
              _running = false;
              _completeStreamDone();
            },
            onDone: _completeStreamDone,
            cancelOnError: false,
          );
      _snapshot.add(
        RecorderSnapshot(
          isRecording: true,
          isStarting: false,
          activeSegmentStartedAtUtc: _captureStartedAtUtc,
        ),
      );
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 500))
          .listen((amplitude) {
            final current = _snapshot.value;
            _snapshot.add(
              current.copyWith(
                averageDb: amplitude.current,
                peakDb: amplitude.max,
                error: null,
              ),
            );
          });
      await _startResumeGuard();
    } catch (error) {
      _running = false;
      await _analyzer.stop();
      _snapshot.add(
        const RecorderSnapshot.idle().copyWith(error: error.toString()),
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    if ((!_running && _writer == null) || _stopping) {
      return;
    }
    _stopping = true;
    _running = false;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    // Disarm the auto-resume guard before tearing the stream down so the stop
    // we are about to perform is not mistaken for an interruption to recover.
    await _stopResumeGuard();
    try {
      if (await _recorder.isRecording() || await _recorder.isPaused()) {
        await _recorder.stop();
      }
      final done = _streamDone;
      if (done != null && !done.isCompleted) {
        await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
      }
      await _flushRemainder();
      await _finishActiveSegment();
      await _recordStreamSubscription?.cancel();
      _recordStreamSubscription = null;
      if (_analysisActive) {
        _analyzer.flush();
        await _analyzer.stop();
      }
    } finally {
      _gateOpen = false;
      _analysisActive = false;
      _stopping = false;
      _snapshot.add(const RecorderSnapshot.idle());
    }
  }

  Future<void> dispose() async {
    // [stop] must finish first: it drains the stream, flushes the final segment
    // (emitting into _closedSegments), stops the analyzer feed, and disarms the
    // resume guard. After it the rest are independent resource releases, so run
    // them concurrently. Future.wait still waits for all to settle before it
    // surfaces any error, so nothing is left half-disposed.
    await stop();
    await Future.wait([
      _resume.dispose(),
      _analyzer.dispose(),
      _snapshot.close(),
      _closedSegments.close(),
      _triggerEvents.close(),
      _recorder.dispose(),
    ]);
  }

  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp,
        avAudioSessionMode: AVAudioSessionMode.measurement,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      ),
    );
    await session.setActive(true);
  }

  /// Arms the auto-resume safety net for the freshly opened stream: a periodic
  /// liveness watchdog plus an OS interruption listener. Fully skipped (no
  /// timer, no subscription) when the feature is gated off, so capture behaves
  /// exactly as before.
  Future<void> _startResumeGuard() async {
    if (!_resume.enabled) {
      return;
    }
    _resume.start(DateTime.now().toUtc());
    await _interruptionSubscription?.cancel();
    final session = await AudioSession.instance;
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      // Ducking lowers other apps' volume but does not stop our capture.
      if (event.type == AudioInterruptionType.duck) {
        return;
      }
      if (event.begin) {
        _resume.onInterruptionBegin();
      } else {
        _resume.onInterruptionEnd(DateTime.now().toUtc());
      }
    });
    _resumeWatchdog?.cancel();
    _resumeWatchdog = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _resume.tick(DateTime.now().toUtc()),
    );
  }

  Future<void> _stopResumeGuard() async {
    _resumeWatchdog?.cancel();
    _resumeWatchdog = null;
    await _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
    _resume.stop();
  }

  void _resetCaptureState(AppConfig config) {
    _config = config;
    _captureStartedAtUtc = DateTime.now().toUtc();
    _captureSessionId = _uuid.v4();
    _captureRate = config.effectiveCaptureSampleRate;
    _samplesPerSegment = config.samplesPerSegmentAt(_captureRate);
    _overlapSamples = config.overlapSamplesAt(_captureRate);
    _writer = null;
    _writerStartedAtUtc = null;
    _writerPath = null;
    _overlapBytes = Uint8List(0);
    _remainderBytes = Uint8List(0);
    _currentOverlapSamples = 0;
    _currentUniqueSamples = 0;
    _currentStartSample = 0;
    _totalLiveSamples = 0;
    _sequence = 0;
    _commotionSamples = 0;
    _lastCommotionAlertUtc = null;
    _dsp = _AudioDsp.fromConfig(config);
    _recentChunks.clear();
    _recentBytes = 0;
    _recentDb = null;
    _storeRate = _captureRate;
    _storeFactor = 1;
    _storeDownsampler = null;

    // Acoustic gate setup. A sleep session forces analysis on and continuous.
    _sleepContinuous = sleepModeActive;
    _analysisActive = config.hasAcousticAnalysis || sleepModeActive;
    _gateOpen = false;
    _gateLoudSamples = 0;
    _gateQuietSamples = 0;
    _gateActivationDb = config.analysisActivationDb;
    _gateSustainSamples = (config.analysisSustainSeconds * _captureRate).round();
    _gateHoldSamples = (config.analysisHoldSeconds * _captureRate).round();
    _analyzerDecimFactor = config.analyzerDecimationFactor;
    _analyzerDownsampler = _analysisActive && _analyzerDecimFactor > 1
        ? _MonoDownsampler(_analyzerDecimFactor, _captureRate.toDouble())
        : null;
  }

  int _streamBufferSize(AppConfig config) {
    final frameSize = config.channels * 2;
    final frames = (_captureRate / 10).round().clamp(512, 4096);
    return frames * frameSize;
  }

  Future<void> _handlePcmBytes(Uint8List bytes) async {
    final config = _config;
    if (!_running || config == null || bytes.isEmpty) {
      return;
    }
    // Audio is flowing — tell the resume watchdog capture is alive.
    if (_resume.enabled) {
      _resume.notifyChunk(DateTime.now().toUtc());
    }
    final frameSize = config.channels * 2;
    final data = _consumeAlignedFrames(bytes, frameSize);
    var offset = 0;
    while (offset < data.length && _running) {
      await _ensureWriter();
      final writer = _writer;
      if (writer == null) {
        return;
      }
      final remainingSamples = _samplesPerSegment - _currentUniqueSamples;
      if (remainingSamples <= 0) {
        await _finishActiveSegment();
        continue;
      }
      final availableSamples = (data.length - offset) ~/ frameSize;
      final takeSamples = math.min(availableSamples, remainingSamples);
      if (takeSamples <= 0) {
        return;
      }
      final end = offset + takeSamples * frameSize;
      final rawSlice = Uint8List.sublistView(data, offset, end);
      // Apply client-side gain + tone shaping so stored audio, overlap, and the
      // loudness trigger all see the same processed signal.
      final slice = _dsp?.process(rawSlice, config.channels) ?? rawSlice;
      // Write at the segment's stored rate (decimated for quiet segments).
      final store = _storeDownsampler;
      await writer.write(store == null ? slice : store.process(slice));
      _currentUniqueSamples += takeSamples;
      _totalLiveSamples += takeSamples;
      _rememberOverlap(slice, _overlapSamples, frameSize);
      _rememberRecent(slice);
      final power = _pcmPower(slice);
      _detectCommotion(slice, takeSamples, power);
      _updateAdaptiveLoudness(power);
      _runAcousticGate(slice, takeSamples, config, power);
      offset = end;
      if (_currentUniqueSamples >= _samplesPerSegment) {
        await _finishActiveSegment();
      }
    }
  }

  Uint8List _consumeAlignedFrames(Uint8List bytes, int frameSize) {
    final combined = _remainderBytes.isEmpty
        ? bytes
        : Uint8List.fromList([..._remainderBytes, ...bytes]);
    final alignedLength = combined.length - combined.length % frameSize;
    if (alignedLength == combined.length) {
      _remainderBytes = Uint8List(0);
      return combined;
    }
    _remainderBytes = Uint8List.fromList(combined.sublist(alignedLength));
    return Uint8List.fromList(combined.sublist(0, alignedLength));
  }

  Future<void> _flushRemainder() async {
    final config = _config;
    if (config == null || _remainderBytes.isEmpty) {
      _remainderBytes = Uint8List(0);
      return;
    }
    final frameSize = config.channels * 2;
    final alignedLength =
        _remainderBytes.length - _remainderBytes.length % frameSize;
    if (alignedLength > 0) {
      final aligned = Uint8List.fromList(
        _remainderBytes.sublist(0, alignedLength),
      );
      _remainderBytes = Uint8List(0);
      final wasRunning = _running;
      _running = true;
      await _handlePcmBytes(aligned);
      _running = wasRunning;
    }
    _remainderBytes = Uint8List(0);
  }

  Future<void> _ensureWriter() async {
    if (_writer != null) {
      return;
    }
    final config = _config;
    final captureStartedAt = _captureStartedAtUtc;
    if (config == null || captureStartedAt == null) {
      return;
    }
    _currentStartSample = _totalLiveSamples;
    _currentUniqueSamples = 0;
    _currentOverlapSamples = math.min(
      _overlapBytes.length ~/ (config.channels * 2),
      _overlapSamples,
    );
    // Decide the stored quality for this segment from the trailing loudness.
    _chooseStoreRate(config);
    final startedAtUtc = _timeForSample(_currentStartSample);
    final path = await _segmentIndex.createSegmentPath(
      startedAtUtc,
      extension: '.wav',
    );
    final writer = await WavSegmentWriter.open(
      path: path,
      sampleRate: _storeRate,
      channels: config.channels,
    );
    final store = _storeDownsampler;
    if (_currentOverlapSamples > 0) {
      final overlap = store == null ? _overlapBytes : store.process(_overlapBytes);
      await writer.write(overlap);
    }
    _storedOverlapSamples = writer.sampleCount;
    _writer = writer;
    _writerStartedAtUtc = startedAtUtc;
    _writerPath = path;
    _snapshot.add(
      _snapshot.value.copyWith(
        isRecording: true,
        isStarting: false,
        activeSegmentPath: path,
        activeSegmentStartedAtUtc: startedAtUtc,
        error: null,
      ),
    );
  }

  /// Picks the stored sample rate for the next segment. With adaptive quality
  /// off, this is always the capture rate (a no-op decimator). With it on, a
  /// trailing-quiet segment is stored downsampled to save space while loud
  /// segments keep full quality.
  void _chooseStoreRate(AppConfig config) {
    if (!config.adaptiveQualityEnabled) {
      _storeRate = _captureRate;
      _storeFactor = 1;
      _storeDownsampler = null;
      return;
    }
    // Until we have a trailing-loudness reading, keep full quality (treat the
    // first segment as loud) rather than needlessly downsampling startup audio.
    final loud = (_recentDb ?? config.adaptiveLoudnessDb) >=
        config.adaptiveLoudnessDb;
    if (loud) {
      _storeRate = _captureRate;
      _storeFactor = 1;
      _storeDownsampler = null;
      return;
    }
    final factor = (_captureRate / config.quietSampleRate).round().clamp(1, 16);
    if (factor <= 1) {
      _storeRate = _captureRate;
      _storeFactor = 1;
      _storeDownsampler = null;
      return;
    }
    _storeFactor = factor;
    _storeRate = _captureRate ~/ factor;
    _storeDownsampler = _Pcm16Downsampler(
      factor,
      config.channels,
      _captureRate.toDouble(),
    );
  }

  Future<void> _finishActiveSegment() async {
    final config = _config;
    final writer = _writer;
    final path = _writerPath;
    final startedAtUtc = _writerStartedAtUtc;
    if (config == null ||
        writer == null ||
        path == null ||
        startedAtUtc == null) {
      return;
    }
    _writer = null;
    _writerPath = null;
    _writerStartedAtUtc = null;
    if (_currentUniqueSamples <= 0) {
      await writer.cancel();
      return;
    }
    final file = await writer.close();
    final stat = await file.exists() ? await file.stat() : null;
    final endedAtUtc = _timeForSample(
      _currentStartSample + _currentUniqueSamples,
    );
    final storedTotal = writer.sampleCount;
    final storedUnique = math.max(0, storedTotal - _storedOverlapSamples);
    final segment = RecordingSegment(
      id: SegmentIndex.safeSegmentId(startedAtUtc),
      startedAtUtc: startedAtUtc,
      endedAtUtc: endedAtUtc,
      captureSessionId: _captureSessionId ?? '',
      sequence: _sequence,
      sampleRate: _storeRate,
      channels: config.channels,
      startSample: _currentStartSample ~/ _storeFactor,
      sampleCount: storedUnique,
      storedSampleCount: storedTotal,
      overlapSamples: _storedOverlapSamples,
      container: 'wav',
      codec: 'pcm_s16le',
      localPath: path,
      byteSize: stat?.size ?? 0,
      uploadStatus: SegmentUploadStatus.pending,
    );
    _sequence += 1;
    _currentUniqueSamples = 0;
    _currentOverlapSamples = 0;
    if (segment.byteSize > 0) {
      _closedSegments.add(segment);
    }
  }

  void _rememberOverlap(Uint8List bytes, int overlapSamples, int frameSize) {
    final overlapBytes = overlapSamples * frameSize;
    if (overlapBytes <= 0) {
      _overlapBytes = Uint8List(0);
      return;
    }
    final combined = Uint8List.fromList([..._overlapBytes, ...bytes]);
    if (combined.length <= overlapBytes) {
      _overlapBytes = combined;
      return;
    }
    _overlapBytes = Uint8List.fromList(
      combined.sublist(combined.length - overlapBytes),
    );
  }

  void _rememberRecent(Uint8List slice) {
    final config = _config;
    if (config == null) {
      return;
    }
    final maxBytes =
        (_captureRate * config.channels * 2 * _recentWindowSeconds).round();
    _recentChunks.add(Uint8List.fromList(slice));
    _recentBytes += slice.length;
    while (_recentBytes > maxBytes && _recentChunks.length > 1) {
      _recentBytes -= _recentChunks.removeAt(0).length;
    }
  }

  void _updateAdaptiveLoudness(_PcmPower power) {
    final db = _dbForRms(power.averagePower);
    _recentDb = _recentDb == null ? db : (0.9 * _recentDb! + 0.1 * db);
  }

  /// Implements the "kick in once decibels get consistently high" gate and feeds
  /// the analysis isolate while it is open (including quiet stretches, so gaps
  /// between snores are observed for apnea detection).
  void _runAcousticGate(
    Uint8List slice,
    int samples,
    AppConfig config,
    _PcmPower power,
  ) {
    if (!_analysisActive) {
      return;
    }
    // Sleep session: keep the gate permanently open so depth is tracked through
    // quiet sleep (the loudness gate would otherwise idle the engine).
    if (_sleepContinuous) {
      if (!_gateOpen) {
        _gateOpen = true;
        _analyzer.resyncFeed();
      }
      _feedAnalyzer(slice, config);
      return;
    }
    final db = _dbForRms(power.averagePower);
    final loud = db >= _gateActivationDb;
    if (!_gateOpen) {
      if (loud) {
        _gateLoudSamples += samples;
      } else {
        _gateLoudSamples = math.max(0, _gateLoudSamples - samples);
      }
      if (_gateLoudSamples >= _gateSustainSamples) {
        _gateOpen = true;
        _gateQuietSamples = 0;
        _analyzer.resyncFeed();
      } else {
        return;
      }
    }
    // Gate is open: feed audio and track how long it has been quiet.
    _feedAnalyzer(slice, config);
    if (loud) {
      _gateQuietSamples = 0;
    } else {
      _gateQuietSamples += samples;
      if (_gateQuietSamples >= _gateHoldSamples) {
        _gateOpen = false;
        _gateLoudSamples = 0;
        _analyzer.flush();
      }
    }
  }

  void _feedAnalyzer(Uint8List slice, AppConfig config) {
    final mono = pcm16BytesToMonoDoubles(slice, config.channels);
    if (mono.isEmpty) {
      return;
    }
    final down = _analyzerDownsampler;
    final decimated = down == null ? mono : down.process(mono);
    if (decimated.isEmpty) {
      return;
    }
    // The first sample of this slice corresponds to the current live position
    // minus the samples we just added.
    final sliceStart = _totalLiveSamples - (slice.length ~/ (config.channels * 2));
    _analyzer.addMonoSamples(decimated, _timeForSample(sliceStart));
  }

  void _detectCommotion(Uint8List bytes, int samples, _PcmPower stats) {
    final config = _config;
    final sessionId = _captureSessionId;
    if (config == null || sessionId == null || bytes.length < 2) {
      return;
    }
    // Higher sensitivity (0..1) lowers the loudness thresholds and the time the
    // sound must be sustained before the "commotion" alert fires.
    final sensitivity = config.noiseTriggerSensitivity.clamp(0.0, 1.0);
    final avgThreshold = 0.30 - 0.26 * sensitivity;
    final peakThreshold = 0.95 - 0.55 * sensitivity;
    final loud =
        stats.averagePower >= avgThreshold || stats.peakPower >= peakThreshold;
    if (loud) {
      _commotionSamples += samples;
    } else {
      _commotionSamples = math.max(0, _commotionSamples - samples);
    }
    final sustainSeconds = (5.0 - 4.0 * sensitivity).clamp(1.0, 5.0);
    final sustainedSamples = (_captureRate * sustainSeconds).round();
    if (_commotionSamples < sustainedSamples) {
      return;
    }
    final occurredAt = _timeForSample(_totalLiveSamples);
    final lastAlert = _lastCommotionAlertUtc;
    if (lastAlert != null &&
        occurredAt.difference(lastAlert) < const Duration(minutes: 2)) {
      return;
    }
    _lastCommotionAlertUtc = occurredAt;
    _commotionSamples = 0;
    _triggerEvents.add(
      AudioTriggerEvent(
        type: AudioTriggerType.commotion,
        occurredAtUtc: occurredAt,
        captureSessionId: sessionId,
        sampleIndex: _totalLiveSamples,
        averagePower: stats.averagePower,
        peakPower: stats.peakPower,
      ),
    );
  }

  _PcmPower _pcmPower(Uint8List bytes) {
    var sumSquares = 0.0;
    var peak = 0.0;
    var count = 0;
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
      final value = data.getInt16(offset, Endian.little);
      final normalized = value.abs() / 32768.0;
      peak = math.max(peak, normalized);
      sumSquares += normalized * normalized;
      count += 1;
    }
    if (count == 0) {
      return const _PcmPower(averagePower: 0, peakPower: 0);
    }
    return _PcmPower(
      averagePower: math.sqrt(sumSquares / count),
      peakPower: peak,
    );
  }

  double _dbForRms(double rms) {
    if (rms <= 0) {
      return -120;
    }
    return (20 * math.log(rms) / math.ln10).clamp(-120.0, 0.0);
  }

  DateTime _timeForSample(int sample) {
    final captureStartedAt = _captureStartedAtUtc;
    if (captureStartedAt == null || _captureRate <= 0) {
      return DateTime.now().toUtc();
    }
    return captureStartedAt.add(
      Duration(microseconds: sample * 1000000 ~/ _captureRate),
    );
  }

  void _completeStreamDone() {
    final done = _streamDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }
}

class _PcmPower {
  const _PcmPower({required this.averagePower, required this.peakPower});

  final double averagePower;
  final double peakPower;
}

/// Client-side audio shaping for int16 PCM: a linear input gain followed by an
/// optional 3-band tone control (low shelf / mid peak / high shelf). Filter
/// state is kept per channel across slices so segment boundaries stay seamless.
class _AudioDsp {
  _AudioDsp._(this._gain, this._stages, int channels)
    : _states = List.generate(
        _stages.length,
        (_) => List.generate(channels, (_) => _BiquadState()),
      );

  final double _gain;
  final List<_Biquad> _stages;
  final List<List<_BiquadState>> _states;

  static _AudioDsp? fromConfig(AppConfig config) {
    if (!config.hasAudioDsp) {
      return null;
    }
    final fs = config.effectiveCaptureSampleRate.toDouble();
    final stages = <_Biquad>[];
    if (config.bassGainDb != 0.0) {
      stages.add(_Biquad.lowShelf(fs, 120, config.bassGainDb));
    }
    if (config.midGainDb != 0.0) {
      stages.add(_Biquad.peaking(fs, 1000, 0.9, config.midGainDb));
    }
    if (config.trebleGainDb != 0.0) {
      stages.add(_Biquad.highShelf(fs, 6000, config.trebleGainDb));
    }
    return _AudioDsp._(config.micSensitivity, stages, config.channels.clamp(1, 2));
  }

  Uint8List process(Uint8List frameBytes, int channels) {
    final out = Uint8List.fromList(frameBytes);
    final view = ByteData.sublistView(out);
    final sampleCount = out.length ~/ 2;
    for (var i = 0; i < sampleCount; i++) {
      final channel = channels <= 1 ? 0 : i % channels;
      var sample = view.getInt16(i * 2, Endian.little) / 32768.0;
      sample *= _gain;
      for (var s = 0; s < _stages.length; s++) {
        sample = _states[s][channel].process(_stages[s], sample);
      }
      var scaled = (sample * 32768.0).round();
      if (scaled > 32767) {
        scaled = 32767;
      } else if (scaled < -32768) {
        scaled = -32768;
      }
      view.setInt16(i * 2, scaled, Endian.little);
    }
    return out;
  }
}

/// Anti-aliased integer downsampler for normalized mono doubles. Used to feed
/// the FFT analyzer at ~16 kHz regardless of the capture rate.
class _MonoDownsampler {
  _MonoDownsampler(this.factor, double fs)
      : _lp = _Biquad.lowPass(fs, 0.45 * fs / factor, 0.707),
        _state = _BiquadState();

  final int factor;
  final _Biquad _lp;
  final _BiquadState _state;
  int _phase = 0;

  Float64List process(Float64List input) {
    if (factor <= 1) {
      return input;
    }
    final out = <double>[];
    for (final x in input) {
      final y = _state.process(_lp, x);
      if (_phase == 0) {
        out.add(y);
      }
      _phase = (_phase + 1) % factor;
    }
    return Float64List.fromList(out);
  }
}

/// Anti-aliased integer downsampler for interleaved PCM16. Used to store quiet
/// segments at a lower sample rate. Per-channel filter state and the decimation
/// phase persist across calls so a segment's stream stays continuous.
class _Pcm16Downsampler {
  _Pcm16Downsampler(this.factor, this.channels, double fs)
      : _lp = _Biquad.lowPass(fs, 0.45 * fs / factor, 0.707),
        _states = List.generate(channels < 1 ? 1 : channels, (_) => _BiquadState());

  final int factor;
  final int channels;
  final _Biquad _lp;
  final List<_BiquadState> _states;
  int _phase = 0;

  Uint8List process(Uint8List bytes) {
    if (factor <= 1) {
      return bytes;
    }
    final ch = channels < 1 ? 1 : channels;
    final view = ByteData.sublistView(bytes);
    final frames = bytes.length ~/ (ch * 2);
    final out = BytesBuilder();
    final frame = ByteData(ch * 2);
    for (var f = 0; f < frames; f++) {
      final keep = _phase == 0;
      for (var c = 0; c < ch; c++) {
        var s = view.getInt16((f * ch + c) * 2, Endian.little) / 32768.0;
        s = _states[c].process(_lp, s);
        if (keep) {
          var v = (s * 32768.0).round();
          if (v > 32767) {
            v = 32767;
          } else if (v < -32768) {
            v = -32768;
          }
          frame.setInt16(c * 2, v, Endian.little);
        }
      }
      if (keep) {
        out.add(frame.buffer.asUint8List(0, ch * 2));
      }
      _phase = (_phase + 1) % factor;
    }
    return out.toBytes();
  }
}

/// Normalized (a0 == 1) biquad coefficients from the RBJ audio EQ cookbook.
class _Biquad {
  const _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;

  factory _Biquad.lowPass(double fs, double f0, double q) {
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha;
    final b1 = 1 - cosW0;
    return _Biquad(
      (b1 / 2) / a0,
      b1 / a0,
      (b1 / 2) / a0,
      (-2 * cosW0) / a0,
      (1 - alpha) / a0,
    );
  }

  factory _Biquad.peaking(double fs, double f0, double q, double gainDb) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final a0 = 1 + alpha / a;
    return _Biquad(
      (1 + alpha * a) / a0,
      (-2 * cosW0) / a0,
      (1 - alpha * a) / a0,
      (-2 * cosW0) / a0,
      (1 - alpha / a) / a0,
    );
  }

  factory _Biquad.lowShelf(double fs, double f0, double gainDb) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / 2 * math.sqrt2;
    final twoSqrtAAlpha = 2 * math.sqrt(a) * alpha;
    final a0 = (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha;
    return _Biquad(
      (a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha)) / a0,
      (2 * a * ((a - 1) - (a + 1) * cosW0)) / a0,
      (a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha)) / a0,
      (-2 * ((a - 1) + (a + 1) * cosW0)) / a0,
      ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha) / a0,
    );
  }

  factory _Biquad.highShelf(double fs, double f0, double gainDb) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / 2 * math.sqrt2;
    final twoSqrtAAlpha = 2 * math.sqrt(a) * alpha;
    final a0 = (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha;
    return _Biquad(
      (a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha)) / a0,
      (-2 * a * ((a - 1) + (a + 1) * cosW0)) / a0,
      (a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha)) / a0,
      (2 * ((a - 1) - (a + 1) * cosW0)) / a0,
      ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha) / a0,
    );
  }
}

class _BiquadState {
  double _x1 = 0;
  double _x2 = 0;
  double _y1 = 0;
  double _y2 = 0;

  double process(_Biquad c, double x) {
    final y =
        c.b0 * x + c.b1 * _x1 + c.b2 * _x2 - c.a1 * _y1 - c.a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
