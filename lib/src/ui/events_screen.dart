// Events: recent acoustic detections across the account's unlocked devices.
import 'package:flutter/material.dart';
import 'package:sonus_auris_interfaces/sonus_auris_interfaces.dart' as interfaces;

import '../services/console_controller.dart';
import '../util/relative_time.dart';
import 'console_home.dart';

class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final events = controller.events;
    return ConsolePage(
      title: 'Events',
      onRefresh: () => controller.refreshEvents(),
      child: events.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(
                children: [
                  Icon(Icons.graphic_eq,
                      size: 48, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  const Text(
                    'No detections yet. Acoustic events from your devices '
                    'appear here as they sync.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final event in events) _EventTile(event: event)],
            ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final interfaces.AcousticEvent event;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(_kindIcon(event.kind)),
        title: Text(_kindLabel(event.kind)),
        subtitle: Text(formatEventRange(event.startedAt, event.endedAt)),
        trailing: Text('${(event.confidence * 100).round()}%'),
      ),
    );
  }
}

String _kindLabel(String kind) {
  switch (kind) {
    case 'snore':
      return 'Snoring';
    case 'apneaPattern':
      return 'Possible apnea pattern';
    case 'music':
      return 'Music';
    case 'speech':
      return 'Speech';
    case 'keyword':
      return 'Keyword';
    case 'sleepCycle':
      return 'Sleep cycle';
    case 'sleepCycleAlarm':
      return 'Sleep-cycle alarm';
    case 'suddenLoudNoise':
      return 'Sudden loud noise';
    case 'raisedVoice':
      return 'Raised voice';
    case 'possibleArgumentPattern':
      return 'Possible argument pattern';
    default:
      return kind;
  }
}

IconData _kindIcon(String kind) {
  switch (kind) {
    case 'snore':
    case 'apneaPattern':
    case 'sleepCycle':
    case 'sleepCycleAlarm':
      return Icons.bedtime_outlined;
    case 'music':
      return Icons.music_note_outlined;
    case 'speech':
    case 'keyword':
      return Icons.record_voice_over_outlined;
    case 'suddenLoudNoise':
      return Icons.warning_amber_outlined;
    case 'raisedVoice':
    case 'possibleArgumentPattern':
      return Icons.campaign_outlined;
    default:
      return Icons.graphic_eq;
  }
}
