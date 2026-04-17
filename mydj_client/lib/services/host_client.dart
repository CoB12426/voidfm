import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/track_info.dart';
import '../models/host_config.dart';
import '../models/dj_preferences.dart';

class HostClient {
  final String hostAddress;
  final int port;

  /// キャンセル可能なリクエストを発行するには外部から Client を渡す。
  /// null の場合は使い捨て Client を生成する。
  final http.Client? _client;

  HostClient({
    required this.hostAddress,
    required this.port,
    http.Client? client,
  }) : _client = client;

  Uri _uri(String path) => Uri.parse('http://$hostAddress:$port$path');

  /// GET /ping — 疎通確認。成功なら true。
  Future<bool> ping() async {
    final client = http.Client();
    try {
      final response = await client
          .get(_uri('/ping'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } finally {
      client.close();
    }
  }

  /// GET /config — サーバー設定を取得。
  Future<HostConfig> fetchConfig() async {
    final client = http.Client();
    try {
      final response = await client
          .get(_uri('/config'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('fetchConfig failed: ${response.statusCode}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return HostConfig.fromJson(json);
    } finally {
      client.close();
    }
  }

  /// POST /talk — DJ トーク音声を取得。
  ///
  /// [_client] が設定されている場合はそのクライアントを使用する。
  /// 呼び出し元が [_client].close() を呼ぶことでリクエストをキャンセルできる。
  Future<Uint8List> fetchTalk({
    required TrackInfo currentTrack,
    TrackInfo? previousTrack,
    required DjPreferences preferences,
  }) async {
    final client = _client ?? http.Client();
    final owned = _client == null; // 自前で生成した場合のみ finally でclose
    try {
      final body = jsonEncode({
        'current_track':                   currentTrack.toJson(),
        if (previousTrack != null) 'previous_track': previousTrack.toJson(),
        'preferences':             preferences.toJson(),
      });

      final response = await client
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
    } finally {
      if (owned) client.close();
    }
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
