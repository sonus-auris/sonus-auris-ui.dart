import 'dart:collection';
import 'dart:convert';

import 'pagelet_model.dart';
import 'pagelet_policy.dart';

const pageletProtocolVersion = '1.0.0';
const pageletMaxEnvelopeBytes = 65536;
const pageletReplayWindowEntries = 128;
const pageletClockSkew = Duration(minutes: 5);

enum PageletHostPlatform { ios, android, macos, windows, linux, web }

enum PageletRendererKind {
  nativeSchema('native-schema'),
  serverHtml('server-html'),
  contentHtml('content-html');

  const PageletRendererKind(this.wireName);
  final String wireName;

  static PageletRendererKind parse(String value) => values.firstWhere(
        (renderer) => renderer.wireName == value,
        orElse: () => throw FormatException('Unknown pagelet renderer: $value'),
      );
}

class PageletHostContext {
  const PageletHostContext({
    required this.appVersion,
    required this.platform,
    required this.renderer,
  });

  final String appVersion;
  final PageletHostPlatform platform;
  final PageletRendererKind renderer;

  factory PageletHostContext.fromJson(Map<String, Object?> json) {
    _rejectUnknownKeys(
      json,
      const {'appVersion', 'platform', 'renderer'},
      'pagelet host context',
    );
    final appVersion = _requiredString(json, 'appVersion');
    if (appVersion.length > 64 ||
        !RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$').hasMatch(appVersion)) {
      throw const FormatException('Invalid pagelet host appVersion');
    }
    final platformName = _requiredString(json, 'platform');
    final platform = PageletHostPlatform.values.firstWhere(
      (candidate) => candidate.name == platformName,
      orElse: () => throw FormatException(
        'Unknown pagelet host platform: $platformName',
      ),
    );
    final renderer = PageletRendererKind.parse(
      _requiredString(json, 'renderer'),
    );
    if (platform == PageletHostPlatform.web &&
        renderer == PageletRendererKind.nativeSchema) {
      throw const FormatException('Web cannot claim the native schema renderer');
    }
    if (platform != PageletHostPlatform.web &&
        renderer == PageletRendererKind.serverHtml) {
      throw const FormatException(
        'Native hosts cannot claim the server HTML renderer',
      );
    }
    return PageletHostContext(
      appVersion: appVersion,
      platform: platform,
      renderer: renderer,
    );
  }
}

class PageletEnvelope {
  const PageletEnvelope({
    required this.requestId,
    required this.sessionNonce,
    required this.issuedAt,
    required this.expiresAt,
    required this.host,
    required this.document,
  });

  final String requestId;
  final String sessionNonce;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final PageletHostContext host;
  final PageletDocument document;

  static PageletEnvelope decode(
    String raw, {
    DateTime? now,
    int maxBytes = pageletMaxEnvelopeBytes,
  }) {
    if (utf8.encode(raw).length > maxBytes) {
      throw FormatException('Pagelet envelope exceeds $maxBytes bytes');
    }
    final decoded = jsonDecode(raw);
    final json = _asObject(decoded, 'pagelet envelope');
    return PageletEnvelope.fromJson(json, now: now);
  }

  factory PageletEnvelope.fromJson(
    Map<String, Object?> json, {
    DateTime? now,
  }) {
    _rejectUnknownKeys(
      json,
      const {
        'protocolVersion',
        'requestId',
        'sessionNonce',
        'issuedAt',
        'expiresAt',
        'host',
        'document',
      },
      'pagelet envelope',
    );
    final protocolVersion = _requiredString(json, 'protocolVersion');
    if (protocolVersion != pageletProtocolVersion) {
      throw FormatException(
        'Unsupported pagelet protocol version: $protocolVersion',
      );
    }
    final requestId = _requiredString(json, 'requestId');
    if (!RegExp(r'^req_[A-Za-z0-9_-]{16,80}$').hasMatch(requestId)) {
      throw const FormatException('Invalid pagelet requestId');
    }
    final sessionNonce = _requiredString(json, 'sessionNonce');
    if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(sessionNonce)) {
      throw const FormatException('Invalid pagelet sessionNonce');
    }
    final issuedAt = _requiredDateTime(json, 'issuedAt');
    final expiresAt = _requiredDateTime(json, 'expiresAt');
    if (!expiresAt.isAfter(issuedAt)) {
      throw const FormatException('Pagelet envelope expiry must follow issuance');
    }
    final clock = (now ?? DateTime.now()).toUtc();
    if (issuedAt.isAfter(clock.add(pageletClockSkew))) {
      throw const FormatException('Pagelet envelope was issued in the future');
    }
    if (!expiresAt.isAfter(clock)) {
      throw const FormatException('Pagelet envelope has expired');
    }
    final host = PageletHostContext.fromJson(
      _asObject(json['host'], 'pagelet host context'),
    );
    final document = PageletDocument.fromJson(
      _asObject(json['document'], 'pagelet document'),
    );
    final violation = PageletPolicy.violation(document);
    if (violation != null) {
      throw FormatException('Pagelet policy violation: $violation');
    }
    return PageletEnvelope(
      requestId: requestId,
      sessionNonce: sessionNonce,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      host: host,
      document: document,
    );
  }
}

class PageletReplayGuard {
  PageletReplayGuard({this.capacity = pageletReplayWindowEntries})
      : assert(capacity > 0);

  final int capacity;
  final Queue<(String, String)> _accepted = Queue<(String, String)>();
  final Set<String> _requestIds = <String>{};
  final Set<String> _sessionNonces = <String>{};

  void accept(PageletEnvelope envelope) {
    if (_requestIds.contains(envelope.requestId)) {
      throw StateError('Replayed pagelet requestId');
    }
    if (_sessionNonces.contains(envelope.sessionNonce)) {
      throw StateError('Replayed pagelet sessionNonce');
    }
    _requestIds.add(envelope.requestId);
    _sessionNonces.add(envelope.sessionNonce);
    _accepted.addLast((envelope.requestId, envelope.sessionNonce));
    while (_accepted.length > capacity) {
      final removed = _accepted.removeFirst();
      _requestIds.remove(removed.$1);
      _sessionNonces.remove(removed.$2);
    }
  }
}

void _rejectUnknownKeys(
  Map<String, Object?> json,
  Set<String> allowed,
  String context,
) {
  final unknown = json.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException('Unknown $context field(s): ${unknown.join(', ')}');
  }
}

Map<String, Object?> _asObject(Object? value, String context) {
  if (value is! Map) {
    throw FormatException('$context must be an object');
  }
  return value.map((key, value) {
    if (key is! String) {
      throw FormatException('$context keys must be strings');
    }
    return MapEntry(key, value);
  });
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

DateTime _requiredDateTime(Map<String, Object?> json, String key) {
  final raw = _requiredString(json, key);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null || !raw.endsWith('Z')) {
    throw FormatException('$key must be an RFC3339 UTC timestamp');
  }
  return parsed.toUtc();
}
