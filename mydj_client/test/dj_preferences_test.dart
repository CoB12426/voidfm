import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/models/dj_preferences.dart';

void main() {
  test('serializes host-bound DJ preferences', () {
    const prefs = DjPreferences(
      llmModel: 'model-a',
      ttsSpeaker: 'voice-a',
      talkLength: 'short',
      weatherCity: 'Tokyo',
      personality: 'chill',
      username: 'Aki',
      djName: 'Nova',
      customPrompt: 'Keep it dry.',
      talkFrequency: 3,
    );

    expect(prefs.toJson(), {
      'llm_model': 'model-a',
      'tts_speaker': 'voice-a',
      'talk_length': 'short',
      'weather_city': 'Tokyo',
      'personality': 'chill',
      'username': 'Aki',
      'dj_name': 'Nova',
      'custom_prompt': 'Keep it dry.',
    });
  });
}
