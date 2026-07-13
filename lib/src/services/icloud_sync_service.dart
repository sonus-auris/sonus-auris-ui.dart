// Mirrors encrypted segments the backend cannot push into the user's iCloud Drive via the native iCloud bridge.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'crypto/segment_encryptor.dart';
import 'sound_recorder_backend_client.dart';

class IcloudSyncResult {
  const IcloudSyncResult({
    this.completed = 0,
    this.failed = 0,
    this.skipped = false,
    this.error,
  });

  final int completed;
  final int failed;
  final bool skipped;
  final String? error;
}

/// Drains server-side iCloud "client-managed" copy jobs: for each pending job it
/// downloads the segment from the short-lived S3 URL, hands the bytes to the
/// native iOS layer to write into the user's iCloud container, then reports the
/// copy complete to the backend. Apple exposes no server-side iCloud write API,
/// so this device-driven mirror is the only way to back up into a user's iCloud.
class IcloudSyncService {
  IcloudSyncService({
    MethodChannel? channel,
    http.Client? httpClient,
    this.downloadTimeout = const Duration(seconds: 45),
    SegmentEncryptor? encryptor,
  })  : _channel = channel ?? const MethodChannel('audio_dashcam/icloud'),
        _httpClient = httpClient ?? http.Client(),
        _encryptor = encryptor;

  final MethodChannel _channel;
  final http.Client _httpClient;
  final Duration downloadTimeout;

  /// Decrypts ciphertext fetched from our S3 vault so a *usable* audio file is
  /// written into the user's own iCloud. This is the user-initiated, per-clip
  /// "opt-in release" path — decryption happens here on-device, never server-side.
  final SegmentEncryptor? _encryptor;

  /// Whether the device is signed into iCloud and the ubiquity container is
  /// reachable. Returns false on non-iOS platforms (channel not registered).
  Future<bool> isAvailable() async {
    try {
      final available = await _channel.invokeMethod<bool>('isAvailable');
      return available ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<IcloudSyncResult> syncPendingJobs({
    required SoundRecorderBackendClient backendClient,
    required AppConfig config,
    required CloudSecrets secrets,
    int maxJobs = 25,
  }) async {
    if (!await isAvailable()) {
      return const IcloudSyncResult(
        skipped: true,
        error: 'iCloud is not available on this device.',
      );
    }
    final List<Map<String, dynamic>> jobs;
    try {
      jobs = await backendClient.listCloudCopyJobs(
        config: config,
        secrets: secrets,
        limit: maxJobs,
      );
    } catch (error) {
      return IcloudSyncResult(error: 'Listing iCloud copy jobs failed: $error');
    }
    var completed = 0;
    var failed = 0;
    for (final entry in jobs) {
      final job = entry['job'];
      final download = entry['download'];
      if (job is! Map<String, dynamic> || download is! Map<String, dynamic>) {
        continue;
      }
      final jobId = (job['id'] as String? ?? '').trim();
      final destinationKey = (job['destinationKey'] as String? ?? '').trim();
      final url = (download['url'] as String? ?? '').trim();
      if (jobId.isEmpty || destinationKey.isEmpty || url.isEmpty) {
        continue;
      }
      try {
        final downloaded = await _download(url);
        final bytes = _encryptor == null
            ? downloaded
            : await _encryptor.open(downloaded);
        final fileId = await _writeToIcloud(destinationKey, bytes);
        await backendClient.completeCloudCopyJob(
          config: config,
          secrets: secrets,
          jobId: jobId,
          providerFileId: fileId,
          destinationKey: destinationKey,
        );
        completed += 1;
      } catch (_) {
        // Leave the job in waiting_client so the next drain retries it.
        failed += 1;
      }
    }
    return IcloudSyncResult(completed: completed, failed: failed);
  }

  Future<Uint8List> _download(String url) async {
    final uri = Uri.parse(url);
    // The backend hands us presigned S3 HTTPS URLs. Enforce HTTPS (except local
    // dev) so a misconfigured/compromised backend can't downgrade the segment
    // fetch to cleartext — matching the posture of every other client here.
    if (uri.scheme != 'https' &&
        uri.host != 'localhost' &&
        uri.host != '127.0.0.1') {
      throw const FormatException(
        'iCloud segment download URL must use HTTPS.',
      );
    }
    final response = await _httpClient.get(uri).timeout(downloadTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Segment download failed: HTTP ${response.statusCode}.');
    }
    return response.bodyBytes;
  }

  /// Writes [bytes] into the iCloud container at [destinationKey] and returns the
  /// native file identifier/path. Throws on failure.
  Future<String> _writeToIcloud(String destinationKey, Uint8List bytes) async {
    final fileId = await _channel.invokeMethod<String>('importSegment', {
      'destinationKey': destinationKey,
      'bytes': bytes,
    });
    if (fileId == null || fileId.trim().isEmpty) {
      throw StateError('iCloud write returned no file identifier.');
    }
    return fileId.trim();
  }

  void close() {
    _httpClient.close();
  }
}
