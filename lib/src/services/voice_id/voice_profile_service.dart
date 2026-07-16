// On-device "Knows your voice" enrollment store: up to five voice samples and
// their precomputed FFT/MFCC fingerprints for fast speaker matching.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'voice_fingerprinter.dart';

/// One enrolled voice sample: the raw WAV clip (kept for re-fingerprinting if
/// the algorithm ever changes) plus its precomputed fingerprint (the
/// transformed state used for every live match, so recognition never has to
/// re-read audio from disk).
class VoiceProfileSample {
  const VoiceProfileSample({
    required this.id,
    required this.createdAtUtc,
    required this.fingerprint,
    this.wavPath,
  });

  final String id;
  final DateTime createdAtUtc;
  final List<double> fingerprint;
  final String? wavPath;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'fingerprint': fingerprint,
    if (wavPath != null) 'wavPath': wavPath,
  };

  static VoiceProfileSample? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final createdAt = DateTime.tryParse(json['createdAtUtc'] as String? ?? '');
    final rawFingerprint = json['fingerprint'];
    if (id is! String || createdAt == null || rawFingerprint is! List) {
      return null;
    }
    final fingerprint = <double>[];
    for (final value in rawFingerprint) {
      if (value is! num) {
        return null;
      }
      fingerprint.add(value.toDouble());
    }
    return VoiceProfileSample(
      id: id,
      createdAtUtc: createdAt.toUtc(),
      fingerprint: fingerprint,
      wavPath: json['wavPath'] as String?,
    );
  }
}

/// Result of matching live audio against the enrolled samples.
class VoiceMatch {
  const VoiceMatch({
    required this.similarity,
    required this.isMatch,
    this.sampleId,
  });

  /// Best cosine similarity across enrolled samples, in [-1, 1].
  final double similarity;

  /// True when [similarity] clears [VoiceProfileService.matchThreshold].
  final bool isMatch;

  /// The enrolled sample that matched best.
  final String? sampleId;
}

/// Owns the enrolled voice samples for "Knows your voice".
///
/// Everything stays on this device: clips and fingerprints live under the
/// app-support directory (never synced, never uploaded) in
/// `voice_profiles/` + `voice_profiles.v1.json`. At most [maxSamples] samples
/// are kept; enrolling more is rejected so the user consciously curates what
/// their voiceprint is built from.
class VoiceProfileService {
  VoiceProfileService({
    VoiceFingerprinter? fingerprinter,
    Future<Directory> Function()? baseDirectoryProvider,
  }) : fingerprinter = fingerprinter ?? VoiceFingerprinter(),
       _baseDirectoryProvider =
           baseDirectoryProvider ?? getApplicationSupportDirectory;

  static const int maxSamples = 5;

  /// Cosine-similarity floor for "this is the enrolled voice". MFCC mean/std
  /// fingerprints of the same speaker typically land well above this; distinct
  /// speakers and non-speech land below.
  static const double matchThreshold = 0.82;

  static const String _indexFileName = 'voice_profiles.v1.json';
  static const String _clipsDirName = 'voice_profiles';

  final VoiceFingerprinter fingerprinter;
  final Future<Directory> Function() _baseDirectoryProvider;

  List<VoiceProfileSample> _samples = const [];
  bool _loaded = false;

  /// The enrolled samples, oldest first. [load] must have run (all public
  /// mutators call it themselves).
  List<VoiceProfileSample> get samples => List.unmodifiable(_samples);

  bool get hasSamples => _samples.isNotEmpty;

  Future<File> get _indexFile async {
    final base = await _baseDirectoryProvider();
    return File(p.join(base.path, _indexFileName));
  }

  Future<Directory> get _clipsDirectory async {
    final base = await _baseDirectoryProvider();
    final directory = Directory(p.join(base.path, _clipsDirName));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<List<VoiceProfileSample>> load() async {
    if (_loaded) {
      return samples;
    }
    final file = await _indexFile;
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString()) as List<dynamic>;
        _samples = json
            .whereType<Map<String, dynamic>>()
            .map(VoiceProfileSample.fromJson)
            .whereType<VoiceProfileSample>()
            .toList();
      } catch (_) {
        _samples = const [];
      }
    }
    _loaded = true;
    return samples;
  }

  Future<void> _save() async {
    final file = await _indexFile;
    final tempFile = File('${file.path}.tmp');
    await tempFile.writeAsString(
      jsonEncode(_samples.map((sample) => sample.toJson()).toList()),
      flush: true,
    );
    await tempFile.rename(file.path);
  }

  /// Enrolls one clip of the user's voice. [mono] is normalized (-1..1) PCM at
  /// [sampleRate]; anything above 16 kHz is decimated first so every
  /// fingerprint lives in the same feature space. Returns the new sample, or
  /// an error message the UI can show verbatim.
  Future<({VoiceProfileSample? sample, String? error})> enroll({
    required Float64List mono,
    required int sampleRate,
  }) async {
    await load();
    if (_samples.length >= maxSamples) {
      return (
        sample: null,
        error:
            'You already have $maxSamples voice samples. '
            'Remove one before adding another.',
      );
    }
    final resampled = VoiceFingerprinter.downsample(
      mono,
      sampleRate,
      fingerprinter.sampleRate,
    );
    final fingerprint = fingerprinter.fingerprint(resampled);
    if (fingerprint == null) {
      return (
        sample: null,
        error:
            'That clip did not contain enough clear speech — '
            'try again while speaking normally.',
      );
    }
    final id = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
    String? wavPath;
    try {
      final directory = await _clipsDirectory;
      final file = File(p.join(directory.path, 'sample-$id.wav'));
      await file.writeAsBytes(
        _wavBytes(resampled, fingerprinter.sampleRate),
        flush: true,
      );
      wavPath = file.path;
    } catch (_) {
      // The fingerprint is what matching needs; a failed clip write only
      // costs future re-fingerprinting.
    }
    final sample = VoiceProfileSample(
      id: id,
      createdAtUtc: DateTime.now().toUtc(),
      fingerprint: fingerprint,
      wavPath: wavPath,
    );
    _samples = [..._samples, sample];
    await _save();
    return (sample: sample, error: null);
  }

  Future<void> removeSample(String id) async {
    await load();
    final sample = _samples.where((sample) => sample.id == id).firstOrNull;
    if (sample == null) {
      return;
    }
    if (sample.wavPath != null) {
      final file = File(sample.wavPath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _samples = _samples.where((other) => other.id != id).toList();
    await _save();
  }

  Future<void> clear() async {
    await load();
    for (final sample in _samples) {
      if (sample.wavPath != null) {
        final file = File(sample.wavPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    _samples = const [];
    await _save();
  }

  /// Matches live audio against every enrolled fingerprint. Returns null when
  /// nothing is enrolled or the clip has too little speech to judge.
  Future<VoiceMatch?> match({
    required Float64List mono,
    required int sampleRate,
  }) async {
    await load();
    if (_samples.isEmpty) {
      return null;
    }
    final resampled = VoiceFingerprinter.downsample(
      mono,
      sampleRate,
      fingerprinter.sampleRate,
    );
    final fingerprint = fingerprinter.fingerprint(resampled);
    if (fingerprint == null) {
      return null;
    }
    var best = -1.0;
    String? bestId;
    for (final sample in _samples) {
      final similarity = VoiceFingerprinter.cosineSimilarity(
        fingerprint,
        sample.fingerprint,
      );
      if (similarity > best) {
        best = similarity;
        bestId = sample.id;
      }
    }
    return VoiceMatch(
      similarity: best,
      isMatch: best >= matchThreshold,
      sampleId: bestId,
    );
  }

  /// Minimal 16-bit mono PCM WAV container around the clip.
  static Uint8List _wavBytes(Float64List mono, int sampleRate) {
    final dataLength = mono.length * 2;
    final bytes = BytesBuilder();
    void writeString(String value) => bytes.add(value.codeUnits);
    void writeUint32(int value) {
      bytes.add(
        Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little),
      );
    }

    void writeUint16(int value) {
      bytes.add(
        Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.little),
      );
    }

    writeString('RIFF');
    writeUint32(36 + dataLength);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(1); // mono
    writeUint32(sampleRate);
    writeUint32(sampleRate * 2); // byte rate
    writeUint16(2); // block align
    writeUint16(16); // bits per sample
    writeString('data');
    writeUint32(dataLength);
    final pcm = Int16List(mono.length);
    for (var i = 0; i < mono.length; i++) {
      final scaled = (mono[i] * 32767).round();
      pcm[i] = scaled < -32768 ? -32768 : (scaled > 32767 ? 32767 : scaled);
    }
    bytes.add(pcm.buffer.asUint8List());
    return bytes.toBytes();
  }
}
