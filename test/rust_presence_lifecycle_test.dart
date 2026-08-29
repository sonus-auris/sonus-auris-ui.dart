import 'package:audio_dashcam/src/services/rust_presence_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

String _stateKey(RustPresenceLifecycle state) =>
    '${state.phase.index}:${state.generation}:${state.retryAttempt}';

void _expectSameState(
  RustPresenceLifecycle actual,
  RustPresenceLifecycle expected,
) {
  expect(_stateKey(actual), _stateKey(expected));
}

void main() {
  test('authenticated lifecycle produces only phase-appropriate effects', () {
    var state = const RustPresenceLifecycle();

    var transition = state.advance(RustPresenceInput.configure);
    state = transition.state;
    expect(state.phase, RustPresencePhase.connecting);
    expect(transition.effects, [
      RustPresenceEffect.closeTransport,
      RustPresenceEffect.openTransport,
    ]);

    transition = state.advance(
      RustPresenceInput.transportReady,
      eventGeneration: state.generation,
    );
    state = transition.state;
    expect(state.phase, RustPresencePhase.authenticating);
    expect(transition.effects, [RustPresenceEffect.sendAuthentication]);

    transition = state.advance(
      RustPresenceInput.authenticated,
      eventGeneration: state.generation,
    );
    state = transition.state;
    expect(state.phase, RustPresencePhase.connected);
    expect(transition.effects, [RustPresenceEffect.startHeartbeat]);

    transition = state.advance(
      RustPresenceInput.heartbeatTimer,
      eventGeneration: state.generation,
    );
    expect(transition.effects, [RustPresenceEffect.sendHeartbeat]);
    expect(state.acceptsPresence, isTrue);
  });

  test('stale callbacks stutter after replacement, failure, and close', () {
    var state = const RustPresenceLifecycle()
        .advance(RustPresenceInput.configure)
        .state;
    final firstGeneration = state.generation;

    state = state.advance(RustPresenceInput.configure).state;
    final replacement = state;
    for (final input in RustPresenceInput.values.where(
      (input) =>
          input != RustPresenceInput.configure &&
          input != RustPresenceInput.close,
    )) {
      final stale = state.advance(input, eventGeneration: firstGeneration);
      _expectSameState(stale.state, replacement);
      expect(stale.effects, isEmpty, reason: input.name);
    }

    state = state.advance(RustPresenceInput.close).state;
    final closed = state;
    for (final input in RustPresenceInput.values.where(
      (input) =>
          input != RustPresenceInput.configure &&
          input != RustPresenceInput.close,
    )) {
      final stale = state.advance(
        input,
        eventGeneration: replacement.generation,
      );
      _expectSameState(stale.state, closed);
      expect(stale.effects, isEmpty, reason: input.name);
    }

    final reopened = state.advance(RustPresenceInput.configure);
    expect(reopened.state.phase, RustPresencePhase.connecting);
    expect(reopened.state.generation, closed.generation + 1);
  });

  test('retry backoff is monotone, capped, and finitely exhausted', () {
    var state = const RustPresenceLifecycle()
        .advance(RustPresenceInput.configure)
        .state;
    final delays = <Duration>[];

    for (
      var attempt = 0;
      attempt < RustPresenceLifecycle.maxRetryAttempts;
      attempt += 1
    ) {
      state = state
          .advance(
            RustPresenceInput.transportFailed,
            eventGeneration: state.generation,
          )
          .state;
      delays.add(state.reconnectDelay);
      state = state
          .advance(
            RustPresenceInput.retryTimer,
            eventGeneration: state.generation,
          )
          .state;
    }

    expect(delays.map((delay) => delay.inSeconds), [1, 2, 4, 8, 16, 32, 60]);

    final exhausted = state.advance(
      RustPresenceInput.transportFailed,
      eventGeneration: state.generation,
    );
    expect(exhausted.state.phase, RustPresencePhase.retryExhausted);
    expect(
      exhausted.state.retryAttempt,
      RustPresenceLifecycle.maxRetryAttempts,
    );
    expect(exhausted.effects, [RustPresenceEffect.closeTransport]);

    final timerAfterExhaustion = exhausted.state.advance(
      RustPresenceInput.retryTimer,
      eventGeneration: exhausted.state.generation,
    );
    expect(timerAfterExhaustion.isStutter, isTrue);
    _expectSameState(timerAfterExhaustion.state, exhausted.state);
  });

  test('bounded exploration is total, deterministic, and invariant-safe', () {
    final initial = const RustPresenceLifecycle();
    final frontier = <RustPresenceLifecycle>[initial];
    final seen = <String>{_stateKey(initial)};

    for (var depth = 0; depth < 20 && frontier.isNotEmpty; depth += 1) {
      final currentLayer = List<RustPresenceLifecycle>.of(frontier);
      frontier.clear();
      for (final state in currentLayer) {
        expect(state.isValid, isTrue, reason: _stateKey(state));
        for (final input in RustPresenceInput.values) {
          final generations =
              input == RustPresenceInput.configure ||
                  input == RustPresenceInput.close
              ? const <int?>[null]
              : <int?>[
                  state.generation - 1,
                  state.generation,
                  state.generation + 1,
                  null,
                ];
          for (final eventGeneration in generations) {
            final first = state.advance(
              input,
              eventGeneration: eventGeneration,
            );
            final second = state.advance(
              input,
              eventGeneration: eventGeneration,
            );
            expect(first.state.isValid, isTrue);
            expect(_stateKey(first.state), _stateKey(second.state));
            expect(first.effects, second.effects);

            final isStaleTransportEvent =
                input != RustPresenceInput.configure &&
                input != RustPresenceInput.close &&
                eventGeneration != state.generation;
            if (isStaleTransportEvent) {
              _expectSameState(first.state, state);
              expect(first.effects, isEmpty);
            }

            final key = _stateKey(first.state);
            if (first.state.generation <= 20 && seen.add(key)) {
              frontier.add(first.state);
            }
          }
        }
      }
    }

    expect(seen.length, greaterThan(70));
  });
}
