// Tiny time formatting helpers (no intl dependency).

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "just now" / "5m ago" / "3h ago" / "2d ago" / "4mo ago" / "1y ago".
String relativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) {
    return 'never';
  }
  final reference = (now ?? DateTime.now()).toUtc();
  final delta = reference.difference(time.toUtc());
  if (delta.isNegative || delta.inMinutes < 1) {
    return 'just now';
  }
  if (delta.inHours < 1) {
    return '${delta.inMinutes}m ago';
  }
  if (delta.inDays < 1) {
    return '${delta.inHours}h ago';
  }
  if (delta.inDays < 30) {
    return '${delta.inDays}d ago';
  }
  if (delta.inDays < 365) {
    return '${delta.inDays ~/ 30}mo ago';
  }
  return '${delta.inDays ~/ 365}y ago';
}

/// Same, but parses an ISO-8601 string first; returns "never" when blank or
/// unparsable.
String relativeTimeIso(String? iso, {DateTime? now}) {
  if (iso == null || iso.trim().isEmpty) {
    return 'never';
  }
  return relativeTime(DateTime.tryParse(iso), now: now);
}

String _two(int value) => value.toString().padLeft(2, '0');

/// "Jul 17, 13:02" in local time.
String formatStamp(DateTime time) {
  final local = time.toLocal();
  return '${_months[local.month - 1]} ${local.day}, '
      '${_two(local.hour)}:${_two(local.minute)}';
}

/// "Jul 17, 13:02 – 13:07" (same day) or "Jul 17, 23:58 – Jul 18, 00:04".
String formatEventRange(String startedIso, String endedIso) {
  final started = DateTime.tryParse(startedIso);
  final ended = DateTime.tryParse(endedIso);
  if (started == null) {
    return startedIso;
  }
  final startText = formatStamp(started);
  if (ended == null) {
    return startText;
  }
  final sameDay =
      started.toLocal().year == ended.toLocal().year &&
      started.toLocal().month == ended.toLocal().month &&
      started.toLocal().day == ended.toLocal().day;
  final endLocal = ended.toLocal();
  final endText = sameDay
      ? '${_two(endLocal.hour)}:${_two(endLocal.minute)}'
      : formatStamp(ended);
  return '$startText – $endText';
}
