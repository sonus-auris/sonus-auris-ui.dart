// Immutable snapshot of the audio-playback engine state (loaded, playing, position/duration) for the UI.
class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.isLoaded,
    required this.isPlaying,
    required this.position,
    required this.duration,
    this.currentIndex,
    this.error,
  });

  const PlaybackSnapshot.empty()
    : isLoaded = false,
      isPlaying = false,
      position = Duration.zero,
      duration = Duration.zero,
      currentIndex = null,
      error = null;

  final bool isLoaded;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final int? currentIndex;
  final String? error;

  PlaybackSnapshot copyWith({
    bool? isLoaded,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    Object? currentIndex = _unset,
    Object? error = _unset,
  }) {
    return PlaybackSnapshot(
      isLoaded: isLoaded ?? this.isLoaded,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      currentIndex: identical(currentIndex, _unset)
          ? this.currentIndex
          : currentIndex as int?,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  static const _unset = Object();
}
