import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/services/supertonic_service.dart';

// Run with --dart-define=SUPER_TTS_MODEL_DIR=/absolute/path/to/extracted/model
const modelDirectory = String.fromEnvironment('SUPER_TTS_MODEL_DIR');

void main() {
  test('official Supertonic 3 model synthesizes an English WAV', () async {
    final wav = await SupertonicService.instance.synthesize(
      modelDirectory,
      "You're listening to VoidFM. Coming up next, another great track.",
    );
    expect(wav.length, greaterThan(44));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    SupertonicService.instance.reset();
  }, skip: modelDirectory.isEmpty ? 'Set SUPER_TTS_MODEL_DIR to run' : false);

  test('voice selection and slower synthesis work with official model',
      () async {
    final slow = await SupertonicService.instance.synthesize(
      modelDirectory,
      'Coming up next on VoidFM, another great track.',
      speaker: 'F1',
      speed: 0.85,
    );
    final fast = await SupertonicService.instance.synthesize(
      modelDirectory,
      'Coming up next on VoidFM, another great track.',
      speaker: 'F1',
      speed: 1.1,
    );
    final male = await SupertonicService.instance.synthesize(
      modelDirectory,
      'Coming up next on VoidFM, another great track.',
      speaker: 'M1',
    );
    expect(slow.length, greaterThan(fast.length));
    expect(male.length, greaterThan(44));
    SupertonicService.instance.reset();
  }, skip: modelDirectory.isEmpty ? 'Set SUPER_TTS_MODEL_DIR to run' : false);
}
