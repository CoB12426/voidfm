class DjPreferences {
  final String? llmModel;
  final String language;       // "ja" | "en"
  final String talkLength;     // "short" | "medium" | "long"
  final String djVoice;        // "default" | "JAMES" | "E-GIRL" | "ETHAN" etc.
  final String weatherCity;    // 天気取得用の都市名または "lat,lon" 座標（空文字 = サーバーデフォルト）
  final String personality;    // "standard" | "energetic" | "chill" | "intellectual" | "comedian"

  const DjPreferences({
    this.llmModel,
    this.language = 'ja',
    this.talkLength = 'medium',
    this.djVoice = 'default',
    this.weatherCity = '',
    this.personality = 'standard',
  });

  DjPreferences copyWith({
    String? llmModel,
    String? language,
    String? talkLength,
    String? djVoice,
    String? weatherCity,
    String? personality,
  }) =>
      DjPreferences(
        llmModel: llmModel ?? this.llmModel,
        language: language ?? this.language,
        talkLength: talkLength ?? this.talkLength,
        djVoice: djVoice ?? this.djVoice,
        weatherCity: weatherCity ?? this.weatherCity,
        personality: personality ?? this.personality,
      );

  Map<String, dynamic> toJson() => {
        if (llmModel != null) 'llm_model': llmModel,
        'language': language,
        'talk_length': talkLength,
        'dj_voice': djVoice,
        if (weatherCity.isNotEmpty) 'weather_city': weatherCity,
        'personality': personality,
      };
}
