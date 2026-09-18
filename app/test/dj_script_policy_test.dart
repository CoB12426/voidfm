import 'package:flutter_test/flutter_test.dart';
import 'package:voidfm/models/dj_preferences.dart';
import 'package:voidfm/models/track_info.dart';
import 'package:voidfm/services/dj_script_policy.dart';

void main() {
  const track = TrackInfo(title: 'Midnight City', artist: 'M83');
  const preferences = DjPreferences();

  String select(String raw, [DjPreferences prefs = preferences]) =>
      DjScriptPolicy.select(raw: raw, nextTrack: track, preferences: prefs);

  test('keeps a grounded English introduction', () {
    const raw =
        "Up next on VoidFM, here's Midnight City by M83. Let's keep the music going.";
    expect(select(raw), raw);
  });

  test('strips bracket tags the on-device TTS cannot perform', () {
    expect(select('[laugh] Up next, Midnight City by M83. [sigh]'),
        'Up next, Midnight City by M83.');
  });

  test('removes sign-off phrases so the show keeps going', () {
    final result = select('Midnight City by M83 is next. Until next time!');
    expect(result.toLowerCase(), isNot(contains('until next time')));
    expect(result, startsWith('Midnight City by M83 is next.'));
  });

  test('joins punctuation left dangling by removed tags', () {
    expect(select('Up next, Midnight City by M83 [laugh] !'),
        'Up next, Midnight City by M83!');
  });

  test('adds terminal punctuation', () {
    expect(select('Here is Midnight City by M83'),
        'Here is Midnight City by M83.');
  });

  test('falls back to a short line for empty output', () {
    expect(select('   '), 'Here comes the next track.');
  });

  test('clamps to the talk length at a sentence boundary', () {
    final raw = List.filled(20, 'Midnight City by M83 is up next.').join(' ');
    final result = select(raw, const DjPreferences(talkLength: 'short'));
    expect(result.length, lessThanOrEqualTo(180));
    expect(result, endsWith('.'));
  });
}
