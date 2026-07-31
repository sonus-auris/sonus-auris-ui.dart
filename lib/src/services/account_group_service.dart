// Passwordless account-group invitations and trusted identity membership.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';
import 'supabase_key_policy.dart';

enum AccountInviteDelivery { email, phone }

class AccountGroupMember {
  const AccountGroupMember({
    required this.groupId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.identityHint,
    this.revokedAt,
  });

  final String groupId;
  final String userId;
  final String role;
  final String? identityHint;
  final DateTime joinedAt;
  final DateTime? revokedAt;

  bool get isOwner => role == 'owner';
  bool get isActive => revokedAt == null;

  factory AccountGroupMember.fromJson(Map<String, Object?> json) {
    return AccountGroupMember(
      groupId: (json['group_id'] as String? ?? '').trim(),
      userId: (json['user_id'] as String? ?? '').trim(),
      role: (json['role'] as String? ?? '').trim(),
      identityHint: (json['identity_hint'] as String?)?.trim(),
      joinedAt:
          DateTime.tryParse(json['joined_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      revokedAt: DateTime.tryParse(
        json['revoked_at'] as String? ?? '',
      )?.toUtc(),
    );
  }
}

class AccountInvitation {
  const AccountInvitation({
    required this.id,
    required this.groupId,
    required this.deliveryKind,
    required this.destinationHint,
    required this.expiresAt,
    required this.createdAt,
    this.acceptedAt,
    this.revokedAt,
  });

  final String id;
  final String groupId;
  final String deliveryKind;
  final String destinationHint;
  final DateTime expiresAt;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final DateTime? revokedAt;

  bool get isPending =>
      acceptedAt == null &&
      revokedAt == null &&
      expiresAt.isAfter(DateTime.now().toUtc());

  factory AccountInvitation.fromJson(Map<String, Object?> json) {
    return AccountInvitation(
      id: (json['id'] as String? ?? '').trim(),
      groupId: (json['group_id'] as String? ?? '').trim(),
      deliveryKind: (json['delivery_kind'] as String? ?? '').trim(),
      destinationHint: (json['destination_hint'] as String? ?? '').trim(),
      expiresAt:
          DateTime.tryParse(json['expires_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      acceptedAt: DateTime.tryParse(
        json['accepted_at'] as String? ?? '',
      )?.toUtc(),
      revokedAt: DateTime.tryParse(
        json['revoked_at'] as String? ?? '',
      )?.toUtc(),
    );
  }
}

class AccountInviteShare {
  const AccountInviteShare({
    required this.invitationId,
    required this.groupId,
    required this.destination,
    required this.delivery,
    required this.token,
    required this.link,
    required this.expiresAt,
  });

  final String invitationId;
  final String groupId;
  final String destination;
  final AccountInviteDelivery delivery;
  final String token;
  final Uri link;
  final DateTime expiresAt;
}

class AccountGroupSnapshot {
  const AccountGroupSnapshot({
    required this.groupId,
    this.members = const <AccountGroupMember>[],
    this.invitations = const <AccountInvitation>[],
  });

  final String groupId;
  final List<AccountGroupMember> members;
  final List<AccountInvitation> invitations;
}

class AccountGroupService {
  AccountGroupService({
    http.Client? httpClient,
    Random? secureRandom,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _httpClient = httpClient ?? http.Client(),
       _random = secureRandom ?? Random.secure();

  final http.Client _httpClient;
  final Random _random;
  final Duration requestTimeout;

  bool canUse(AppConfig config, CloudSecrets secrets) =>
      config.hasSupabaseAuthConfig && secrets.hasSupabaseToken;

  Future<String> ensureGroup({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final decoded = await _rpc(
      config,
      secrets,
      'ensure_account_group',
      const {},
    );
    final groupId = decoded is String ? decoded.trim() : '';
    if (groupId.isEmpty) {
      throw StateError('Supabase did not return an account group.');
    }
    return groupId;
  }

  Future<AccountGroupSnapshot> load({
    required AppConfig config,
    required CloudSecrets secrets,
  }) async {
    final groupId = await ensureGroup(config: config, secrets: secrets);
    final responses = await Future.wait([
      _getRows(config, secrets, 'account_group_members', {
        'group_id': 'eq.$groupId',
        'order': 'joined_at.asc',
      }),
      _getRows(config, secrets, 'account_invitations', {
        'group_id': 'eq.$groupId',
        'order': 'created_at.desc',
      }),
    ]);
    return AccountGroupSnapshot(
      groupId: groupId,
      members: [
        for (final row in responses[0]) AccountGroupMember.fromJson(row),
      ],
      invitations: [
        for (final row in responses[1]) AccountInvitation.fromJson(row),
      ],
    );
  }

  Future<AccountInviteShare> createInvite({
    required AppConfig config,
    required CloudSecrets secrets,
    required AccountInviteDelivery delivery,
    required String destination,
  }) async {
    final normalized = destination.trim();
    _validateDestination(delivery, normalized);
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    final decoded = await _rpc(config, secrets, 'create_account_invite', {
      'p_delivery_kind': delivery.name,
      'p_destination_hint': _maskedDestination(delivery, normalized),
      'p_token': token,
    });
    final rows = _asRows(decoded);
    if (rows.isEmpty) {
      throw StateError('Supabase did not create the invitation.');
    }
    final row = rows.first;
    final invitationId = (row['invite_id'] as String? ?? '').trim();
    final groupId = (row['group_id'] as String? ?? '').trim();
    final expiresAt = DateTime.tryParse(
      row['expires_at'] as String? ?? '',
    )?.toUtc();
    if (invitationId.isEmpty || groupId.isEmpty || expiresAt == null) {
      throw StateError('Supabase returned an invalid invitation.');
    }
    final link = Uri(
      scheme: 'sonusauris',
      host: 'invite',
      path: '/join',
      queryParameters: {'token': token},
    );
    return AccountInviteShare(
      invitationId: invitationId,
      groupId: groupId,
      destination: normalized,
      delivery: delivery,
      token: token,
      link: link,
      expiresAt: expiresAt,
    );
  }

  Future<String> acceptInvite({
    required AppConfig config,
    required CloudSecrets secrets,
    required String token,
  }) async {
    final normalized = token.trim();
    if (normalized.length < 32 || normalized.length > 512) {
      throw const FormatException('The invitation link is invalid.');
    }
    final decoded = await _rpc(config, secrets, 'accept_account_invite', {
      'p_token': normalized,
    });
    final groupId = decoded is String ? decoded.trim() : '';
    if (groupId.isEmpty) {
      throw StateError('Supabase did not accept the invitation.');
    }
    return groupId;
  }

  Future<void> revokeMember({
    required AppConfig config,
    required CloudSecrets secrets,
    required String userId,
  }) async {
    await _rpc(config, secrets, 'revoke_account_member', {
      'p_user_id': userId.trim(),
    });
  }

  Future<void> revokeInvitation({
    required AppConfig config,
    required CloudSecrets secrets,
    required String invitationId,
  }) async {
    await _rpc(config, secrets, 'revoke_account_invite', {
      'p_invite_id': invitationId.trim(),
    });
  }

  Future<Object?> _rpc(
    AppConfig config,
    CloudSecrets secrets,
    String function,
    Map<String, Object?> body,
  ) async {
    _requireConfigured(config, secrets);
    final response = await _httpClient
        .post(
          _uri(config, 'rpc/$function'),
          headers: _headers(config, secrets),
          body: jsonEncode(body),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_error(response.body, 'Account update failed.'));
    }
    if (response.body.trim().isEmpty) return null;
    return jsonDecode(response.body);
  }

  Future<List<Map<String, Object?>>> _getRows(
    AppConfig config,
    CloudSecrets secrets,
    String table,
    Map<String, String> query,
  ) async {
    _requireConfigured(config, secrets);
    final response = await _httpClient
        .get(
          _uri(config, table).replace(queryParameters: query),
          headers: _headers(config, secrets),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_error(response.body, 'Account read failed.'));
    }
    return _asRows(jsonDecode(response.body));
  }

  List<Map<String, Object?>> _asRows(Object? decoded) {
    if (decoded is! List) return const <Map<String, Object?>>[];
    return [
      for (final row in decoded)
        if (row is Map) row.cast<String, Object?>(),
    ];
  }

  Uri _uri(AppConfig config, String suffix) {
    requireSafeSupabaseClientKey(config.supabaseAnonKey);
    final base = Uri.parse(config.supabaseUrl.trim());
    if (base.host.isEmpty ||
        (base.scheme != 'https' &&
            base.host != 'localhost' &&
            base.host != '127.0.0.1')) {
      throw const FormatException('Supabase URL must use HTTPS.');
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        'rest',
        'v1',
        ...suffix.split('/'),
      ],
      fragment: '',
    );
  }

  Map<String, String> _headers(AppConfig config, CloudSecrets secrets) => {
    'apikey': config.supabaseAnonKey.trim(),
    'authorization': 'Bearer ${secrets.supabaseAccessToken.trim()}',
    'content-type': 'application/json',
    'accept': 'application/json',
  };

  void _requireConfigured(AppConfig config, CloudSecrets secrets) {
    if (!canUse(config, secrets)) {
      throw StateError('Sign in before managing account access.');
    }
  }

  void _validateDestination(
    AccountInviteDelivery delivery,
    String destination,
  ) {
    if (delivery == AccountInviteDelivery.email) {
      final parts = destination.split('@');
      if (parts.length != 2 ||
          parts.first.isEmpty ||
          !parts.last.contains('.')) {
        throw const FormatException('Enter a valid email address.');
      }
      return;
    }
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(destination)) {
      throw const FormatException(
        'Enter the phone number in international format, such as +15551234567.',
      );
    }
  }

  String _maskedDestination(
    AccountInviteDelivery delivery,
    String destination,
  ) {
    if (delivery == AccountInviteDelivery.email) {
      final parts = destination.split('@');
      final local = parts.first;
      final shown = local.length <= 2 ? local[0] : local.substring(0, 2);
      return '$shown***@${parts.last.toLowerCase()}';
    }
    return '••••${destination.substring(destination.length - 4)}';
  }

  String _error(String body, String fallback) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final message = decoded['message'] ?? decoded['error_description'];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    } catch (_) {
      // Fall through to a stable user-facing error.
    }
    return fallback;
  }

  void close() => _httpClient.close();
}
