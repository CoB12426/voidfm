class DjPreferences {
  final String? llmModel;
  final String? ttsSpeaker; // PCホストの話者（/config の tts_speakers）
  final String? localVoice; // 端末内 Supertonic 3 の話者（F1〜M5）
  final double ttsSpeed; // 端末内 TTS の話速
  final String talkLength; // "short" | "medium" | "long"
  final String
      personality; // "standard" | "energetic" | "chill" | "intellectual" | "comedian"
  final String username; // リスナーの名前（空文字 = 未設定）
  final String djName; // DJの名前（空文字 = 未設定）
  final String customPrompt; // カスタム指示（空文字 = なし）
  final int talkFrequency; // トーク頻度: N曲ごとに1回（1 = 毎曲）

  const DjPreferences({
    this.llmModel,
    this.ttsSpeaker,
    this.localVoice,
    this.ttsSpeed = 0.85,
    this.talkLength = 'medium',
    this.personality = 'standard',
    this.username = '',
    this.djName = '',
    this.customPrompt = '',
    this.talkFrequency = 1,
  });

  DjPreferences copyWith({
    String? llmModel,
    String? ttsSpeaker,
    String? localVoice,
    double? ttsSpeed,
    String? talkLength,
    String? personality,
    String? username,
    String? djName,
    String? customPrompt,
    int? talkFrequency,
  }) =>
      DjPreferences(
        llmModel: llmModel ?? this.llmModel,
        ttsSpeaker: ttsSpeaker ?? this.ttsSpeaker,
        localVoice: localVoice ?? this.localVoice,
        ttsSpeed: ttsSpeed ?? this.ttsSpeed,
        talkLength: talkLength ?? this.talkLength,
        personality: personality ?? this.personality,
        username: username ?? this.username,
        djName: djName ?? this.djName,
        customPrompt: customPrompt ?? this.customPrompt,
        talkFrequency: talkFrequency ?? this.talkFrequency,
      );

  /// ホスト / 端末内エンジンに渡すプロンプト用の設定。
  /// 端末内 TTS 専用の値（localVoice, ttsSpeed）は含めない。
  Map<String, dynamic> toJson() => {
        if (llmModel != null) 'llm_model': llmModel,
        if (ttsSpeaker != null) 'tts_speaker': ttsSpeaker,
        'talk_length': talkLength,
        'personality': personality,
        if (username.isNotEmpty) 'username': username,
        if (djName.isNotEmpty) 'dj_name': djName,
        if (customPrompt.isNotEmpty) 'custom_prompt': customPrompt,
      };
}
