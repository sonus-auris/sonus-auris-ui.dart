// Small in-memory ring buffer of timestamped diagnostic messages, exposed as a stream for the diagnostics UI.
import 'package:rxdart/rxdart.dart';

class DiagnosticEntry {
  const DiagnosticEntry({
    required this.occurredAtUtc,
    required this.level,
    required this.event,
    required this.message,
    this.stack,
    this.details = const {},
  });

  final DateTime occurredAtUtc;
  final String level;
  final String event;
  final String message;
  final StackTrace? stack;
  final Map<String, Object?> details;
}

class DiagnosticLog {
  final BehaviorSubject<List<String>> _entries =
      BehaviorSubject<List<String>>.seeded(const []);
  final PublishSubject<DiagnosticEntry> _events = PublishSubject();

  ValueStream<List<String>> get entries => _entries.stream;
  Stream<DiagnosticEntry> get events => _events.stream;

  void add(
    String message, {
    String level = 'info',
    String event = 'diagnostic',
    StackTrace? stack,
    Map<String, Object?> details = const {},
  }) {
    final nowUtc = DateTime.now().toUtc();
    final timestamp = nowUtc.toLocal().toIso8601String();
    final next = ['[$timestamp] $message', ..._entries.value];
    _entries.add(next.take(80).toList(growable: false));
    _events.add(
      DiagnosticEntry(
        occurredAtUtc: nowUtc,
        level: level,
        event: event,
        message: message,
        stack: stack,
        details: details,
      ),
    );
  }

  Future<void> dispose() async {
    await _events.close();
    await _entries.close();
  }
}
