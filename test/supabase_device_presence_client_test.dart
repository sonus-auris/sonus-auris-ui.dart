import 'package:audio_dashcam/src/services/supabase_device_presence_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presence state maps device keys and ignores malformed entries', () {
    final state = presenceRefsFromState({
      'device-a': {
        'metas': [
          {'phx_ref': 'a1', 'platform': 'ios'},
          {'phx_ref': 'a2', 'platform': 'ios'},
        ],
      },
      'device-b': {
        'metas': [
          {'phx_ref': 'b1'},
        ],
      },
      'broken': {'metas': 'not-a-list'},
    });

    expect(state, {
      'device-a': {'a1', 'a2'},
      'device-b': {'b1'},
    });
  });

  test('presence diff keeps a device online until its final socket leaves', () {
    final state = <String, Set<String>>{
      'device-a': {'a1', 'a2'},
    };

    applyPresenceDiff(state, {
      'joins': {
        'device-b': {
          'metas': [
            {'phx_ref': 'b1'},
          ],
        },
      },
      'leaves': {
        'device-a': {
          'metas': [
            {'phx_ref': 'a1'},
          ],
        },
      },
    });
    expect(state, {
      'device-a': {'a2'},
      'device-b': {'b1'},
    });

    applyPresenceDiff(state, {
      'joins': const {},
      'leaves': {
        'device-a': {
          'metas': [
            {'phx_ref': 'a2'},
          ],
        },
      },
    });
    expect(state.keys, {'device-b'});
  });
}
