// Small in-memory ring buffer of timestamped diagnostic messages, exposed as a stream for the diagnostics UI.
import 'package:rxdart/rxdart.dart';

class DiagnosticLog {
  final BehaviorSubject<List<String>> _entries =
      BehaviorSubject<List<String>>.seeded(const []);

  ValueStream<List<String>> get entries => _entries.stream;

  void add(String message) {
    final timestamp = DateTime.now().toLocal().toIso8601String();
    final next = ['[$timestamp] $message', ..._entries.value];
    _entries.add(next.take(80).toList(growable: false));
  }

  Future<void> dispose() => _entries.close();
}
