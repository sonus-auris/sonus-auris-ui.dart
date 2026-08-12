import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _maximumRequestBytes = 16 * 1024;
const _maximumResponseBytes = 256 * 1024;
const _maximumRequestsPerMinute = 120;

Future<void> main() async {
  final config = _BridgeConfig.fromEnvironment();
  final upstreamClient = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final limiter = _MinuteLimiter(_maximumRequestsPerMinute);
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    config.port,
    shared: false,
  );
  server.autoCompress = false;

  stdout.writeln(
    jsonEncode({
      'event': 'shared_auth_test_bridge_ready',
      'url': 'http://127.0.0.1:${server.port}/session',
    }),
  );

  final shutdown = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) {
      if (!shutdown.isCompleted) shutdown.complete();
    }),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) {
        if (!shutdown.isCompleted) shutdown.complete();
      }),
  ];

  final serving = server.forEach((request) async {
    try {
      await _handleRequest(
        request,
        config: config,
        upstreamClient: upstreamClient,
        limiter: limiter,
      );
    } catch (_) {
      if (!request.response.headersSent) {
        _secureHeaders(request.response);
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'bridge_failure'}));
      }
      await request.response.close();
    }
  });

  await Future.any([shutdown.future, serving]);
  await server.close(force: true);
  upstreamClient.close(force: true);
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}

Future<void> _handleRequest(
  HttpRequest request, {
  required _BridgeConfig config,
  required HttpClient upstreamClient,
  required _MinuteLimiter limiter,
}) async {
  _secureHeaders(request.response);
  final origin = request.headers.value(HttpHeaders.originHeader);
  final allowedOrigin = origin == null ? null : _validatedLoopbackOrigin(origin);
  if (origin != null && allowedOrigin == null) {
    await _jsonError(request.response, HttpStatus.forbidden, 'origin_rejected');
    return;
  }
  if (allowedOrigin != null) {
    request.response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, allowedOrigin)
      ..set(HttpHeaders.varyHeader, HttpHeaders.originHeader);
  }

  if (request.method == 'OPTIONS' && request.uri.path == '/session') {
    if (allowedOrigin == null) {
      await _jsonError(request.response, HttpStatus.forbidden, 'origin_required');
      return;
    }
    request.response.headers
      ..set(HttpHeaders.accessControlAllowMethodsHeader, 'POST, OPTIONS')
      ..set(HttpHeaders.accessControlAllowHeadersHeader, 'content-type')
      ..set(HttpHeaders.accessControlMaxAgeHeader, '600');
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  if (request.method == 'GET' && request.uri.path == '/healthz') {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'ok'}));
    await request.response.close();
    return;
  }

  if (request.method != 'POST' || request.uri.path != '/session') {
    await _jsonError(request.response, HttpStatus.notFound, 'not_found');
    return;
  }
  if (!limiter.allow()) {
    await _jsonError(
      request.response,
      HttpStatus.tooManyRequests,
      'rate_limited',
    );
    return;
  }
  final contentType = request.headers.contentType;
  if (contentType?.mimeType != ContentType.json.mimeType) {
    await _jsonError(
      request.response,
      HttpStatus.unsupportedMediaType,
      'json_required',
    );
    return;
  }

  final requestBytes = await _readLimited(request, _maximumRequestBytes);
  if (requestBytes == null) {
    await _jsonError(
      request.response,
      HttpStatus.requestEntityTooLarge,
      'request_too_large',
    );
    return;
  }

  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(requestBytes));
  } on FormatException {
    await _jsonError(request.response, HttpStatus.badRequest, 'invalid_json');
    return;
  }
  if (decoded is! Map ||
      decoded.length != 2 ||
      !decoded.containsKey('email') ||
      !decoded.containsKey('code')) {
    await _jsonError(request.response, HttpStatus.badRequest, 'invalid_request');
    return;
  }

  final email = (decoded['email'] as String? ?? '').trim().toLowerCase();
  final code = (decoded['code'] as String? ?? '').trim();
  if (!_syntheticEmail(email) || !RegExp(r'^[0-9]{6}$').hasMatch(code)) {
    await _jsonError(request.response, HttpStatus.forbidden, 'identity_rejected');
    return;
  }

  late final HttpClientResponse upstreamResponse;
  try {
    final upstreamRequest = await upstreamClient
        .postUrl(config.upstream)
        .timeout(const Duration(seconds: 15));
    upstreamRequest
      ..followRedirects = false
      ..headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType)
      ..headers.contentType = ContentType.json
      ..headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.bearerSecret}',
      )
      ..write(
        jsonEncode({
          'email': email,
          'code': code,
          'project': config.project,
        }),
      );
    upstreamResponse = await upstreamRequest.close().timeout(
      const Duration(seconds: 30),
    );
  } on TimeoutException {
    await _jsonError(request.response, HttpStatus.badGateway, 'upstream_timeout');
    return;
  } on SocketException {
    await _jsonError(
      request.response,
      HttpStatus.badGateway,
      'upstream_unavailable',
    );
    return;
  }

  final responseBytes = await _readLimited(
    upstreamResponse,
    _maximumResponseBytes,
  );
  if (responseBytes == null || upstreamResponse.statusCode != HttpStatus.ok) {
    await _jsonError(request.response, HttpStatus.badGateway, 'upstream_rejected');
    return;
  }
  try {
    final payload = jsonDecode(utf8.decode(responseBytes));
    if (payload is! Map ||
        (payload['access_token'] as String? ?? '').trim().isEmpty ||
        (payload['refresh_token'] as String? ?? '').trim().isEmpty) {
      throw const FormatException('missing session');
    }
  } on FormatException {
    await _jsonError(
      request.response,
      HttpStatus.badGateway,
      'invalid_upstream_session',
    );
    return;
  }

  request.response.statusCode = HttpStatus.ok;
  request.response.headers.contentType = ContentType.json;
  request.response.add(responseBytes);
  await request.response.close();
}

Future<Uint8List?> _readLimited(Stream<List<int>> stream, int maximum) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (builder.length + chunk.length > maximum) {
      return null;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> _jsonError(
  HttpResponse response,
  int status,
  String code,
) async {
  _secureHeaders(response);
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode({'error': code}));
  await response.close();
}

void _secureHeaders(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('pragma', 'no-cache')
    ..set('x-content-type-options', 'nosniff')
    ..set('referrer-policy', 'no-referrer');
}

String? _validatedLoopbackOrigin(String value) {
  final origin = Uri.tryParse(value.trim());
  if (origin == null ||
      !origin.hasAuthority ||
      origin.userInfo.isNotEmpty ||
      origin.query.isNotEmpty ||
      origin.fragment.isNotEmpty ||
      origin.path.isNotEmpty ||
      !_loopback(origin.host) ||
      (origin.scheme != 'http' && origin.scheme != 'https')) {
    return null;
  }
  return origin.toString();
}

bool _syntheticEmail(String email) {
  final separator = email.lastIndexOf('@');
  if (separator <= 0 || separator == email.length - 1) return false;
  final domain = email.substring(separator + 1);
  return domain == 'example.com' ||
      domain == 'example.net' ||
      domain == 'example.org' ||
      domain.endsWith('.test') ||
      domain.endsWith('.example') ||
      domain.endsWith('.invalid');
}

bool _loopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

final class _MinuteLimiter {
  _MinuteLimiter(this.maximum);

  final int maximum;
  final Queue<DateTime> _accepted = Queue<DateTime>();

  bool allow() {
    final now = DateTime.now().toUtc();
    final cutoff = now.subtract(const Duration(minutes: 1));
    while (_accepted.isNotEmpty && _accepted.first.isBefore(cutoff)) {
      _accepted.removeFirst();
    }
    if (_accepted.length >= maximum) return false;
    _accepted.addLast(now);
    return true;
  }
}

final class _BridgeConfig {
  const _BridgeConfig({
    required this.upstream,
    required this.bearerSecret,
    required this.project,
    required this.port,
  });

  factory _BridgeConfig.fromEnvironment() {
    final environment = Platform.environment;
    final upstream = _exactUpstream(
      environment['SONUS_TEST_SHARED_AUTH_UPSTREAM'] ?? '',
    );
    final bearerSecret =
        (environment['SONUS_TEST_SHARED_AUTH_BEARER'] ?? '').trim();
    if (bearerSecret.length < 32) {
      throw StateError(
        'SONUS_TEST_SHARED_AUTH_BEARER must contain at least 32 characters.',
      );
    }
    final project =
        (environment['SONUS_TEST_SHARED_AUTH_PROJECT'] ?? '').trim();
    final normalizedProject = project.toLowerCase();
    final parts = normalizedProject
        .split(RegExp(r'[^a-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toSet();
    if (!(normalizedProject.endsWith('-test') ||
            normalizedProject.endsWith('_test')) ||
        parts.contains('prod') ||
        parts.contains('production')) {
      throw StateError(
        'SONUS_TEST_SHARED_AUTH_PROJECT must name an isolated test project.',
      );
    }
    final port = int.tryParse(
      (environment['SONUS_TEST_BRIDGE_PORT'] ?? '41842').trim(),
    );
    if (port == null || port < 1024 || port > 65535) {
      throw StateError('SONUS_TEST_BRIDGE_PORT is invalid.');
    }
    return _BridgeConfig(
      upstream: upstream,
      bearerSecret: bearerSecret,
      project: project,
      port: port,
    );
  }

  final Uri upstream;
  final String bearerSecret;
  final String project;
  final int port;

  static Uri _exactUpstream(String value) {
    final parsed = Uri.tryParse(value.trim());
    if (parsed == null ||
        !parsed.hasAuthority ||
        parsed.userInfo.isNotEmpty ||
        parsed.query.isNotEmpty ||
        parsed.fragment.isNotEmpty ||
        parsed.path.replaceFirst(RegExp(r'/+$'), '') !=
            '/auth/test/supabase/session') {
      throw StateError('SONUS_TEST_SHARED_AUTH_UPSTREAM is invalid.');
    }
    final loopbackHttp = parsed.scheme == 'http' && _loopback(parsed.host);
    if (parsed.scheme != 'https' && !loopbackHttp) {
      throw StateError(
        'Shared Auth upstream must use HTTPS or exact loopback HTTP.',
      );
    }
    return parsed.replace(path: '/auth/test/supabase/session');
  }
}
