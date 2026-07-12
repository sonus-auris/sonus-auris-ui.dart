// Wraps just_audio to play back local segments and streams a PlaybackSnapshot of the player state.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../models/playback_snapshot.dart';
import '../models/recording_segment.dart';

class PlaybackService {
  PlaybackService({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _subscriptions.addAll([
      _player.playerStateStream.listen((state) {
        _emit(_snapshot.value.copyWith(isPlaying: state.playing));
      }),
      _player.positionStream.listen((position) {
        _emit(_snapshot.value.copyWith(position: position));
      }),
      _player.durationStream.listen((duration) {
        _emit(_snapshot.value.copyWith(duration: duration ?? Duration.zero));
      }),
      _player.currentIndexStream.listen((index) {
        _emit(_snapshot.value.copyWith(currentIndex: index));
      }),
    ]);
  }

  final AudioPlayer _player;
  final BehaviorSubject<PlaybackSnapshot> _snapshot = BehaviorSubject.seeded(
    const PlaybackSnapshot.empty(),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  ValueStream<PlaybackSnapshot> get snapshots => _snapshot.stream;

  Future<void> playSegments(List<RecordingSegment> segments) async {
    final localSegments =
        segments.where((segment) => segment.localPath != null).toList()
          ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (localSegments.isEmpty) {
      _emit(
        const PlaybackSnapshot.empty().copyWith(
          error: 'No local audio segments are available.',
        ),
      );
      return;
    }
    try {
      // The recorder leaves the shared audio session configured for *capture*
      // (playAndRecord + measurement mode + voiceCommunication usage), which on
      // Android routes output to the earpiece/voice-call stream — so media plays
      // back inaudibly. Switch the session to a media/playback profile (speaker,
      // media volume) before playing, and make sure the player is at full volume.
      await _configureForPlayback();
      await _player.setVolume(1.0);
      await _player.setLoopMode(LoopMode.off);
      await _player.setAudioSources(
        localSegments.map(_sourceForSegment).toList(),
        // Lazy-load sources instead of pulling every WAV into RAM at once — a
        // wide window can be many segments, and a big preload makes the app a
        // bigger target for Android's low-memory killer.
        preload: false,
      );
      _emit(
        _snapshot.value.copyWith(isLoaded: true, error: null, currentIndex: 0),
      );
      await _player.play();
    } catch (error) {
      _emit(_snapshot.value.copyWith(error: error.toString()));
    }
  }

  /// Switch the shared audio session to a media-playback profile so output goes
  /// to the speaker at media volume (the recorder sets a capture profile that
  /// otherwise routes playback to the earpiece). Best-effort: a failure here
  /// shouldn't block playback.
  Future<void> _configureForPlayback() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(true);
    } catch (_) {
      // Leave the session as-is; playback still proceeds.
    }
  }

  /// Play a wall-clock time range `[startUtc, endUtc]` across the rolling window,
  /// stitching together the segments that overlap it (each clipped to the range)
  /// and optionally looping the whole range.
  Future<void> playRange(
    List<RecordingSegment> segments,
    DateTime startUtc,
    DateTime endUtc, {
    bool loop = false,
  }) async {
    final start = startUtc.toUtc();
    final end = endUtc.toUtc();
    if (!end.isAfter(start)) {
      _emit(_snapshot.value.copyWith(error: 'End time must be after start time.'));
      return;
    }
    final matching = segments
        .where((s) =>
            s.localPath != null &&
            s.endedAtUtc.isAfter(start) &&
            s.startedAtUtc.isBefore(end))
        .toList()
      ..sort((a, b) => a.startedAtUtc.compareTo(b.startedAtUtc));
    if (matching.isEmpty) {
      _emit(_snapshot.value.copyWith(
        isLoaded: false,
        error: 'No local audio in that time range.',
      ));
      return;
    }
    try {
      await _configureForPlayback();
      await _player.setVolume(1.0);
      await _player.setLoopMode(loop ? LoopMode.all : LoopMode.off);
      await _player.setAudioSources(
        matching.map((s) => _rangeSourceForSegment(s, start, end)).toList(),
        preload: false,
      );
      _emit(_snapshot.value.copyWith(isLoaded: true, error: null, currentIndex: 0));
      await _player.play();
    } catch (error) {
      _emit(_snapshot.value.copyWith(error: error.toString()));
    }
  }

  /// Clip one segment to the intersection of its own span and `[startUtc, endUtc]`.
  /// File position `trimStart` corresponds to the segment's `startedAtUtc`, so a
  /// wall-clock offset into the range maps to `trimStart + offset` in the file.
  AudioSource _rangeSourceForSegment(
    RecordingSegment segment,
    DateTime startUtc,
    DateTime endUtc,
  ) {
    final canonical = segment.canonicalDuration;
    final fromStart = startUtc.isAfter(segment.startedAtUtc)
        ? startUtc.difference(segment.startedAtUtc)
        : Duration.zero;
    final toEnd = endUtc.isBefore(segment.endedAtUtc)
        ? endUtc.difference(segment.startedAtUtc)
        : canonical;
    var clipDuration = toEnd - fromStart;
    if (clipDuration <= Duration.zero) {
      clipDuration = canonical - fromStart;
    }
    return ClippingAudioSource(
      child: AudioSource.file(segment.localPath!, tag: segment.id),
      start: segment.trimStart + fromStart,
      duration: clipDuration,
      tag: segment.id,
    );
  }

  Future<void> pause() => _player.pause();

  Future<void> stop() async {
    await _player.stop();
    _emit(const PlaybackSnapshot.empty());
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _snapshot.close();
    await _player.dispose();
  }

  void _emit(PlaybackSnapshot snapshot) {
    if (!_snapshot.isClosed) {
      _snapshot.add(snapshot);
    }
  }

  AudioSource _sourceForSegment(RecordingSegment segment) {
    final file = AudioSource.file(segment.localPath!, tag: segment.id);
    if (segment.trimStart <= Duration.zero) {
      return file;
    }
    return ClippingAudioSource(
      child: file,
      start: segment.trimStart,
      duration: segment.canonicalDuration,
      tag: segment.id,
    );
  }
}
