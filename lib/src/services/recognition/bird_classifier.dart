// Bird/wildlife call identification with the Google Perch v2 model (Apache-2.0),
// run fully on-device via TFLite. The model and its label list are downloaded
// on first use (ModelManager) — nothing is bundled in the app binary.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model_manager.dart';

/// One species hypothesis for a clip.
class BirdMatch {
  const BirdMatch({required this.label, required this.score});

  /// Species label (scientific or common name, per the label file).
  final String label;

  /// Sigmoid score in 0..1.
  final double score;

  Map<String, Object?> toDetails() => {'species': label, 'score': score};
}

/// Classifies bird/wildlife calls from raw mono PCM using Perch v2.
///
/// Perch expects 5-second windows of mono float PCM at 32 kHz. Audio leaving
/// the rolling buffer at another rate should be resampled by the caller
/// (the capture pipeline already produces mono float frames).
class BirdClassifier {
  BirdClassifier({
    required this.models,
    http.Client? httpClient,
    this.labelsUrl = 'https://models.sonusauris.app/perch/perch-v2-labels.csv',
  }) : _http = httpClient ?? http.Client();

  static const int sampleRate = 32000;
  static const int windowSamples = 5 * sampleRate;

  final ModelManager models;
  final http.Client _http;
  final String labelsUrl;

  IsolateInterpreter? _interpreter;
  Interpreter? _rawInterpreter;
  List<String>? _labels;

  bool get isReady => _interpreter != null && _labels != null;

  /// Downloads (if needed) and loads the model + labels. Safe to call again.
  Future<void> ensureLoaded() async {
    if (isReady) {
      return;
    }
    final modelFile = await models.ensure(ModelCatalog.perchBirds);
    _labels ??= await _loadLabels(modelFile.parent);
    final raw = Interpreter.fromFile(modelFile);
    _rawInterpreter = raw;
    _interpreter = await IsolateInterpreter.create(address: raw.address);
  }

  Future<List<String>> _loadLabels(Directory cacheDir) async {
    final file = File('${cacheDir.path}/perch-v2-labels.csv');
    if (!await file.exists()) {
      final response = await _http.get(Uri.parse(labelsUrl));
      if (response.statusCode != 200) {
        throw HttpException(
          'Perch labels download failed (${response.statusCode})',
          uri: Uri.parse(labelsUrl),
        );
      }
      await file.writeAsBytes(response.bodyBytes, flush: true);
    }
    return const LineSplitter()
        .convert(await file.readAsString())
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// Classifies one 5-second window of mono PCM at [sampleRate]. Shorter input
  /// is zero-padded; longer input is truncated. Returns up to [topK] matches
  /// with score >= [minScore], best first.
  Future<List<BirdMatch>> classify(
    Float32List samples, {
    int topK = 3,
    double minScore = 0.3,
  }) async {
    await ensureLoaded();
    final interpreter = _interpreter!;
    final labels = _labels!;

    final window = Float32List(windowSamples);
    window.setRange(0, math.min(samples.length, windowSamples), samples);

    final input = [window];
    final output = [Float32List(labels.length)];
    await interpreter.run(input, output);

    final logits = output.first;
    final indexed = List<int>.generate(logits.length, (i) => i)
      ..sort((a, b) => logits[b].compareTo(logits[a]));
    final matches = <BirdMatch>[];
    for (final i in indexed.take(topK)) {
      final score = _sigmoid(logits[i]);
      if (score < minScore) {
        break;
      }
      matches.add(BirdMatch(label: labels[i], score: score));
    }
    return matches;
  }

  static double _sigmoid(double x) => 1 / (1 + math.exp(-x));

  Future<void> dispose() async {
    await _interpreter?.close();
    _rawInterpreter?.close();
    _interpreter = null;
    _rawInterpreter = null;
    _http.close();
  }
}
