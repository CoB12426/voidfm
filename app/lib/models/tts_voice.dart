class TtsVoice {
  static const ids = [
    'F1',
    'F2',
    'F3',
    'F4',
    'F5',
    'M1',
    'M2',
    'M3',
    'M4',
    'M5'
  ];
  static const defaultId = 'F1';

  static String validated(String? id) => ids.contains(id) ? id! : defaultId;

  static int speakerId(String? id) => ids.indexOf(validated(id));

  static String label(String id) => id.startsWith('F')
      ? 'Female ${id.substring(1)}'
      : 'Male ${id.substring(1)}';
}
