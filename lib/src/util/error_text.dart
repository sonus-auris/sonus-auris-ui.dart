// User-presentable message extraction for caught errors.

/// The human-readable message carried by validation ([FormatException]) and
/// service ([StateError]) failures; falls back to `toString()`.
String errorText(Object error) {
  if (error is FormatException) {
    return error.message;
  }
  if (error is StateError) {
    return error.message;
  }
  return '$error';
}
