// Model for one rolling audio segment on disk with its upload status and metadata (timing, sample range, geo tag).
import 'geo_tag.dart';

enum SegmentUploadStatus {
  pending,
  uploading,
  uploaded,
  failed,
  localOnly;

  static SegmentUploadStatus fromName(String? name) {
    return SegmentUploadStatus.values.firstWhere(
      (status) => status.name == name,
      orElse: () => SegmentUploadStatus.pending,
    );
  }
}

class RecordingSegment {
  const RecordingSegment({
    required this.id,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.byteSize,
    required this.uploadStatus,
    this.captureSessionId = '',
    this.sequence = 0,
    this.sampleRate = 0,
    this.channels = 0,
    this.startSample = 0,
    this.sampleCount = 0,
    this.storedSampleCount = 0,
    this.overlapSamples = 0,
    this.container = '',
    this.codec = '',
    this.localPath,
    this.remoteKey,
    this.uploadedAtUtc,
    this.permanentRemoteKey,
    this.permanentSavedAtUtc,
    this.permanentError,
    this.error,
    this.geoTag,
    this.nextUploadGeneration = 1,
    this.activeUploadGeneration = 0,
    this.acknowledgedUploadGeneration = 0,
  });

  final String id;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final String captureSessionId;
  final int sequence;
  final int sampleRate;
  final int channels;
  final int startSample;
  final int sampleCount;
  final int storedSampleCount;
  final int overlapSamples;
  final String container;
  final String codec;
  final String? localPath;
  final int byteSize;
  final SegmentUploadStatus uploadStatus;
  final String? remoteKey;
  final DateTime? uploadedAtUtc;
  final String? permanentRemoteKey;
  final DateTime? permanentSavedAtUtc;
  final String? permanentError;
  final String? error;

  /// Next durable attempt generation allocated by the upload state machine.
  final int nextUploadGeneration;

  /// Generation whose asynchronous result is currently allowed to commit.
  final int activeUploadGeneration;

  /// Last generation that produced a verified remote acknowledgement.
  final int acknowledgedUploadGeneration;

  /// Optional capture-location evidence (null unless location tagging is on and
  /// a fix was available). See [GeoTag].
  final GeoTag? geoTag;

  Duration get duration => endedAtUtc.difference(startedAtUtc);

  bool get hasSampleTimeline =>
      sampleRate > 0 && channels > 0 && sampleCount > 0;

  int get endSampleExclusive => startSample + sampleCount;

  int get storedStartSample => startSample - overlapSamples;

  int get effectiveStoredSampleCount =>
      storedSampleCount > 0 ? storedSampleCount : sampleCount + overlapSamples;

  Duration get trimStart => _samplesToDuration(overlapSamples);

  Duration get canonicalDuration =>
      hasSampleTimeline ? _samplesToDuration(sampleCount) : duration;

  String get fileExtension {
    final path = localPath;
    if (path != null) {
      final dot = path.lastIndexOf('.');
      if (dot >= 0 && dot < path.length - 1) {
        return path.substring(dot + 1).toLowerCase();
      }
    }
    if (container == 'wav') {
      return 'wav';
    }
    if (container == 'raw') {
      return 'pcm';
    }
    return 'm4a';
  }

  String get contentType {
    switch (fileExtension) {
      case 'wav':
        return 'audio/wav';
      case 'pcm':
        return 'application/octet-stream';
      default:
        return 'audio/mp4';
    }
  }

  bool get isLocal => localPath != null && localPath!.isNotEmpty;

  bool get isUploaded =>
      uploadStatus == SegmentUploadStatus.uploaded &&
      remoteKey != null &&
      remoteKey!.trim().isNotEmpty;

  bool get isPermanentlySaved =>
      permanentRemoteKey != null && permanentRemoteKey!.trim().isNotEmpty;

  RecordingSegment copyWith({
    String? id,
    DateTime? startedAtUtc,
    DateTime? endedAtUtc,
    String? captureSessionId,
    int? sequence,
    int? sampleRate,
    int? channels,
    int? startSample,
    int? sampleCount,
    int? storedSampleCount,
    int? overlapSamples,
    String? container,
    String? codec,
    Object? localPath = _unset,
    int? byteSize,
    SegmentUploadStatus? uploadStatus,
    Object? remoteKey = _unset,
    Object? uploadedAtUtc = _unset,
    Object? permanentRemoteKey = _unset,
    Object? permanentSavedAtUtc = _unset,
    Object? permanentError = _unset,
    Object? error = _unset,
    Object? geoTag = _unset,
    int? nextUploadGeneration,
    int? activeUploadGeneration,
    int? acknowledgedUploadGeneration,
  }) {
    return RecordingSegment(
      id: id ?? this.id,
      startedAtUtc: startedAtUtc ?? this.startedAtUtc,
      endedAtUtc: endedAtUtc ?? this.endedAtUtc,
      captureSessionId: captureSessionId ?? this.captureSessionId,
      sequence: sequence ?? this.sequence,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      startSample: startSample ?? this.startSample,
      sampleCount: sampleCount ?? this.sampleCount,
      storedSampleCount: storedSampleCount ?? this.storedSampleCount,
      overlapSamples: overlapSamples ?? this.overlapSamples,
      container: container ?? this.container,
      codec: codec ?? this.codec,
      localPath: identical(localPath, _unset)
          ? this.localPath
          : localPath as String?,
      byteSize: byteSize ?? this.byteSize,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      remoteKey: identical(remoteKey, _unset)
          ? this.remoteKey
          : remoteKey as String?,
      uploadedAtUtc: identical(uploadedAtUtc, _unset)
          ? this.uploadedAtUtc
          : uploadedAtUtc as DateTime?,
      permanentRemoteKey: identical(permanentRemoteKey, _unset)
          ? this.permanentRemoteKey
          : permanentRemoteKey as String?,
      permanentSavedAtUtc: identical(permanentSavedAtUtc, _unset)
          ? this.permanentSavedAtUtc
          : permanentSavedAtUtc as DateTime?,
      permanentError: identical(permanentError, _unset)
          ? this.permanentError
          : permanentError as String?,
      error: identical(error, _unset) ? this.error : error as String?,
      geoTag: identical(geoTag, _unset) ? this.geoTag : geoTag as GeoTag?,
      nextUploadGeneration: nextUploadGeneration ?? this.nextUploadGeneration,
      activeUploadGeneration:
          activeUploadGeneration ?? this.activeUploadGeneration,
      acknowledgedUploadGeneration:
          acknowledgedUploadGeneration ?? this.acknowledgedUploadGeneration,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'startedAtUtc': startedAtUtc.toIso8601String(),
      'endedAtUtc': endedAtUtc.toIso8601String(),
      'captureSessionId': captureSessionId,
      'sequence': sequence,
      'sampleRate': sampleRate,
      'channels': channels,
      'startSample': startSample,
      'sampleCount': sampleCount,
      'storedSampleCount': storedSampleCount,
      'overlapSamples': overlapSamples,
      'container': container,
      'codec': codec,
      'localPath': localPath,
      'byteSize': byteSize,
      'uploadStatus': uploadStatus.name,
      'remoteKey': remoteKey,
      'uploadedAtUtc': uploadedAtUtc?.toIso8601String(),
      'permanentRemoteKey': permanentRemoteKey,
      'permanentSavedAtUtc': permanentSavedAtUtc?.toIso8601String(),
      'permanentError': permanentError,
      'error': error,
      'geoTag': geoTag?.toJson(),
      'nextUploadGeneration': nextUploadGeneration,
      'activeUploadGeneration': activeUploadGeneration,
      'acknowledgedUploadGeneration': acknowledgedUploadGeneration,
    };
  }

  factory RecordingSegment.fromJson(Map<String, dynamic> json) {
    final nextGeneration = _asPositiveInt(json['nextUploadGeneration']);
    final activeGeneration = _asNonNegativeInt(json['activeUploadGeneration']);
    final acknowledgedGeneration = _asNonNegativeInt(
      json['acknowledgedUploadGeneration'],
    );
    final normalizedNextGeneration = [
      nextGeneration,
      activeGeneration + 1,
      acknowledgedGeneration + 1,
    ].reduce((left, right) => left > right ? left : right);
    return RecordingSegment(
      id: json['id'] as String,
      startedAtUtc: DateTime.parse(json['startedAtUtc'] as String).toUtc(),
      endedAtUtc: DateTime.parse(json['endedAtUtc'] as String).toUtc(),
      captureSessionId: json['captureSessionId'] as String? ?? '',
      sequence: _asInt(json['sequence']),
      sampleRate: _asInt(json['sampleRate']),
      channels: _asInt(json['channels']),
      startSample: _asInt(json['startSample']),
      sampleCount: _asInt(json['sampleCount']),
      storedSampleCount: _asInt(json['storedSampleCount']),
      overlapSamples: _asInt(json['overlapSamples']),
      container: json['container'] as String? ?? '',
      codec: json['codec'] as String? ?? '',
      localPath: json['localPath'] as String?,
      byteSize: _asInt(json['byteSize']),
      uploadStatus: SegmentUploadStatus.fromName(
        json['uploadStatus'] as String?,
      ),
      remoteKey: json['remoteKey'] as String?,
      uploadedAtUtc: json['uploadedAtUtc'] == null
          ? null
          : DateTime.parse(json['uploadedAtUtc'] as String).toUtc(),
      permanentRemoteKey: json['permanentRemoteKey'] as String?,
      permanentSavedAtUtc: json['permanentSavedAtUtc'] == null
          ? null
          : DateTime.parse(json['permanentSavedAtUtc'] as String).toUtc(),
      permanentError: json['permanentError'] as String?,
      error: json['error'] as String?,
      geoTag: json['geoTag'] is Map<String, dynamic>
          ? GeoTag.fromJson(json['geoTag'] as Map<String, dynamic>)
          : null,
      nextUploadGeneration: normalizedNextGeneration,
      activeUploadGeneration: activeGeneration,
      acknowledgedUploadGeneration: acknowledgedGeneration,
    );
  }

  static const _unset = Object();

  Duration _samplesToDuration(int samples) {
    if (sampleRate <= 0 || samples <= 0) {
      return Duration.zero;
    }
    return Duration(microseconds: samples * 1000000 ~/ sampleRate);
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _asPositiveInt(Object? value) {
    final parsed = _asInt(value);
    return parsed <= 0 ? 1 : parsed;
  }

  static int _asNonNegativeInt(Object? value) {
    final parsed = _asInt(value);
    return parsed < 0 ? 0 : parsed;
  }
}
