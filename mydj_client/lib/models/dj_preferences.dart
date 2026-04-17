class DjPreferences {
  final String? llmModel;
  final String talkLength;     // "short" | "medium" | "long"
  final String weatherCity;    // 天気取得用の都市名または "lat,lon" 座標（空文字 = サーバーデフォルト）
  final String personality;    // "standard" | "energetic" | "chill" | "intellectual" | "comedian"
  final String username;       // リスナーの名前（空文字 = 未設定）
  final String djName;         // DJの名前（空文字 = 未設定）
  final String customPrompt;   // カスタム指示（空文字 = なし）
  final int talkFrequency;     // トーク頻度: N曲ごとに1回（1 = 毎曲）

  const DjPreferences({
    this.llmModel,
    this.talkLength = 'medium',
    this.weatherCity = '',
    this.personality = 'standard',
    this.username = '',
    this.djName = '',
    this.customPrompt = '',
    this.talkFrequency = 1,
  });

  DjPreferences copyWith({
    String? llmModel,
    String? talkLength,
    String? weatherCity,
    String? personality,
    String? username,
    String? djName,
    String? customPrompt,
    int? talkFrequency,
  }) =>
      DjPreferences(
        llmModel: llmModel ?? this.llmModel,
        talkLength: talkLength ?? this.talkLength,
        weatherCity: weatherCity ?? this.weatherCity,
        personality: personality ?? this.personality,
        username: username ?? this.username,
        djName: djName ?? this.djName,
        customPrompt: customPrompt ?? this.customPrompt,
        talkFrequency: talkFrequency ?? this.talkFrequency,
      );

  Map<String, dynamic> toJson() => {
        if (llmModel != null) 'llm_model': llmModel,
        'talk_length': talkLength,
        if (weatherCity.isNotEmpty) 'weather_city': weatherCity,
        'personality': personality,
        if (username.isNotEmpty) 'username': username,
        if (djName.isNotEmpty) 'dj_name': djName,
        if (customPrompt.isNotEmpty) 'custom_prompt': customPrompt,
      };
}
