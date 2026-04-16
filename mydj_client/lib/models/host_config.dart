class HostConfig {
  final List<String> llmModels;
  final String defaultLlm;
  final List<String> ttsSpeakers;
  final String defaultSpeaker;
  final String serverVersion;

  const HostConfig({
    required this.llmModels,
    required this.defaultLlm,
    required this.ttsSpeakers,
    required this.defaultSpeaker,
    required this.serverVersion,
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) => HostConfig(
        llmModels: List<String>.from(json['llm_models'] as List),
        defaultLlm: json['default_llm'] as String,
        ttsSpeakers: List<String>.from(json['tts_speakers'] as List),
        defaultSpeaker: json['default_speaker'] as String,
        serverVersion: json['server_version'] as String,
      );
}
