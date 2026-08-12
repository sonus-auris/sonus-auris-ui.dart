import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _maxRequestBytes = 16 * 1024;
const _maxResponseBytes = 256 * 1024;

Future<void> main() async {
  final config = _Config.fromEnvironment();
  final upstreamClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  final limiter = _MinuteLimiter(120);
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    config.port,
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
    ProcessSignal.sigint.watch().listen((_) => _complete(shutdown)),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => _complete(shutdown)),
  ];

  final serving = server.forEach((request) async {
    try {
      await _handle(
        request,
        config: config,
        upstreamClient: upstreamClient,
        limiter: limiter,
      );
    } catch (_) {
      try {
        await _error(
          request.response,
          HttpStatus.internalServerError,
          'bridge_failure',
        );
      } catch (_) {
        // The response may already be closed. Never leak exception details.
      }
    }
  });

  await Future.any([shutdown.future, serving]);
  await server.close(force: true);
  upstreamClient.close(force: true);
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}

void _complete(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

Future<void> _handle(
  HttpRequest request, {
  required _Config config,
  required HttpClient upstreamClient,
  required _MinuteLimiter limiter,
}) async {
  _secure(request.response);
  final origin = request.headers.value(HttpHeaders.originHeader);
  final allowedOrigin = origin == null ? null : _loopbackOrigin(origin);
  if (origin != null && allowedOrigin == null) {
    await _error(request.response, HttpStatus.forbidden, 'origin_rejected');
    return;
  }
  if (allowedOrigin != null) {
    request.response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, allowedOrigin)
      ..set(HttpHeaders.varyHeader, HttpHeaders.originHeader);
  }

  if (request.method == 'OPTIONS' && request.uri.path == '/session') {
    if (allowedOrigin == null) {
      await _error(request.response, HttpStatus.forbidden, 'origin_required');
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
    await _json(request.response, HttpStatus.ok, {'status': 'ok'});
    return;
  }
  if (request.method != 'POST' || request.uri.path != '/session') {
    await _error(request.response, HttpStatus.notFound, 'not_found');
    return;
  }
  if (!limiter.allow()) {
    await _error(
      request.response,
      HttpStatus.tooManyRequests,
      'rate_limited',
    );
    return;
  }
  if (request.headers.contentType?.mimeType != ContentType.json.mimeType) {
    await _error(
      request.response,
      HttpStatus.unsupportedMediaType,
      'json_required',
    );
    return;
  }

  final body = await _readLimited(request, _maxRequestBytes);
  if (body == null) {
    await _error(
      request.response,
      HttpStatus.requestEntityTooLarge,
      'request_too_large',
    );
    return;
  }

  final payload = _decodeObject(body);
  if (payload == null ||
      payload.length != 2 ||
      !payload.containsKey('email') ||
      !payload.containsKey('code')) {
    await _error(request.response, HttpStatus.badRequest, 'invalid_request');
    return;
  }
  final rawEmail = payload['email'];
  final rawCode = payload['code'];
  if (rawEmail is! String || rawCode is! String) {
    await _error(request.response, HttpStatus.badRequest, 'invalid_request');
    return;
  }
  final email = rawEmail.trim().toLowerCase();
  final code = rawCode.trim();
  if (!_syntheticEmail(email) || !RegExp(r'^[0-9]{6}$').hasMatch(code)) {
    await _error(request.response, HttpStatus.forbidden, 'identity_rejected');
    return;
  }

  final upstreamBody = await _exchange(
    upstreamClient,
    config: config,
    email: email,
    code: code,
  );
  if (upstreamBody == null) {
    await _error(request.response, HttpStatus.badGateway, 'upstream_rejected');
    return;
  }
  final upstreamPayload = _decodeObject(upstreamBody);
  if (upstreamPayload == null ||
      !_nonEmptyString(upstreamPayload['access_token']) ||
      !_nonEmptyString(upstreamPayload['refresh_token'])) {
    await _error(
      request.response,
      HttpStatus.badGateway,
      'invalid_upstream_session',
    );
    return;
  }

  request.response.statusCode = HttpStatus.ok;
  request.response.headers.contentType = ContentType.json;
  request.response.add(upstreamBody);
  await request.response.close();
}

Future<Uint8List?> _exchange(
  HttpClient client, {
  required _Config config,
  required String email,
  required String code,
}) async {
  try {
    final request = await client
        .postUrl(config.upstream)
        .timeout(const Duration(seconds: 15));
    request
      ..followRedirects = false
      ..headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType)
      ..headers.contentType = ContentType.json
      ..headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${config.bearer}',
      )
      ..write(
        jsonEncode({
          'email': email,
          'code': code,
          'project': config.project,
        }),
      );
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    final body = await _readLimited(response, _maxResponseBytes);
    if (response.statusCode != HttpStatus.ok) return null;
    return body;
  } on TimeoutException {
    return null;
  } on SocketException {
    return null;
  } on HttpException {
    return null;
  }
}

Map<String, Object?>? _decodeObject(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) return null;
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  } on FormatException {
    return null;
  }
}

bool _nonEmptyString(Object? value) =>
    value is String && value.trim().isNotEmpty;

Future<Uint8List?> _readLimited(Stream<List<int>> stream, int maximum) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    if (builder.length + chunk.length > maximum) return null;
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> _error(HttpResponse response, int status, String code) =>
    _json(response, status, {'error': code});

Future<void> _json(
  HttpResponse response,
  int status,
  Map<String, Object?> payload,
) async {
  _secure(response);
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(payload));
  await response.close();
}

void _secure(HttpResponse response) {
  response.headers
    ..set(HttpHeaders.cacheControlHeader, 'no-store')
    ..set('pragma', 'no-cache')
    ..set('x-content-type-options', 'nosniff')
    ..set('referrer-policy', 'no-referrer');
}

String? _loopbackOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path.isNotEmpty ||
      !_loopback(uri.host) ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri.toString();
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

final class _Config {
  const _Config({
    required this.upstream,
    required this.bearer,
    required this.project,
    required this.port,
  });

  factory _Config.fromEnvironment() {
    final environment = Platform.environment;
    final upstream = _upstream(
      environment['SONUS_TEST_SHARED_AUTH_UPSTREAM'] ?? '',
    );
    final bearer =
        (environment['SONUS_TEST_SHARED_AUTH_BEARER'] ?? '').trim();
    if (bearer.length < 32) {
      throw StateError(
        'SONUS_TEST_SHARED_AUTH_BEARER must contain at least 32 characters.',
      );
    }
    final project =
        (environment['SONUS_TEST_SHARED_AUTH_PROJECT'] ?? '').trim();
    final lower = project.toLowerCase();
    final parts = lower
        .split(RegExp(r'[^a-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .toSet();
    if (!(lower.endsWith('-test') || lower.endsWith('_test')) ||
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
    return _Config(
      upstream: upstream,
      bearer: bearer,
      project: project,
      port: port,
    );
  }

  final Uri upstream;
  final String bearer;
  final String project;
  final int port;

  static Uri _upstream(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path.replaceFirst(RegExp(r'/+$'), '') !=
            '/auth/test/supabase/session') {
      throw StateError('SONUS_TEST_SHARED_AUTH_UPSTREAM is invalid.');
    }
    final loopbackHttp = uri.scheme == 'http' && _loopback(uri.host);
    if (uri.scheme != 'https' && !loopbackHttp) {
      throw StateError(
        'Shared Auth upstream must use HTTPS or exact loopback HTTP.',
      );
    }
    return uri.replace(path: '/auth/test/supabase/session');
  }
}
