import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../models/track_info.dart';

/// Android の NotificationListenerService / MediaController から
/// Flutter へ届くイベントを受け取るサービス。
///
/// ─ ストリーム ─
///   trackStream     : 現在トラック変更イベント (com.example.voidfm/notification)
///   nextTrackStream : キューから取得した次トラック更新イベント (com.example.voidfm/next_track)
///                     MediaController.Callback が onMetadataChanged /
///                     onPlaybackStateChanged / onQueueChanged を検知するたびに流れる。
class NotificationService {
  static const _trackChannel     = EventChannel('com.example.voidfm/notification');
  static const _nextTrackChannel = EventChannel('com.example.voidfm/next_track');
  static const _trackEndingChannel = EventChannel('com.example.voidfm/track_ending');
  static const _methodChannel    = MethodChannel('com.example.voidfm/media_session');

  Stream<TrackInfo>? _trackStream;
  Stream<Map<String, dynamic>>? _rawNextTrackStream;
  Stream<TrackInfo>? _nextTrackStream;
  Stream<Map<String, dynamic>>? _trackEndingStream;

  /// 現在再生中トラックが変わるたびに発火するストリーム。
  Stream<TrackInfo> get trackStream {
    _trackStream ??= _trackChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => _parseMap(Map<String, dynamic>.from(e as Map)));
    return _trackStream!;
  }

  /// MediaSession キューから取得した「次の曲」更新イベントの生 Map ストリーム。
  ///
  /// Map に含まれるキー:
  ///   title / artist / album           : 次の曲（song_next）
  ///   next_title / next_artist / next_album : 次の次の曲（存在する場合のみ）
  ///
  /// キューを公開していないアプリでは何も流れない。
  Stream<Map<String, dynamic>> get nextTrackRawStream {
    _rawNextTrackStream ??= _nextTrackChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .asBroadcastStream();
    return _rawNextTrackStream!;
  }

  /// MediaSession キューから取得した「次の曲」が更新されるたびに発火するストリーム。
  /// ── キューを公開していないアプリでは何も流れない ──
  Stream<TrackInfo> get nextTrackStream {
    _nextTrackStream ??= nextTrackRawStream.map(_parseMap);
    return _nextTrackStream!;
  }

  /// 現在の曲が終わる直前（約50ms前）に届くイベント。
  ///
  /// 主なキー:
  ///   remaining_ms: 残り時間（ms, 0以上）
  Stream<Map<String, dynamic>> get trackEndingStream {
    _trackEndingStream ??= _trackEndingChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .asBroadcastStream();
    return _trackEndingStream!;
  }

  Future<void> skipToNext()     async => _methodChannel.invokeMethod<void>('skipToNext');
  Future<void> skipToPrevious() async => _methodChannel.invokeMethod<void>('skipToPrevious');

  /// Android 側の djActive フラグをセットする。
  /// true にすると次のトラック変更時に即座に一時停止が走る。
  Future<void> setDjActive(bool active) async {
    try {
      await _methodChannel.invokeMethod<void>('setDjActive', {'active': active});
    } catch (_) {}
  }

  /// DJ トーク再生中のみ、外部プレイヤーの自動再開を抑止する。
  Future<void> setDjHoldPlayback(bool hold) async {
    try {
      await _methodChannel.invokeMethod<void>('setDjHoldPlayback', {'hold': hold});
    } catch (_) {}
  }

  /// 起動時に現在再生中のトラックを取得する
  Future<TrackInfo?> getCurrentTrack() async {
    try {
      final result = await _methodChannel.invokeMethod<Map>('getCurrentTrack');
      if (result == null) return null;
      return _parseMap(Map<String, dynamic>.from(result));
    } catch (_) {
      return null;
    }
  }

  /// 音楽が再生中かどうかを取得する
  Future<bool> isAudioPlaying() async {
    try {
      final result = await _methodChannel.invokeMethod<bool>('isAudioPlaying');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  TrackInfo _parseMap(Map<String, dynamic> map) {
    final artRaw = map['albumArt'];
    Uint8List? albumArt;
    if (artRaw is Uint8List) {
      albumArt = artRaw;
    } else if (artRaw is List) {
      albumArt = Uint8List.fromList(artRaw.cast<int>());
    }
    return TrackInfo(
      title:    map['title']  as String? ?? '',
      artist:   map['artist'] as String? ?? '',
      album:    map['album']  as String?,
      albumArt: albumArt,
    );
  }
}
