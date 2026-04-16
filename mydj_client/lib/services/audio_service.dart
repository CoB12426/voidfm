import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// DJ トーク音声の再生と音楽プレイヤーの一時停止/再開を担うサービス。
///
/// Void Talk フロー:
///   1. pauseMusic()  — 音楽プレイヤーを一時停止
///   2. playTalk()    — DJ トーク音声を再生（完了まで待機）
///   3. resumeMusic() — 音楽プレイヤーを再開
class AudioService {
  static const _mediaChannel = MethodChannel('com.example.voidfm/media_session');

  // シングルトンで管理
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  final AudioPlayer _player = AudioPlayer();

  /// プリロード済みアセットのパス。null = 未プリロード。
  String? _loadedAssetPath;

  /// preloadIntro が実行中かどうか（playAsset との競合防止）
  bool _isPreloading = false;

  bool get isPlaying => _player.playing;

  /// イントロ音声をあらかじめ AudioPlayer にロードしておく。
  ///
  /// preloadIntro() を呼んだ後に同じパスで playAsset() を呼ぶと、
  /// setAudioSource をスキップして seek + play だけで開始できる。
  /// すでに再生中・ロード中の場合はスキップする。
  Future<void> preloadIntro(String assetPath) async {
    if (_player.playing || _isPreloading) return;
    _isPreloading = true;
    try {
      await _player.setAudioSource(AudioSource.asset(assetPath));
      _loadedAssetPath = assetPath;
      debugPrint('AudioService: intro preloaded: $assetPath');
    } catch (e) {
      _loadedAssetPath = null;
      debugPrint('AudioService: intro preload error ($assetPath): $e');
    } finally {
      _isPreloading = false;
    }
  }

  /// アプリ内 assets に格納した音声ファイルを再生する（完了まで await）。
  ///
  /// preloadIntro() で同じパスがロード済みの場合は setAudioSource をスキップし、
  /// seek + play だけで開始することで遅延を最小化する。
  Future<bool> playAsset(String assetPath) async {
    try {
      // プリロード済みの場合はアセットの再ロードをスキップ（高速パス）
      final alreadyLoaded = !_isPreloading &&
          _loadedAssetPath == assetPath &&
          _player.processingState != ProcessingState.idle;

      if (alreadyLoaded) {
        // pause で ready 状態を保ちつつ先頭にシーク
        if (_player.playing) await _player.pause();
        await _player.seek(Duration.zero);
        debugPrint('AudioService: intro fast-path (skip setAudioSource)');
      } else {
        if (_player.playing) await _player.stop();
        await _player.setAudioSource(AudioSource.asset(assetPath));
        _loadedAssetPath = assetPath;
      }

      await _player.play();
      // completed のみを正常終了扱いにする（idle は中断の可能性がある）
      await _player.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      ).timeout(const Duration(seconds: 30), onTimeout: () {
        _player.stop();
        return _player.playerState;
      });
      return true;
    } catch (e) {
      debugPrint('AudioService: playAsset error ($assetPath): $e');
      return false;
    }
  }

  /// DJ トーク音声（MP3 / WAV）を再生する。完了まで await する。
  /// 音楽は事前に pauseMusic() で停止済みであること。
  Future<void> playTalk(Uint8List wavBytes, {String contentType = 'audio/mpeg'}) async {
    debugPrint('AudioService: playTalk start (${wavBytes.length} bytes, $contentType)');
    if (_player.playing) {
      debugPrint('AudioService: playTalk — stopping current playback');
      await _player.stop();
    }
    _loadedAssetPath = null; // アセットプリロードをクリア
    try {
      final source = _BytesAudioSource(wavBytes, contentType: contentType);
      debugPrint('AudioService: playTalk — setAudioSource()');
      await _player.setAudioSource(source);
      debugPrint('AudioService: playTalk — setAudioSource done, duration=${_player.duration}');
      
      debugPrint('AudioService: playTalk — calling play()');
      await _player.play();
      debugPrint('AudioService: playTalk — play() returned');

      // 再生完了は completed のみで判定する。
      // idle は setAudioSource/stop 直後にも出るため、完了扱いにしない。
      final estimatedSec = (_player.duration?.inSeconds ?? 30) + 20;
      final waitTimeout = Duration(seconds: estimatedSec);
      debugPrint('AudioService: playTalk — waiting completed (timeout=$waitTimeout)');
      await _player.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      ).timeout(waitTimeout, onTimeout: () {
        debugPrint('AudioService: playTalk timeout ($waitTimeout), stopping player');
        _player.stop();
        return _player.playerState;
      });

      debugPrint('AudioService: playTalk done');
    } catch (e) {
      debugPrint('AudioService: playTalk error: $e');
    }
  }

  /// 音楽プレイヤーを一時停止する。
  Future<void> pauseMusic() async {
    try {
      await _mediaChannel.invokeMethod<void>('pause');
      // pause 完了を確実にするため短い待機時間を設定
      await Future.delayed(const Duration(milliseconds: 50));
    } catch (e) {
      debugPrint('AudioService: pauseMusic failed (continuing): $e');
    }
  }

  /// 音楽プレイヤーの音量を減らす（イントロ再生時用）。
  /// volume: 0.0 ～ 1.0（0.3 = 30%など）
  Future<void> setMusicVolume(double volume) async {
    try {
      await _mediaChannel.invokeMethod<void>('setVolume', {'volume': volume});
    } catch (e) {
      debugPrint('AudioService: setMusicVolume failed (continuing): $e');
    }
  }

  /// 音楽プレイヤーの音量を最大に戻す。
  Future<void> resetMusicVolume() async {
    try {
      await _mediaChannel.invokeMethod<void>('setVolume', {'volume': 1.0});
    } catch (e) {
      debugPrint('AudioService: resetMusicVolume failed (continuing): $e');
    }
  }

  /// 音楽プレイヤーを再開する。
  Future<void> resumeMusic() async {
    try {
      // TTS再生終了後のAudioFocus競合を回避するため、小休止を挟む
      await Future.delayed(const Duration(milliseconds: 100));
      debugPrint('AudioService: resumeMusic — calling play()');
      await _mediaChannel.invokeMethod<void>('play');
      debugPrint('AudioService: resumeMusic — play() completed');
    } catch (e) {
      debugPrint('AudioService: resumeMusic failed: $e');
    }
  }

  /// 再生中のトーク音声を停止する。
  Future<void> stop() async {
    if (_player.playing) await _player.stop();
    _loadedAssetPath = null;
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}

/// just_audio 用のインメモリ AudioSource。
class _BytesAudioSource extends StreamAudioSource {
  final Uint8List _bytes;
  final String _contentType;

  _BytesAudioSource(this._bytes, {String contentType = 'audio/mpeg'})
      : _contentType = contentType,
        super(tag: 'dj-talk');

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0;
    final e = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_bytes.sublist(s, e)),
      contentType: _contentType,
    );
  }
}
