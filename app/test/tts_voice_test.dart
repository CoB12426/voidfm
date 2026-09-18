import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/models/dj_preferences.dart';
import 'package:voidfm/models/tts_voice.dart';

void main() {
  test('all ten Supertonic voices map to speaker IDs', () {
    expect(TtsVoice.ids.length, 10);
    expect(TtsVoice.speakerId('F1'), 0);
    expect(TtsVoice.speakerId('M1'), 5);
    expect(TtsVoice.speakerId('M5'), 9);
    expect(TtsVoice.speakerId('unknown'), 0);
  });

  test('voice and pace survive preference copy', () {
    const original = DjPreferences(localVoice: 'M3', ttsSpeed: 0.9);
    final next = original.copyWith(talkLength: 'short');
    expect(next.localVoice, 'M3');
    expect(next.ttsSpeed, 0.9);
  });
}
