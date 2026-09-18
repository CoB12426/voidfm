import '../models/dj_preferences.dart';
import '../models/track_info.dart';

/// Lightweight cleanup of the local LLM's raw output — mirrors the host's
/// `postprocess_talk_text` / `clamp_talk_length` (talk_engine.py). No topic
/// or "is this usable" gatekeeping: the on-device model gets the same
/// freedom the host-side one does.
class DjScriptPolicy {
  static const _closingPatterns = [
    r'\bthat\s+wraps\s+it\s+up\b',
    r'\bwrap(?:ping)?\s+up\b',
    r'\bthat\s+wraps\b',
    r'\bsigning\s+off\b',
    r'\bgoodbye\b',
    r'\buntil\s+next\s+time\b',
  ];

  // The on-device TTS (Supertonic, via sherpa-onnx) has no support for
  // inline performance tags, unlike the host's TTS — so unlike the host,
  // every bracket tag is stripped rather than a supported subset kept.
  static final _tagPattern = RegExp(r'\[([A-Za-z][A-Za-z _-]{0,31})\]');

  static const _lengthLimits = {'short': 180, 'medium': 320, 'long': 800};

  static String select({
    required String raw,
    required TrackInfo nextTrack,
    required DjPreferences preferences,
  }) {
    var text = raw.replaceAll(_tagPattern, '');
    for (final pattern in _closingPatterns) {
      text = text.replaceAll(RegExp(pattern, caseSensitive: false), '').trim();
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAllMapped(RegExp(r'\s+([,.!?;:])'), (m) => m[1]!).trim();

    if (text.isEmpty) return 'Here comes the next track.';
    if (!RegExp(r'[.!?]$').hasMatch(text)) text = '$text.';

    return _clamp(text, preferences.talkLength);
  }

  static String _clamp(String text, String talkLength) {
    final limit = _lengthLimits[talkLength] ?? _lengthLimits['medium']!;
    if (text.length <= limit) return text;

    var clipped = text.substring(0, limit).trimRight();
    final cut = [
      clipped.lastIndexOf('.'),
      clipped.lastIndexOf('!'),
      clipped.lastIndexOf('?')
    ].reduce((a, b) => a > b ? a : b);
    if (cut >= (limit * 0.6).floor()) {
      clipped = clipped.substring(0, cut + 1).trimRight();
    } else {
      clipped = clipped.replaceAll(RegExp(r'[,;:.!?\s]+$'), '');
      if (clipped.length >= limit) {
        clipped = clipped
            .substring(0, limit - 1)
            .replaceAll(RegExp(r'[,;:.!?\s]+$'), '');
      }
      clipped = '$clipped.';
    }
    return clipped;
  }
}
