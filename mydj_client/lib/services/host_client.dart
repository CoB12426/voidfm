import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/track_info.dart';
import '../models/host_config.dart';
import '../models/dj_preferences.dart';

class TalkJobStatus {
  final String jobId;
  final String status;
  final String? error;
  final double? llmTime;
  final double? ttsTime;
  final double? totalTime;
  final int? audioBytes;
  final bool cached;

  const TalkJobStatus({
    required this.jobId,
    required this.status,
    this.error,
    this.llmTime,
    this.ttsTime,
    this.totalTime,
    this.audioBytes,
    this.cached = false,
  });

  factory TalkJobStatus.fromJson(Map<String, dynamic> json) => TalkJobStatus(
        jobId: json['job_id'] as String,
        status: json['status'] as String,
        error: json['error'] as String?,
        llmTime: (json['llm_time'] as num?)?.toDouble(),
        ttsTime: (json['tts_time'] as num?)?.toDouble(),
        totalTime: (json['total_time'] as num?)?.toDouble(),
        audioBytes: json['audio_bytes'] as int?,
        cached: json['cached'] as bool? ?? false,
      );
}

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

  String? _activeTalkJobId;
  bool _cancelRequested = false;

  Uri _uri(String path) => Uri.parse('http://$hostAddress:$port$path');

  bool _isValidTrack(TrackInfo t) {
    return t.title.trim().isNotEmpty && t.artist.trim().isNotEmpty;
  }

  /// GET /ping — 疎通確認。成功なら true。
  Future<bool> ping() async {
    final client = http.Client();
    try {
      final response =
          await client.get(_uri('/ping')).timeout(const Duration(seconds: 5));
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
    required TrackInfo nextTrack,
    TrackInfo? previousTrack,
    required DjPreferences preferences,
    List<TrackInfo> trackHistory = const [],
  }) async {
    if (!_isValidTrack(nextTrack)) {
      throw Exception(
          'fetchTalk aborted: invalid nextTrack (empty title/artist)');
    }

    final safePreviousTrack =
        (previousTrack != null && _isValidTrack(previousTrack))
            ? previousTrack
            : null;
    final safeTrackHistory = trackHistory.where(_isValidTrack).toList();

    final body = jsonEncode({
      'next_track': nextTrack.toJson(),
      if (safePreviousTrack != null)
        'previous_track': safePreviousTrack.toJson(),
      'preferences': preferences.toJson(),
      if (safeTrackHistory.isNotEmpty)
        'track_history': safeTrackHistory.map((t) => t.toJson()).toList(),
    });

    return _fetchTalkJob(body);
  }

  Future<Uint8List> _fetchTalkJob(String body) async {
    final client = _client ?? http.Client();
    final owned = _client == null;
    _cancelRequested = false;
    String? jobId;

    try {
      final createResponse = await client
          .post(
            _uri('/talk_jobs'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      if (createResponse.statusCode == 404 ||
          createResponse.statusCode == 405) {
        return _fetchTalkLegacy(client, body);
      }
      if (createResponse.statusCode != 200) {
        final detail = _extractDetail(createResponse.body);
        throw Exception(
            'createTalkJob failed (${createResponse.statusCode}): $detail');
      }

      final createJson =
          jsonDecode(createResponse.body) as Map<String, dynamic>;
      jobId = createJson['job_id'] as String;
      _activeTalkJobId = jobId;

      while (true) {
        if (_cancelRequested) {
          throw Exception('fetchTalk cancelled');
        }

        final status = await _fetchTalkJobStatus(client, jobId);
        if (status.status == 'succeeded') {
          final audio = await client
              .get(_uri('/talk_jobs/$jobId/audio'))
              .timeout(const Duration(minutes: 2));
          if (audio.statusCode != 200) {
            final detail = _extractDetail(audio.body);
            throw Exception(
                'fetchTalk audio failed (${audio.statusCode}): $detail');
          }
          if (status.totalTime != null) {
            print(
              'DjProvider(HostClient): job $jobId done ${status.totalTime!.toStringAsFixed(2)} s '
              '(LLM: ${status.llmTime?.toStringAsFixed(2)} s, '
              'TTS: ${status.ttsTime?.toStringAsFixed(2)} s, '
              'cached: ${status.cached})',
            );
          }
          return audio.bodyBytes;
        }

        if (status.status == 'failed' || status.status == 'cancelled') {
          throw Exception(
              'fetchTalk job ${status.status}: ${status.error ?? jobId}');
        }

        await Future.delayed(const Duration(milliseconds: 750));
      }
    } finally {
      if (_activeTalkJobId == jobId) _activeTalkJobId = null;
      if (owned) client.close();
    }
  }

  Future<TalkJobStatus> _fetchTalkJobStatus(
      http.Client client, String jobId) async {
    final response = await client
        .get(_uri('/talk_jobs/$jobId'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      final detail = _extractDetail(response.body);
      throw Exception(
          'fetchTalk status failed (${response.statusCode}): $detail');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return TalkJobStatus.fromJson(json);
  }

  Future<Uint8List> _fetchTalkLegacy(http.Client client, String body) async {
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

    final llmTime = response.headers['x-voidfm-llm-time'];
    final ttsTime = response.headers['x-voidfm-tts-time'];
    final totalTime = response.headers['x-voidfm-total-time'];
    if (totalTime != null) {
      print(
          'DjProvider(HostClient): Generation took $totalTime s (LLM: $llmTime s, TTS: $ttsTime s)');
    }

    return response.bodyBytes;
  }

  Future<void> cancelActiveTalkJob() async {
    _cancelRequested = true;
    final jobId = _activeTalkJobId;
    if (jobId == null) return;

    final client = http.Client();
    try {
      await client
          .delete(_uri('/talk_jobs/$jobId'))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Best-effort: the local HTTP client may already be closed during cancellation.
    } finally {
      client.close();
    }
  }

  /// GET /station_id — ステーションIDの音声を取得。
  Future<Uint8List> fetchStationId() async {
    final client = _client ?? http.Client();
    final owned = _client == null;
    try {
      final response = await client
          .get(_uri('/station_id'))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        final detail = _extractDetail(response.body);
        throw Exception(
            'fetchStationId failed (${response.statusCode}): $detail');
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
