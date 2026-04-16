import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/track_info.dart';
import '../models/host_config.dart';
import '../models/dj_preferences.dart';

class HostClient {
  final String hostAddress;
  final int port;

  HostClient({required this.hostAddress, required this.port});

  Uri _uri(String path) => Uri.parse('http://$hostAddress:$port$path');

  /// GET /ping — 疎通確認。成功なら true。
  Future<bool> ping() async {
    final response = await http
        .get(_uri('/ping'))
        .timeout(const Duration(seconds: 5));
    return response.statusCode == 200;
  }

  /// GET /config — サーバー設定を取得。
  Future<HostConfig> fetchConfig() async {
    final response = await http
        .get(_uri('/config'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('fetchConfig failed: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return HostConfig.fromJson(json);
  }

  /// POST /talk — DJ トーク音声 (WAV) を取得。
  ///
  /// [currentTrack]  : 次の曲（void talk 後に再生される曲 = song_next）
  /// [previousTrack] : 直前に終わった曲（= song_current）
  /// [nextTrack]     : 次の次の曲（song_next の後の曲。省略可）
  Future<Uint8List> fetchTalk({
    required TrackInfo currentTrack,
    TrackInfo? previousTrack,
    TrackInfo? nextTrack,
    required DjPreferences preferences,
  }) async {
    final body = jsonEncode({
      'current_track':                   currentTrack.toJson(),
      if (previousTrack != null) 'previous_track': previousTrack.toJson(),
      if (nextTrack != null)     'next_track':     nextTrack.toJson(),
      'preferences':             preferences.toJson(),
    });

    final response = await http
        .post(
          _uri('/talk'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(minutes: 10));

    if (response.statusCode != 200) {
      final detail = _extractDetail(response.body);
      throw Exception('fetchTalk failed (${response.statusCode}): $detail');
    }
    return response.bodyBytes;
  }

  String _extractDetail(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['detail']?.toString() ?? body;
    } catch (_) {
      return body;
    }
  }
}
