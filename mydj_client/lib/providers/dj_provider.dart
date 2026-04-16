import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/track_info.dart';
import '../models/dj_preferences.dart';
import '../services/host_client.dart';
import '../services/audio_service.dart';
import '../services/notification_service.dart';

/// DJ トークのライフサイクルを管理するプロバイダー。
///
/// ─ フロー ─
///
///   ON AIR ON
///     ├─ 楽曲再生中 : 音量を下げてイントロ再生 → 音量戻す → resumeMusic
///     │               同時に TTS 生成開始
///     └─ 楽曲未再生 : イントロ再生 → _awaitingMusic=true
///
///   onTrackChanged (曲変わり)
///     ├─ _awaitingMusic=true → TTS 生成開始
///     ├─ ユーザースキップ   → TTS 破棄 + 新しい TTS 生成
///     └─ 楽曲終了(自然)
///           TTS 完了済み → void talk 再生 → resumeMusic → 次 TTS 生成
///           TTS 未完了   → TTS 破棄 → resumeMusic → 次 TTS 生成
///
class DjProvider extends ChangeNotifier {

  // ── 公開状態 ──────────────────────────────────────────────────────────
  TrackInfo? _currentTrack;
  TrackInfo? _nextTrack;
  TrackInfo? _nextNextTrack;
  bool _isOnAir      = false;
  bool _isPlayingTalk = false;
  bool? _hostConnected;
  String? _lastTalkError;

  TrackInfo? get currentTrack   => _currentTrack;
  TrackInfo? get nextTrack      => _nextTrack;
  bool get isServiceEnabled     => _isOnAir;   // home_screen との互換性
  bool get isOnAir              => _isOnAir;
  bool get isProcessing         => _isPlayingTalk; // home_screen との互換性
  bool get isPlayingTalk        => _isPlayingTalk;
  bool? get hostConnected       => _hostConnected;
  String? get lastTalkError     => _lastTalkError;

  // ── 内部状態 ──────────────────────────────────────────────────────────
  bool _awaitingMusic    = false;  // ON AIR 後、楽曲開始待ち
  bool _suppressNextTalk = false;  // 次回 void talk をスキップ
  bool _isHandlingTrackEndingSoon = false;
  DateTime? _trackStartTime;

  static const _skipThresholdSec = 30;
  static const _introPreloadTimeout = Duration(seconds: 4);
  static const _introPreRollBuffer = Duration(milliseconds: 180);
  // 曲切替直後のホスト負荷で TTS 生成が遅れることがあるため、
  // ある程度待ってからスキップ判定する。
  static const _ttsReadyTimeout = Duration(seconds: 12);

  // ── TTS 生成 ──────────────────────────────────────────────────────────
  Completer<Uint8List?>? _ttsCompleter;
  TrackInfo? _ttsForTrack;       // 生成対象の currentTrack
  TrackInfo? _ttsNextTrack;      // 生成開始時に使った nextTrack
  TrackInfo? _ttsNextNextTrack;  // 生成開始時に使った nextNextTrack

  // ── 設定 ─────────────────────────────────────────────────────────────
  String        _hostAddress = '';
  int           _port        = 8000;
  DjPreferences _preferences = const DjPreferences();

  // ── イントロアセット ──────────────────────────────────────────────────
  static const _introAssetsJa = [
    'assets/audio/intro_ja_1.wav',
    'assets/audio/intro_ja_2.wav',
    'assets/audio/intro_ja_3.wav',
  ];
  static const _introAssetsEn = [
    'assets/audio/intro_en_1.wav',
    'assets/audio/intro_en_2.wav',
    'assets/audio/intro_en_3.wav',
  ];
  final _rng = Random();

  String _pickIntroAsset() {
    final isJa = _preferences.language.startsWith('ja');
    final list  = isJa ? _introAssetsJa : _introAssetsEn;
    return list[_rng.nextInt(list.length)];
  }

  // ── サービス ──────────────────────────────────────────────────────────
  final AudioService        _audio = AudioService();
  final NotificationService _notif = NotificationService();
  StreamSubscription? _nextTrackSub;

  DjProvider() {
    _nextTrackSub = _notif.nextTrackRawStream.listen((raw) {
      final title  = raw['title']  as String?;
      final artist = raw['artist'] as String?;
      if (title == null || artist == null) return;
      final next = TrackInfo(
        title:  title,
        artist: artist,
        album:  raw['album'] as String?,
      );
      final nnTitle  = raw['next_title']  as String?;
      final nnArtist = raw['next_artist'] as String?;
      final nextNext = (nnTitle != null && nnArtist != null)
          ? TrackInfo(title: nnTitle, artist: nnArtist, album: raw['next_album'] as String?)
          : null;
      _onNextTrackUpdated(next, nextNext);
    });
  }

  // ── 公開 API ──────────────────────────────────────────────────────────

  /// ON AIR トグル。ON 時はイントロを再生し TTS 生成を開始する。
  Future<void> toggleService({
    required String hostAddress,
    required int port,
    required DjPreferences preferences,
  }) async {
    _hostAddress = hostAddress;
    _port        = port;
    _preferences = preferences;

    if (!_isOnAir) {
      _isOnAir = true;
      notifyListeners();
      await _notif.setDjActive(true);
      await _notif.setDjHoldPlayback(false);
      _pingHostSilently();
      await _playIntro();
    } else {
      // OFF: 再生中のトークがあれば中断して音楽を再開
      _isOnAir       = false;
      _awaitingMusic = false;
      _cancelTts();
      if (_isPlayingTalk) {
        await _audio.stop();
        _isPlayingTalk = false;
      }
      await _restoreMusicPlayback();
      await _notif.setDjActive(false);
      notifyListeners();
    }
  }

  /// 起動時の現在再生中トラックをセット（DJ トークは発火しない）。
  void setTrack(TrackInfo track) {
    _currentTrack   = track;
    _trackStartTime = DateTime.now();
    notifyListeners();
  }

  /// 次のトラック変更で void talk を 1 回スキップする（スワイプ操作用）。
  void suppressNextTalk() => _suppressNextTalk = true;

  /// Android 通知から新しい楽曲情報を受け取り、void talk フローを制御する。
  Future<void> onTrackChanged({
    required TrackInfo newTrack,
    required String    hostAddress,
    required int       port,
    required DjPreferences preferences,
  }) async {
    debugPrint('DjProvider: onTrackChanged — "${newTrack.artist}" / "${newTrack.title}"');
    _hostAddress = hostAddress;
    _port        = port;
    _preferences = preferences;

    // 同一曲でアルバムアートのみ更新の場合
    if (_currentTrack == newTrack) {
      if (_currentTrack?.albumArt == null && newTrack.albumArt != null) {
        _currentTrack = newTrack;
        notifyListeners();
      }
      return;
    }

    final prevTrack = _currentTrack;
    final now       = DateTime.now();
    final playedSec = _trackStartTime != null
        ? now.difference(_trackStartTime!).inSeconds
        : null;
    final isQuickSkip = playedSec != null && playedSec < _skipThresholdSec;

    debugPrint('DjProvider: onTrackChanged — prevTrack="${prevTrack?.title}" '
        'playedSec=$playedSec isQuickSkip=$isQuickSkip isOnAir=$_isOnAir');

    _currentTrack   = newTrack;
    _trackStartTime = now;
    _nextTrack      = null;
    _nextNextTrack  = null;
    notifyListeners();

    if (!_isOnAir) {
      debugPrint('DjProvider: onTrackChanged — NOT on air, returning');
      return;
    }

    // ── 楽曲開始待機中の最初の曲 ─────────────────────────────────────
    if (_awaitingMusic) {
      _awaitingMusic = false;
      debugPrint('DjProvider: first track arrived, starting TTS generation');
      _startTtsGeneration();
      return;
    }

    // ── ユーザースキップ判定 ──────────────────────────────────────────
    final isUserSkip = _suppressNextTalk || isQuickSkip;
    _suppressNextTalk = false;

    if (isUserSkip) {
      debugPrint('DjProvider: user skip — cancel TTS, start new generation');
      _cancelTts();
      if (_isPlayingTalk) {
        // void talk 再生中にスキップ → 中断して音楽へ
        // finallyブロックが resumeMusic / holdPlayback解除を担う
        await _audio.stop();
        // _isPlayingTalk は _playVoidTalk の finally でリセットされる
        return;
      }
      // void talk 未再生: Android の自動ポーズを解除
      await _restoreMusicPlayback();
      _startTtsGeneration();
      return;
    }

    if (_isPlayingTalk) {
      // void talk 再生中に届く重複通知は無視する。
      // ここで音楽を再開するとトークが途中で切れる。
      debugPrint('DjProvider: track update ignored while void talk is playing');
      return;
    }

    // ── 楽曲終了（自然） ──────────────────────────────────────────────
    debugPrint('DjProvider: checking void talk conditions —'
        ' prevTrack=$prevTrack,'
        ' _ttsCompleter=$_ttsCompleter,'
        ' _ttsForTrack=$_ttsForTrack,'
        ' prevTrack==_ttsForTrack=${prevTrack == _ttsForTrack},'
        ' isCompleted=${_ttsCompleter?.isCompleted}');
    
    if (prevTrack != null &&
        _ttsCompleter != null &&
        _ttsForTrack == prevTrack) {
      if (_ttsCompleter!.isCompleted) {
        // TTS 準備完了 → void talk 再生
        debugPrint('DjProvider: TTS ready — calling _playVoidTalk()');
        await _playVoidTalk();
      } else {
        // 曲終わり直後は TTS が数秒遅れることがあるため、少し長めに待つ。
        final currentCompleter = _ttsCompleter;
        debugPrint('DjProvider: TTS not yet ready — waiting up to $_ttsReadyTimeout');
        final becameReady = await _waitForTtsReady(currentCompleter!);

        if (_ttsCompleter == currentCompleter && becameReady) {
          debugPrint('DjProvider: TTS became ready — calling _playVoidTalk()');
          await _playVoidTalk();
        } else {
          debugPrint('DjProvider: TTS still not ready — resuming normally');
          _cancelTts();
          await _restoreMusicPlayback();
        }
      }
    } else {
      // TTS 未生成 or 対象が違う → 通常通り次の曲を再生
      final reason = prevTrack == null ? 'prevTrack null' :
                     _ttsCompleter == null ? '_ttsCompleter null' :
                     _ttsForTrack != prevTrack ? '_ttsForTrack != prevTrack' :
                     'unknown';
      debugPrint('DjProvider: TTS not applicable ($reason) — resuming normally');
      _cancelTts();
      await _restoreMusicPlayback();
    }

    // 次の曲変わりに向けて TTS 生成を開始
    _startTtsGeneration();
  }

  /// 現在曲の終端直前（約50ms前）イベント。
  ///
  /// 期待シーケンス:
  /// pause(終端前) → TTS再生 → skipToNext → 再生再開
  Future<void> onTrackEndingSoon({
    required String hostAddress,
    required int port,
    required DjPreferences preferences,
  }) async {
    _hostAddress = hostAddress;
    _port        = port;
    _preferences = preferences;

    if (!_isOnAir || _currentTrack == null || _isPlayingTalk || _isHandlingTrackEndingSoon) {
      return;
    }

    _isHandlingTrackEndingSoon = true;
    try {
      // まだ当該曲向けのTTSが無ければ生成開始
      if (_ttsCompleter == null || _ttsForTrack != _currentTrack) {
        _startTtsGeneration();
      }

      final completer = _ttsCompleter;
      if (completer == null) {
        await _restoreMusicPlayback();
        return;
      }

      if (!completer.isCompleted) {
        final becameReady = await _waitForTtsReady(completer);
        if (!becameReady || _ttsCompleter != completer) {
          _cancelTts();
          await _restoreMusicPlayback();
          return;
        }
      }

      // この切り替えでは onTrackChanged 側のトーク実行を抑止
      _suppressNextTalk = true;
      await _playVoidTalk(skipToNextAfterTalk: true);
      _startTtsGeneration();
    } finally {
      _isHandlingTrackEndingSoon = false;
    }
  }

  // ── 内部実装 ──────────────────────────────────────────────────────────

  /// ON AIR 時のイントロ再生シーケンス。
  Future<void> _playIntro() async {
    final asset   = _pickIntroAsset();
    final preload = _audio.preloadIntro(asset); // バックグラウンドでロード開始

    if (_currentTrack != null) {
      // 楽曲再生中: 音量を下げてイントロ、同時に TTS 生成開始
      _startTtsGeneration();
      try { await preload.timeout(_introPreloadTimeout); } catch (_) {}
      // 一部端末で先頭が欠けるため、短いプリロールを入れてから再生する。
      await Future.delayed(_introPreRollBuffer);
      await _audio.setMusicVolume(0.3);
      await _audio.playAsset(asset);
      await _audio.resetMusicVolume();
      await _audio.resumeMusic(); // just_audio の AudioFocus 奪取後に明示的に再開
    } else {
      // 楽曲未再生: イントロだけ再生して楽曲開始を待機
      try { await preload.timeout(_introPreloadTimeout); } catch (_) {}
      await Future.delayed(_introPreRollBuffer);
      await _audio.playAsset(asset);
      _awaitingMusic = true;
      debugPrint('DjProvider: intro done, awaiting music start');
    }
  }

  /// バックグラウンドで TTS 生成を開始する。
  /// 既存の生成はキャンセルして新しい生成を優先する。
  void _startTtsGeneration() {
    _cancelTts();
    if (_currentTrack == null || _hostAddress.isEmpty) return;

    final forTrack  = _currentTrack!;
    final songNext  = _nextTrack;
    final songAfter = _nextNextTrack;

    _ttsForTrack      = forTrack;
    _ttsNextTrack     = songNext;
    _ttsNextNextTrack = songAfter;
    final completer = Completer<Uint8List?>();
    _ttsCompleter = completer;

    debugPrint('DjProvider: TTS start — prev="${forTrack.title}" '
        'next="${songNext?.title ?? "?"}"');

    _generateTts(
      previousTrack: forTrack,
      currentTrack:  songNext,
      nextTrack:     songAfter,
    ).then((bytes) {
      debugPrint('DjProvider: TTS generation completed (${bytes?.length ?? 0} bytes)');
      if (!completer.isCompleted) {
        completer.complete(bytes);
        debugPrint('DjProvider: TTS Completer completed');
      } else {
        debugPrint('DjProvider: TTS Completer already completed (discarding result)');
      }
    }).catchError((e) {
      debugPrint('DjProvider: TTS generation error: $e');
      if (!completer.isCompleted) {
        completer.complete(null);
        debugPrint('DjProvider: TTS Completer completed with null');
      }
    });
  }

  void _cancelTts() {
    _ttsCompleter     = null;
    _ttsForTrack      = null;
    _ttsNextTrack     = null;
    _ttsNextNextTrack = null;
  }

  Future<bool> _waitForTtsReady(Completer<Uint8List?> completer) async {
    try {
      await completer.future.timeout(_ttsReadyTimeout);
      return true;
    } catch (_) {
      debugPrint('DjProvider: _waitForTtsReady timeout ($_ttsReadyTimeout), '
          'isCompleted=${completer.isCompleted}');
      return completer.isCompleted;
    }
  }

  Future<void> _restoreMusicPlayback() async {
    await _audio.resumeMusic();
    await _notif.setDjHoldPlayback(false);
  }

  /// TTS 音声を再生する（音楽を一時停止 → void talk → resumeMusic）。
  Future<void> _playVoidTalk({bool skipToNextAfterTalk = false}) async {
    debugPrint('DjProvider: _playVoidTalk start');
    final wavBytes = await _ttsCompleter!.future;
    _cancelTts();

    if (wavBytes == null || wavBytes.isEmpty) {
      debugPrint('DjProvider: _playVoidTalk — TTS bytes empty, skipping');
      await _restoreMusicPlayback();
      return;
    }

    debugPrint('DjProvider: _playVoidTalk — ${wavBytes.length} bytes, starting playback');
    _isPlayingTalk = true;
    _lastTalkError = null;
    notifyListeners();

    try {
      debugPrint('DjProvider: _playVoidTalk — holdPlayback(true)');
      await _notif.setDjHoldPlayback(true);
      
      debugPrint('DjProvider: _playVoidTalk — pauseMusic()');
      await _audio.pauseMusic();
      await Future.delayed(const Duration(milliseconds: 150));
      
      debugPrint('DjProvider: _playVoidTalk — playTalk()');
      await _audio.playTalk(wavBytes);
      debugPrint('DjProvider: _playVoidTalk — playTalk done');
    } catch (e) {
      debugPrint('DjProvider: _playVoidTalk error: $e');
      _lastTalkError = e.toString();
    } finally {
      debugPrint('DjProvider: _playVoidTalk — finally block: resumeMusic()');
      await Future.delayed(const Duration(milliseconds: 150));

      if (skipToNextAfterTalk) {
        debugPrint('DjProvider: _playVoidTalk — skipToNext() before resume');
        await _notif.skipToNext();
      }

      await _restoreMusicPlayback();
      
      _isPlayingTalk = false;
      notifyListeners();
      debugPrint('DjProvider: _playVoidTalk done');
    }
  }

  /// ホストへリクエストを送り WAV バイト列を返す（null = 失敗）。
  Future<Uint8List?> _generateTts({
    required TrackInfo previousTrack,
    TrackInfo?         currentTrack,
    TrackInfo?         nextTrack,
  }) async {
    try {
      final wav = await HostClient(
        hostAddress: _hostAddress,
        port:        _port,
      ).fetchTalk(
        previousTrack: previousTrack,
        currentTrack:  currentTrack ?? previousTrack,
        nextTrack:     nextTrack,
        preferences:   _preferences,
      );
      debugPrint('DjProvider: TTS done (${wav.length} bytes)');
      return wav;
    } catch (e) {
      debugPrint('DjProvider: TTS failed: $e');
      return null;
    }
  }

  /// nextTrack 情報が更新された。nextTrack が実際に変化した場合のみ TTS を再生成する。
  void _onNextTrackUpdated(TrackInfo track, TrackInfo? nextNext) {
    debugPrint('DjProvider: _onNextTrackUpdated — next="${track.title}" nextNext="${nextNext?.title}"');
    _nextTrack     = track;
    _nextNextTrack = nextNext;

    if (!_isOnAir || _currentTrack == null || _isPlayingTalk) {
      debugPrint('DjProvider: _onNextTrackUpdated — early return (isOnAir=$_isOnAir, '
          'currentTrack=$_currentTrack, isPlayingTalk=$_isPlayingTalk)');
      return;
    }

    if (_ttsCompleter == null) {
      // まだ生成を開始していない: 開始
      debugPrint('DjProvider: nextTrack arrived, starting TTS — next="$track"');
      _startTtsGeneration();
      return;
    }

    // 生成中 or 完了済みの場合: nextTrack が変化したときのみ対応
    final nextChanged     = track    != _ttsNextTrack;
    final nextNextChanged = nextNext != _ttsNextNextTrack;

    if (!(nextChanged || nextNextChanged)) return; // 同じ情報なら何もしない

    if (!_ttsCompleter!.isCompleted) {
      // 生成中かつ情報が変化 → 新情報で再生成
      debugPrint('DjProvider: nextTrack changed during generation, restarting TTS'
          ' (next: $_ttsNextTrack → $track)');
      _cancelTts();
      _startTtsGeneration();
    }
    // 生成完了済みなら変化があっても使用済みデータを保持（再生成しない）
  }

  void _pingHostSilently() {
    if (_hostAddress.isEmpty) return;
    HostClient(hostAddress: _hostAddress, port: _port)
        .ping()
        .then((ok) {
          debugPrint('DjProvider: ping ${ok ? "OK" : "FAILED"}');
          _hostConnected = ok;
          notifyListeners();
        })
        .catchError((e) {
          debugPrint('DjProvider: ping error: $e');
          _hostConnected = false;
          notifyListeners();
        });
  }

  @override
  void dispose() {
    _nextTrackSub?.cancel();
    super.dispose();
  }
}
