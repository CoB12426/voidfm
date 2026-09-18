import 'dart:typed_data';
import '../models/dj_preferences.dart';
import '../models/track_info.dart';
import 'local_client.dart';
import 'remote_client.dart';

/// DJ トークの生成先。
enum DjBackendMode {
  /// PC 上の VoidFM ホスト（LLM + Chatterbox TTS）へ HTTP で接続する。
  remote,

  /// 端末内の Gemma 4 E2B（LiteRT-LM）と Supertonic 3 で生成する。
  local;

  static DjBackendMode parse(String? value) =>
      value == local.name ? local : remote;
}

class TalkFetchResult {
  final Uint8List audio;
  final String? script;
  const TalkFetchResult({required this.audio, this.script});
}

/// トーク音声を生成するバックエンドの共通インターフェース。
///
/// 1 インスタンス = 1 リクエスト系列。[cancel] で進行中の生成を中断し、
/// 使い終わったら [close] でリソースを解放する。
abstract class DjBackend {
  /// 生成できる状態か（リモートは疎通、ローカルはモデル読み込み）。
  Future<bool> ping();

  Future<TalkFetchResult> fetchTalk({
    required TrackInfo nextTrack,
    TrackInfo? previousTrack,
    required DjPreferences preferences,
    List<TrackInfo> trackHistory = const [],
  });

  Future<Uint8List> fetchStationId({required DjPreferences preferences});

  Future<void> cancel();

  void close() {}
}

/// 設定画面で選んだ接続先。DjProvider はこれを受け取って [DjBackend] を作る。
class BackendConfig {
  final DjBackendMode mode;
  final String hostAddress;
  final int port;

  const BackendConfig({
    required this.mode,
    this.hostAddress = '',
    this.port = 8000,
  });

  bool get isRemote => mode == DjBackendMode.remote;

  /// 生成されるトーク音声の Content-Type。
  String get audioContentType => isRemote ? 'audio/mpeg' : 'audio/wav';

  DjBackend create() => isRemote
      ? RemoteHostClient(hostAddress: hostAddress, port: port)
      : LocalDjClient();
}
