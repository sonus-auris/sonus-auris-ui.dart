/// Store-safe Sonus Auris pagelet v1 model.
///
/// Pagelets are declarative data and layout. They are not executable plug-ins:
/// unknown versions, fields, components, and actions fail closed.
library;

enum PageletSurface {
  deviceSummary('device-summary'),
  accountSummary('account-summary'),
  connectionStatus('connection-status'),
  help('help'),
  privacy('privacy'),
  diagnostics('diagnostics'),
  releaseNotes('release-notes'),
  acousticEventSummary('acoustic-event-summary');

  const PageletSurface(this.wireName);
  final String wireName;

  static PageletSurface parse(String value) => values.firstWhere(
        (surface) => surface.wireName == value,
        orElse: () => throw FormatException('Unknown pagelet surface: $value'),
      );
}

enum PageletComponentType {
  section,
  text,
  status,
  metric,
  list,
  button,
  spacer;

  static PageletComponentType parse(String value) => values.firstWhere(
        (type) => type.name == value,
        orElse: () =>
            throw FormatException('Unknown pagelet component type: $value'),
      );
}

enum PageletTone { neutral, positive, warning, critical, muted }

enum PageletSemanticRole { heading, body, caption, status, metric, action }

enum PageletActionKind {
  navigate('native.navigate'),
  refresh('native.refresh'),
  confirmDeviceRename('native.confirm-device-rename'),
  confirmDeviceRevoke('native.confirm-device-revoke'),
  playAuthorizedItem('native.play-authorized-item'),
  openAllowlistedUrl('native.open-allowlisted-url');

  const PageletActionKind(this.wireName);
  final String wireName;

  static PageletActionKind parse(String value) => values.firstWhere(
        (kind) => kind.wireName == value,
        orElse: () => throw FormatException('Unknown pagelet action: $value'),
      );
}

class PageletAction {
  const PageletAction({
    required this.id,
    required this.kind,
    this.params = const <String, Object?>{},
    this.requiresConfirmation = false,
  });

  final String id;
  final PageletActionKind kind;
  final Map<String, Object?> params;
  final bool requiresConfirmation;

  factory PageletAction.fromJson(Map<String, Object?> json) {
    _rejectUnknownKeys(
      json,
      const {'id', 'kind', 'params', 'requiresConfirmation'},
      'pagelet action',
    );
    final params = _optionalObject(json, 'params');
    if (params.length > 8) {
      throw const FormatException('Pagelet action params exceed 8 entries');
    }
    final paramName = RegExp(r'^[a-z][A-Za-z0-9]{0,39}$');
    for (final entry in params.entries) {
      if (!paramName.hasMatch(entry.key)) {
        throw FormatException('Invalid pagelet action param: ${entry.key}');
      }
      if (!_isScalar(entry.value)) {
        throw FormatException(
          'Pagelet action param ${entry.key} must be a scalar value',
        );
      }
    }
    return PageletAction(
      id: _requiredId(json, 'id'),
      kind: PageletActionKind.parse(_requiredString(json, 'kind')),
      params: Map.unmodifiable(params),
      requiresConfirmation:
          _optionalBool(json, 'requiresConfirmation') ?? false,
    );
  }
}

class PageletComponent {
  const PageletComponent({
    required this.id,
    required this.type,
    this.text,
    this.label,
    this.value,
    this.tone,
    this.semanticRole,
    this.children = const <PageletComponent>[],
    this.items = const <String>[],
    this.size,
    this.action,
  });

  final String id;
  final PageletComponentType type;
  final String? text;
  final String? label;
  final Object? value;
  final PageletTone? tone;
  final PageletSemanticRole? semanticRole;
  final List<PageletComponent> children;
  final List<String> items;
  final int? size;
  final PageletAction? action;

  factory PageletComponent.fromJson(
    Map<String, Object?> json, {
    int depth = 0,
  }) {
    if (depth > 8) {
      throw const FormatException('Pagelet component nesting exceeds 8 levels');
    }
    _rejectUnknownKeys(
      json,
      const {
        'id',
        'type',
        'text',
        'label',
        'value',
        'tone',
        'semanticRole',
        'children',
        'items',
        'size',
        'action',
      },
      'pagelet component',
    );

    final type = PageletComponentType.parse(_requiredString(json, 'type'));
    final childrenJson = _optionalList(json, 'children');
    if (childrenJson.length > 32) {
      throw const FormatException('Pagelet section exceeds 32 children');
    }
    final children = <PageletComponent>[
      for (final child in childrenJson)
        PageletComponent.fromJson(
          _asObject(child, 'pagelet child'),
          depth: depth + 1,
        ),
    ];
    final items = _optionalList(json, 'items').map((item) {
      if (item is! String || item.length > 500) {
        throw const FormatException(
          'Pagelet list items must be strings up to 500 characters',
        );
      }
      return item;
    }).toList(growable: false);
    if (items.length > 50) {
      throw const FormatException('Pagelet list exceeds 50 items');
    }

    final text = _optionalString(json, 'text', maxLength: 2000);
    final label = _optionalString(json, 'label', maxLength: 120);
    final value = json['value'];
    if (json.containsKey('value') && !_isScalar(value)) {
      throw const FormatException('Pagelet metric value must be scalar');
    }
    final size = _optionalInt(json, 'size');
    final actionJson = json['action'];
    final action = actionJson == null
        ? null
        : PageletAction.fromJson(_asObject(actionJson, 'pagelet action'));
    final tone = _optionalEnum(
      json,
      'tone',
      PageletTone.values,
      (value) => value.name,
    );
    final semanticRole = _optionalEnum(
      json,
      'semanticRole',
      PageletSemanticRole.values,
      (value) => value.name,
    );

    switch (type) {
      case PageletComponentType.section:
        if (!json.containsKey('children')) {
          throw const FormatException('Pagelet section requires children');
        }
      case PageletComponentType.text:
      case PageletComponentType.status:
        if (text == null) {
          throw FormatException('Pagelet ${type.name} requires text');
        }
      case PageletComponentType.metric:
        if (label == null || !json.containsKey('value')) {
          throw const FormatException(
            'Pagelet metric requires label and value',
          );
        }
      case PageletComponentType.list:
        if (!json.containsKey('items')) {
          throw const FormatException('Pagelet list requires items');
        }
      case PageletComponentType.button:
        if (text == null || action == null) {
          throw const FormatException(
            'Pagelet button requires text and an action',
          );
        }
      case PageletComponentType.spacer:
        if (size == null || size < 4 || size > 64) {
          throw const FormatException(
            'Pagelet spacer size must be between 4 and 64',
          );
        }
    }

    return PageletComponent(
      id: _requiredId(json, 'id'),
      type: type,
      text: text,
      label: label,
      value: value,
      tone: tone,
      semanticRole: semanticRole,
      children: List.unmodifiable(children),
      items: List.unmodifiable(items),
      size: size,
      action: action,
    );
  }
}

class PageletDocument {
  const PageletDocument({
    required this.pageletId,
    required this.revision,
    required this.surface,
    required this.components,
    this.title,
  });

  static const schemaVersion = '1.0.0';

  final String pageletId;
  final int revision;
  final PageletSurface surface;
  final String? title;
  final List<PageletComponent> components;

  factory PageletDocument.fromJson(Map<String, Object?> json) {
    _rejectUnknownKeys(
      json,
      const {
        'schemaVersion',
        'pageletId',
        'revision',
        'surface',
        'title',
        'components',
        'metadata',
      },
      'pagelet document',
    );
    final version = _requiredString(json, 'schemaVersion');
    if (version != schemaVersion) {
      throw FormatException('Unsupported pagelet schema version: $version');
    }
    final revision = _requiredInt(json, 'revision');
    if (revision < 1) {
      throw const FormatException('Pagelet revision must be positive');
    }
    final componentsJson = _requiredList(json, 'components');
    if (componentsJson.isEmpty || componentsJson.length > 64) {
      throw const FormatException(
        'Pagelet document must contain between 1 and 64 components',
      );
    }
    final components = <PageletComponent>[
      for (final component in componentsJson)
        PageletComponent.fromJson(_asObject(component, 'pagelet component')),
    ];

    final ids = <String>{};
    void collectIds(List<PageletComponent> nodes) {
      for (final node in nodes) {
        if (!ids.add(node.id)) {
          throw FormatException('Duplicate pagelet component id: ${node.id}');
        }
        collectIds(node.children);
      }
    }

    collectIds(components);
    final actionIds = <String>{};
    void collectActionIds(List<PageletComponent> nodes) {
      for (final node in nodes) {
        final action = node.action;
        if (action != null && !actionIds.add(action.id)) {
          throw FormatException('Duplicate pagelet action id: ${action.id}');
        }
        collectActionIds(node.children);
      }
    }

    collectActionIds(components);

    return PageletDocument(
      pageletId: _requiredId(json, 'pageletId'),
      revision: revision,
      surface: PageletSurface.parse(_requiredString(json, 'surface')),
      title: _optionalString(json, 'title', maxLength: 120),
      components: List.unmodifiable(components),
    );
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

String _requiredId(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  if (!RegExp(r'^[a-z][a-z0-9-]{1,63}$').hasMatch(value)) {
    throw FormatException('$key is not a valid pagelet identifier');
  }
  return value;
}

String? _optionalString(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('$key must be a non-empty string <= $maxLength chars');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('$key must be an integer');
  }
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) {
    throw FormatException('$key must be an integer');
  }
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) {
    throw FormatException('$key must be a boolean');
  }
  return value;
}

List<Object?> _requiredList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('$key must be an array');
  }
  return List<Object?>.from(value);
}

List<Object?> _optionalList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const <Object?>[];
  if (value is! List) {
    throw FormatException('$key must be an array');
  }
  return List<Object?>.from(value);
}

Map<String, Object?> _optionalObject(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value == null) return const <String, Object?>{};
  return _asObject(value, key);
}

T? _optionalEnum<T>(
  Map<String, Object?> json,
  String key,
  List<T> values,
  String Function(T value) wireName,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$key must be a string');
  }
  for (final candidate in values) {
    if (wireName(candidate) == value) return candidate;
  }
  throw FormatException('Unknown $key: $value');
}

bool _isScalar(Object? value) =>
    value == null || value is String || value is num || value is bool;
