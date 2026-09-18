import 'package:flutter/services.dart';
import '../models/track_info.dart';
import '../models/dj_preferences.dart';
import 'dj_backend.dart';
import 'dj_script_policy.dart';
import 'supertonic_service.dart';

/// 端末内で完結するバックエンド。台本は LiteRT-LM（Gemma 4 E2B）、
/// 音声は Supertonic 3 で生成し、HTTP 通信は行わない。
class LocalDjClient extends DjBackend {
  static const MethodChannel _channel =
      MethodChannel('com.example.voidfm/local_dj');

  static Future<Map<Object?, Object?>> status() async =>
      (await _channel.invokeMapMethod<Object?, Object?>('status')) ?? {};

  /// Gemma と Supertonic の両モデルが端末に揃っているか。
  static Future<bool> hasModels() async {
    try {
      final state = await status();
      return state['hasModel'] == true && state['hasTtsModel'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Gemma エンジンと Supertonic isolate を解放してメモリを空ける。
  /// 生成中の場合は完了を待ってから解放される。
  static Future<void> unload() async {
    SupertonicService.instance.reset();
    await _channel.invokeMethod<void>('unload');
  }

  /// Gemma / Supertonic がメモリに載っているか。
  static Future<({bool llm, bool tts})> loadedState() async {
    final state = await status();
    return (
      llm: state['modelLoaded'] == true,
      tts: SupertonicService.instance.isLoaded,
    );
  }

  static Future<bool> pickModel() async =>
      await _channel.invokeMethod<bool>('pickModel') ?? false;

  static Future<bool> pickTtsModel() async {
    SupertonicService.instance.reset();
    return await _channel.invokeMethod<bool>('pickTtsModel') ?? false;
  }

  @override
  Future<bool> ping() async {
    try {
      await initialize();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> initialize() async {
    final state = await status();
    if (state['hasModel'] != true) {
      throw StateError('Gemma 4 E2B LiteRT-LM model is missing');
    }
    if (state['hasTtsModel'] != true) {
      throw StateError('Supertonic 3 model is missing');
    }
    if (await _channel.invokeMethod<bool>('initialize') != true) {
      throw StateError('Gemma 4 E2B model could not be initialized');
    }
    await SupertonicService.instance
        .initialize(state['ttsModelPath'] as String);
  }

  @override
  Future<TalkFetchResult> fetchTalk({
    required TrackInfo nextTrack,
    TrackInfo? previousTrack,
    required DjPreferences preferences,
    List<TrackInfo> trackHistory = const [],
  }) async {
    final data = await _channel.invokeMapMethod<String, dynamic>('generate', {
      'next': nextTrack.toJson(),
      if (previousTrack != null) 'previous': previousTrack.toJson(),
      'preferences': preferences.toJson(),
      if (trackHistory.isNotEmpty)
        'history': trackHistory.map((t) => t.toJson()).toList(),
    });
    final script = DjScriptPolicy.select(
      raw: data?['script'] as String? ?? '',
      nextTrack: nextTrack,
      preferences: preferences,
    );
    return TalkFetchResult(
      audio: await _synthesize(script, preferences),
      script: script,
    );
  }

  @override
  Future<Uint8List> fetchStationId({required DjPreferences preferences}) async {
    final data = await _channel.invokeMapMethod<String, dynamic>('stationId');
    final script = data?['script'] as String?;
    if (script == null || script.isEmpty) {
      throw StateError('No station ID script');
    }
    return _synthesize(script, preferences);
  }

  /// 設定画面の試聴用。
  static Future<Uint8List> previewVoice({
    required String speaker,
    required double speed,
  }) =>
      LocalDjClient()._synthesize(
        "You're listening to VoidFM. More music is coming up next.",
        DjPreferences(localVoice: speaker, ttsSpeed: speed),
      );

  Future<Uint8List> _synthesize(
      String script, DjPreferences preferences) async {
    final state = await status();
    if (state['hasTtsModel'] != true) {
      throw StateError('Supertonic 3 model is missing');
    }
    return SupertonicService.instance.synthesize(
      state['ttsModelPath'] as String,
      script,
      speaker: preferences.localVoice,
      speed: preferences.ttsSpeed,
    );
  }

  @override
  Future<void> cancel() => _channel.invokeMethod<void>('cancel');
}
