import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  // トーク頻度管理
  int _songsSinceTalk = 0;  // 最後のトーク再生からの経過曲数

  // radio4all カウンター（10回に1回 radio4all.mp3 を再生）
  int _talkPlayCount = 0;
  static const _radioAllEvery = 10;
  static const _radioAllAsset = 'assets/audio/radio4all.mp3';

  // 再生履歴（最大5件、古い順）
  final List<TrackInfo> _trackHistory = [];
  static const _maxHistorySize = 5;

  static const _skipThresholdSec = 30;
  static const _introPreloadTimeout = Duration(seconds: 4);
  static const _introPreRollBuffer = Duration(milliseconds: 180);
  // 曲切替直後のホスト負荷で TTS 生成が遅れることがあるため、
  // ある程度待ってからスキップ判定する。
  static const _ttsReadyTimeout = Duration(seconds: 12);

  // ── TTS 生成 ──────────────────────────────────────────────────────────
  Completer<Uint8List?>? _ttsCompleter;
  TrackInfo? _ttsForTrack;          // 生成対象の currentTrack
  TrackInfo? _ttsNextTrack;         // 生成開始時に使った nextTrack
  http.Client? _ttsHttpClient;      // 進行中リクエストのキャンセル用
  List<TrackInfo> _ttsHistory = []; // 生成開始時の履歴スナップショット
  bool _prependJingle = false;      // station ID 再生前に jingle.mp3 を挟む

  // ── 設定 ─────────────────────────────────────────────────────────────
  String        _hostAddress = '';
  int           _port        = 8000;
  DjPreferences _preferences = const DjPreferences();

  // ── イントロアセット ──────────────────────────────────────────────────
  // intro_en_N.wav を assets/audio/ に追加すればリストを延ばすだけで対応可能
  static const _introAssets = [
    'assets/audio/intro_en_1.wav',
    'assets/audio/intro_en_2.wav',
    'assets/audio/intro_en_3.wav',
  ];

  // Station ID をランダムに代替する確率（0.0〜1.0）
  static const _stationIdRate = 0.25;

  final _rng = Random();

  String _pickIntroAsset() => _introAssets[_rng.nextInt(_introAssets.length)];

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
      _onNextTrackUpdated(next);
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
      _isOnAir          = false;
      _awaitingMusic    = false;
      _songsSinceTalk   = 0;
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

    // 再生履歴を更新（スキップでも自然終了でも記録）
    if (prevTrack != null) _addToHistory(prevTrack);

    _currentTrack   = newTrack;
    _trackStartTime = now;
    _nextTrack      = null;
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
    
    // トーク頻度チェック（自然終了時のみカウント）
    final shouldTalk = _checkTalkFrequency();

    if (!shouldTalk) {
      debugPrint('DjProvider: skipping talk (frequency=${_preferences.talkFrequency}, '
          'count=$_songsSinceTalk)');
      _cancelTts();
      await _restoreMusicPlayback();
    } else if (_shouldPlayRadioAll()) {
      debugPrint('DjProvider: radio4all ($_talkPlayCount)');
      _cancelTts();
      await _playAssetTalk(_radioAllAsset);
    } else if (prevTrack != null &&
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
      // トーク頻度チェック
      if (!_checkTalkFrequency()) {
        debugPrint('DjProvider: onTrackEndingSoon — skipping talk (frequency)');
        _cancelTts();
        await _restoreMusicPlayback();
        return;
      }

      // radio4all チェック
      if (_shouldPlayRadioAll()) {
        debugPrint('DjProvider: onTrackEndingSoon — radio4all ($_talkPlayCount)');
        _cancelTts();
        _suppressNextTalk = true;
        await _playAssetTalk(_radioAllAsset, skipToNextAfterTalk: true);
        _startTtsGeneration();
        return;
      }

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

  /// radio4all を再生すべきか判定し、カウンターを更新する。
  bool _shouldPlayRadioAll() {
    _talkPlayCount++;
    return _talkPlayCount % _radioAllEvery == 0;
  }

  /// ローカルアセットをそのまま void talk として再生する（LLM/TTS 不要）。
  Future<void> _playAssetTalk(String assetPath, {bool skipToNextAfterTalk = false}) async {
    debugPrint('DjProvider: _playAssetTalk — $assetPath');
    _isPlayingTalk = true;
    _lastTalkError = null;
    notifyListeners();
    try {
      await _notif.setDjHoldPlayback(true);
      await _audio.pauseMusic();
      await Future.delayed(const Duration(milliseconds: 150));
      await _audio.playAsset(assetPath);
    } catch (e) {
      debugPrint('DjProvider: _playAssetTalk error: $e');
      _lastTalkError = e.toString();
    } finally {
      await Future.delayed(const Duration(milliseconds: 150));
      if (skipToNextAfterTalk) await _notif.skipToNext();
      await _restoreMusicPlayback();
      _isPlayingTalk = false;
      notifyListeners();
    }
  }

  /// トラックを再生履歴に追加する（最大 [_maxHistorySize] 件）。
  void _addToHistory(TrackInfo track) {
    _trackHistory.removeWhere((t) => t == track);
    _trackHistory.add(track);
    while (_trackHistory.length > _maxHistorySize) {
      _trackHistory.removeAt(0);
    }
  }

  /// トーク頻度チェック。true なら今回トークを再生すべき（カウンタ更新込み）。
  bool _checkTalkFrequency() {
    _songsSinceTalk++;
    if (_songsSinceTalk >= _preferences.talkFrequency) {
      _songsSinceTalk = 0;
      return true;
    }
    return false;
  }

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
  /// [_stationIdRate] の確率で Station ID に切り替える。
  void _startTtsGeneration() {
    _cancelTts();
    if (_currentTrack == null || _hostAddress.isEmpty) return;

    if (_rng.nextDouble() < _stationIdRate) {
      _startStationIdFetch();
      return;
    }

    final forTrack    = _currentTrack!;
    final songNext    = _nextTrack;
    final historySnap = List<TrackInfo>.from(_trackHistory);

    _ttsForTrack  = forTrack;
    _ttsNextTrack = songNext;
    _ttsHistory   = historySnap;
    final completer = Completer<Uint8List?>();
    _ttsCompleter = completer;

    debugPrint('DjProvider: TTS start — prev="${forTrack.title}" '
        'next="${songNext?.title ?? "?"}" history=${historySnap.length}');

    _generateTts(
      previousTrack: forTrack,
      currentTrack:  songNext,
      trackHistory:  historySnap,
    ).then((bytes) {
      debugPrint('DjProvider: TTS generation completed (${bytes?.length ?? 0} bytes)');
      if (!completer.isCompleted) {
        completer.complete(bytes);
      } else {
        debugPrint('DjProvider: TTS Completer already completed (discarding result)');
      }
    }).catchError((e) {
      debugPrint('DjProvider: TTS generation error: $e');
      if (!completer.isCompleted) completer.complete(null);
    });
  }

  /// Station ID をフェッチしてコンプリーターにセットする。
  void _startStationIdFetch() {
    final forTrack = _currentTrack!;
    _ttsForTrack   = forTrack;
    _ttsNextTrack  = null;
    _ttsHistory    = [];
    _prependJingle = true;  // 再生前に jingle.mp3 を挟む
    final completer = Completer<Uint8List?>();
    _ttsCompleter = completer;

    debugPrint('DjProvider: station ID fetch start');
    _fetchStationId().then((bytes) {
      debugPrint('DjProvider: station ID done (${bytes?.length ?? 0} bytes)');
      if (!completer.isCompleted) completer.complete(bytes);
    }).catchError((e) {
      debugPrint('DjProvider: station ID failed: $e');
      if (!completer.isCompleted) completer.complete(null);
    });
  }

  void _cancelTts() {
    // 進行中の HTTP リクエストを強制中断する
    _ttsHttpClient?.close();
    _ttsHttpClient  = null;
    _ttsCompleter   = null;
    _ttsForTrack    = null;
    _ttsNextTrack   = null;
    _ttsHistory     = [];
    _prependJingle  = false;
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

  /// TTS 音声を再生する（音楽を一時停止 → [jingle →] void talk → resumeMusic）。
  Future<void> _playVoidTalk({bool skipToNextAfterTalk = false}) async {
    debugPrint('DjProvider: _playVoidTalk start');
    final wavBytes    = await _ttsCompleter!.future;
    final withJingle  = _prependJingle;
    _cancelTts();

    if (wavBytes == null || wavBytes.isEmpty) {
      debugPrint('DjProvider: _playVoidTalk — TTS bytes empty, skipping');
      await _restoreMusicPlayback();
      return;
    }

    debugPrint('DjProvider: _playVoidTalk — ${wavBytes.length} bytes, jingle=$withJingle');
    _isPlayingTalk = true;
    _lastTalkError = null;
    notifyListeners();

    try {
      await _notif.setDjHoldPlayback(true);
      await _audio.pauseMusic();
      await Future.delayed(const Duration(milliseconds: 150));

      if (withJingle) {
        debugPrint('DjProvider: _playVoidTalk — playing jingle');
        await _audio.playAsset('assets/audio/jingle.m4a');
      }

      debugPrint('DjProvider: _playVoidTalk — playTalk()');
      await _audio.playTalk(wavBytes, contentType: 'audio/mpeg');
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

  /// ホストへリクエストを送り音声バイト列を返す（null = 失敗 or キャンセル）。
  Future<Uint8List?> _generateTts({
    required TrackInfo previousTrack,
    TrackInfo?         currentTrack,
    List<TrackInfo>    trackHistory = const [],
  }) async {
    final client = http.Client();
    _ttsHttpClient = client;
    try {
      final bytes = await HostClient(
        hostAddress: _hostAddress,
        port:        _port,
        client:      client,
      ).fetchTalk(
        previousTrack: previousTrack,
        currentTrack:  currentTrack ?? previousTrack,
        preferences:   _preferences,
        trackHistory:  trackHistory,
      );
      debugPrint('DjProvider: TTS done (${bytes.length} bytes)');
      return bytes;
    } on http.ClientException catch (e) {
      // client.close() によるキャンセル、または接続エラー
      debugPrint('DjProvider: TTS cancelled or connection error: $e');
      return null;
    } catch (e) {
      debugPrint('DjProvider: TTS failed: $e');
      return null;
    } finally {
      // 自分が登録したクライアントなら解放
      if (_ttsHttpClient == client) _ttsHttpClient = null;
      client.close();
    }
  }

  /// GET /station_id から音声バイト列を返す（null = 失敗 or キャンセル）。
  Future<Uint8List?> _fetchStationId() async {
    final client = http.Client();
    _ttsHttpClient = client;
    try {
      final bytes = await HostClient(
        hostAddress: _hostAddress,
        port:        _port,
        client:      client,
      ).fetchStationId();
      return bytes;
    } on http.ClientException catch (e) {
      debugPrint('DjProvider: station ID cancelled or connection error: $e');
      return null;
    } catch (e) {
      debugPrint('DjProvider: station ID failed: $e');
      return null;
    } finally {
      if (_ttsHttpClient == client) _ttsHttpClient = null;
      client.close();
    }
  }

  /// nextTrack 情報が更新された。nextTrack が実際に変化した場合のみ TTS を再生成する。
  void _onNextTrackUpdated(TrackInfo track) {
    debugPrint('DjProvider: _onNextTrackUpdated — next="${track.title}"');
    _nextTrack = track;

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

    if (_ttsNextTrack == track) return; // 同じ情報なら何もしない

    if (!_ttsCompleter!.isCompleted) {
      if (_ttsNextTrack == null) {
        // 曲変更直後の生成（nextTrack 未取得）に nextTrack 情報が初めて届いた。
        // 再生成はせず、次回の比較用として記録だけ更新する。
        debugPrint('DjProvider: nextTrack arrived for in-progress generation, '
            'updating stored value without restart — next="$track"');
        _ttsNextTrack = track;
      } else {
        // すでに nextTrack 情報ありで生成中 → より新しい情報で再生成
        debugPrint('DjProvider: nextTrack changed during generation, restarting TTS'
            ' (next: $_ttsNextTrack → $track)');
        _cancelTts();
        _startTtsGeneration();
      }
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
