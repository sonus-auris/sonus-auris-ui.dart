// On-demand ML model downloads. Models are never bundled in the app binary —
// they are fetched once, checksum-verified, and cached in app support storage,
// so recognition features add ~0 MB to the store download.
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Describes one downloadable model artifact.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.url,
    this.sha256 = '',
    this.approxSizeBytes = 0,
  });

  /// Stable identifier; also the cache file name (`<id>.tflite`).
  final String id;

  /// HTTPS source. Hosted on the Sonus Auris model CDN so licenses and
  /// versions are controlled server-side.
  final String url;

  /// Hex SHA-256 of the artifact. Empty skips verification (dev only).
  final String sha256;

  /// Rough size for UI ("Download ~12 MB?"). 0 when unknown.
  final int approxSizeBytes;
}

/// Built-in model registry. URLs point at the Sonus Auris model mirror;
/// checksums are pinned when a model version is published.
class ModelCatalog {
  /// Google Perch v2 bird/wildlife classifier (Apache-2.0), int8 TFLite.
  static const ModelSpec perchBirds = ModelSpec(
    id: 'perch-v2-int8',
    url: 'https://models.sonusauris.app/perch/perch-v2-int8.tflite',
    approxSizeBytes: 14 * 1024 * 1024,
  );
}

/// Downloads and caches model files on demand.
///
/// Concurrent [ensure] calls for the same model share one download. Partial
/// downloads go to a `.part` file and are promoted only after the checksum
/// verifies, so a killed app never leaves a corrupt model in place.
class ModelManager {
  ModelManager({http.Client? httpClient, Directory? cacheDir})
      : _http = httpClient ?? http.Client(),
        _cacheDirOverride = cacheDir;

  final http.Client _http;
  final Directory? _cacheDirOverride;
  final Map<String, Future<File>> _inFlight = {};

  Future<Directory> _cacheDir() async {
    final base = _cacheDirOverride ??
        Directory(p.join((await getApplicationSupportDirectory()).path));
    final dir = Directory(p.join(base.path, 'models'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _fileFor(ModelSpec spec) async {
    final dir = await _cacheDir();
    return File(p.join(dir.path, '${spec.id}.tflite'));
  }

  Future<bool> isDownloaded(ModelSpec spec) async =>
      (await _fileFor(spec)).exists();

  /// Returns the local model file, downloading it first if needed.
  Future<File> ensure(ModelSpec spec) {
    return _inFlight.putIfAbsent(spec.id, () async {
      try {
        final file = await _fileFor(spec);
        if (await file.exists()) {
          return file;
        }
        return await _download(spec, file);
      } finally {
        _inFlight.remove(spec.id);
      }
    });
  }

  Future<File> _download(ModelSpec spec, File target) async {
    final part = File('${target.path}.part');
    final request = http.Request('GET', Uri.parse(spec.url));
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      throw HttpException(
        'Model ${spec.id} download failed (${response.statusCode})',
        uri: request.url,
      );
    }
    final sink = part.openWrite();
    final digestSink = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(digestSink);
    try {
      await for (final chunk in response.stream) {
        hasher.add(chunk);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    final digest = digestSink.events.single.toString();
    if (spec.sha256.isNotEmpty && digest != spec.sha256.toLowerCase()) {
      await part.delete();
      throw StateError(
        'Model ${spec.id} checksum mismatch (got $digest); refusing to use it',
      );
    }
    await part.rename(target.path);
    return target;
  }

  /// Frees the cached artifact (feature toggled off / storage pressure).
  Future<void> delete(ModelSpec spec) async {
    final file = await _fileFor(spec);
    if (await file.exists()) {
      await file.delete();
    }
  }

  void dispose() => _http.close();
}

/// Minimal sink adapter for `crypto`'s chunked conversion API.
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}
