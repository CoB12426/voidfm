import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/dj_provider.dart';
import '../services/dj_backend.dart';
import '../services/notification_service.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final _notificationService = NotificationService();
  StreamSubscription? _trackSubscription;
  StreamSubscription? _trackEndingSubscription;
  Future<void> _eventChain = Future.value();

  @override
  void initState() {
    super.initState();
    _fetchCurrentTrack();
    _startListening();
  }

  Future<void> _fetchCurrentTrack() async {
    final track = await _notificationService.getCurrentTrack();
    if (track != null && mounted) {
      context.read<DjProvider>().setTrack(track);
    }
  }

  void _startListening() {
    _trackSubscription = _notificationService.trackStream.listen(
      (track) {
        if (track.title.trim().isEmpty || track.artist.trim().isEmpty) {
          debugPrint('Notification stream ignored invalid track: $track');
          return;
        }
        final settings = context.read<SettingsProvider>();
        final dj = context.read<DjProvider>();
        _eventChain = _eventChain.then((_) {
          return dj.onTrackChanged(
            newTrack: track,
            backend: settings.backend,
            preferences: settings.djPreferences,
          );
        }).catchError((e) {
          debugPrint('Notification stream error: $e');
        });
      },
      onError: (e) => debugPrint('Notification stream error: $e'),
    );

    _trackEndingSubscription = _notificationService.trackEndingStream.listen(
      (event) {
        debugPrint('Track ending event: $event');
        final settings = context.read<SettingsProvider>();
        final dj = context.read<DjProvider>();
        _eventChain = _eventChain.then((_) {
          return dj.onTrackEndingSoon(
            backend: settings.backend,
            preferences: settings.djPreferences,
          );
        }).catchError((e) {
          debugPrint('Track ending stream error: $e');
        });
      },
      onError: (e) => debugPrint('Track ending stream error: $e'),
    );
  }

  @override
  void dispose() {
    _trackSubscription?.cancel();
    _trackEndingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final dj = context.watch<DjProvider>();

    final connStatus = dj.isServiceEnabled
        ? (dj.hostConnected == true
            ? ConnectionStatus.connected
            : dj.hostConnected == false
                ? ConnectionStatus.error
                : ConnectionStatus.unconfigured)
        : settings.connectionStatus;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(context, connStatus, settings),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // アルバムアート（上角丸）+ ドラッグ追従スワイプ
                Positioned.fill(
                  child: _SwipeableAlbumArt(
                    albumArt: dj.currentTrack?.albumArt,
                  ),
                ),

                // グラデーションオーバーレイ
                const _GradientOverlay(),
                _OnAirGlow(isOn: dj.isServiceEnabled),

                // 楽曲情報
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _TrackInfo(dj: dj, settings: settings),
                ),
              ],
            ),
          ),
          _buildFooter(context, dj, settings),
        ],
      ),
    );
  }

  AppBar _buildAppBar(BuildContext context, ConnectionStatus status,
      SettingsProvider settings) {
    Color? dotColor;
    bool dotGlow = false;
    if (status == ConnectionStatus.connected) {
      dotColor = const Color(0xFF44CC44);
      dotGlow = true;
    } else if (status == ConnectionStatus.error) {
      dotColor = const Color(0xFFCC4444);
    }

    return AppBar(
      backgroundColor: Colors.black,
      elevation: 0,
      title: Image.asset('assets/logo.png', height: 30),
      actions: [
        _EngineChip(
          settings: settings,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        if (dotColor != null)
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 4),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: dotGlow
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.7),
                            blurRadius: 8,
                          )
                        ]
                      : null,
                ),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.settings_outlined,
              size: 22, color: Colors.white),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(
    BuildContext context,
    DjProvider dj,
    SettingsProvider settings,
  ) {
    final isOn = dj.isServiceEnabled;
    final dotColor = isOn ? const Color(0xFFFF3B30) : const Color(0xFF444444);
    final textColor = isOn ? const Color(0xFFFF3B30) : const Color(0xFF333333);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              // ON AIR インジケータードット（アクセントカラーで光る）
              AnimatedContainer(
                duration: const Duration(milliseconds: 600),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: isOn
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.7),
                            blurRadius: 10,
                            spreadRadius: 1,
                          )
                        ]
                      : [],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  letterSpacing: isOn ? 1.5 : 0,
                ),
                child: Text(isOn ? 'ON AIR' : 'OFF'),
              ),
            ],
          ),
          Switch(
            value: isOn,
            onChanged: settings.isConfigured
                ? (_) async {
                    await dj.toggleService(
                      backend: settings.backend,
                      preferences: settings.djPreferences,
                    );
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

// ---- スワイプ対応アルバムアート背景（ドラッグ追従アニメーション）----
class _SwipeableAlbumArt extends StatefulWidget {
  final Uint8List? albumArt;
  const _SwipeableAlbumArt({this.albumArt});

  @override
  State<_SwipeableAlbumArt> createState() => _SwipeableAlbumArtState();
}

class _SwipeableAlbumArtState extends State<_SwipeableAlbumArt>
    with SingleTickerProviderStateMixin {
  final _notificationService = NotificationService();
  late final AnimationController _animCtrl;
  Animation<double>? _activeAnim;

  // 現在の水平オフセット（論理ピクセル）
  double _dragOffsetPx = 0.0;
  bool _isSwiping = false;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    // アニメーション中は _dragOffsetPx を更新し続ける
    _animCtrl.addListener(() {
      final anim = _activeAnim;
      if (anim != null && mounted) {
        setState(() => _dragOffsetPx = anim.value);
      }
    });
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  // ドラッグ中: 指に追従してアルバムアートを動かす
  void _onDragUpdate(DragUpdateDetails details) {
    if (_isSwiping) return;
    _animCtrl.stop(); // スプリングバック中でも即座に追従
    setState(() => _dragOffsetPx += details.delta.dx);
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    if (_isSwiping) return;
    final width = MediaQuery.of(context).size.width;
    final velocity = details.primaryVelocity ?? 0;
    final toNext = _dragOffsetPx < -(width * 0.3) || velocity < -500;
    final toPrev = _dragOffsetPx > (width * 0.3) || velocity > 500;

    if (toNext || toPrev) {
      await _handleSwipe(toNext, width);
    } else {
      // 閾値未満: 元の位置にスプリングバック
      await _animateTo(0.0, curve: Curves.easeOut, durationMs: 220);
    }
  }

  // _dragOffsetPx を target まで滑らかにアニメーション
  Future<void> _animateTo(double target,
      {Curve curve = Curves.easeOut, int durationMs = 280}) async {
    _animCtrl.duration = Duration(milliseconds: durationMs);
    _activeAnim = Tween<double>(begin: _dragOffsetPx, end: target)
        .animate(CurvedAnimation(parent: _animCtrl, curve: curve));
    _animCtrl.reset();
    await _animCtrl.forward();
  }

  Future<void> _handleSwipe(bool toNext, double width) async {
    if (_isSwiping) return;
    setState(() => _isSwiping = true);

    HapticFeedback.lightImpact();
    context.read<DjProvider>().suppressNextTalk();

    try {
      // スライドアウト
      await _animateTo(
        toNext ? -(width * 1.3) : (width * 1.3),
        curve: Curves.easeInCubic,
        durationMs: 220,
      );
      if (!mounted) return;

      // スキップコマンド送信
      if (toNext) {
        await _notificationService.skipToNext();
      } else {
        await _notificationService.skipToPrevious();
      }
      if (!mounted) return;

      // 反対側からスライドイン
      setState(() => _dragOffsetPx = toNext ? width * 1.3 : -(width * 1.3));
      await _animateTo(0.0, curve: Curves.easeOutCubic, durationMs: 320);
    } catch (e) {
      debugPrint('Album swipe failed: $e');
      if (mounted) {
        await _animateTo(0.0, curve: Curves.easeOutCubic, durationMs: 220);
      }
    } finally {
      if (mounted) {
        setState(() => _isSwiping = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final albumArt = widget.albumArt;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        if (_isSwiping) return;
        _animCtrl.stop();
      },
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () {
        if (!_isSwiping && _dragOffsetPx != 0) {
          unawaited(
              _animateTo(0.0, curve: Curves.easeOutCubic, durationMs: 180));
        }
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Transform.translate(
          offset: Offset(_dragOffsetPx, 0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            child: albumArt != null
                ? SizedBox.expand(
                    key: ValueKey(albumArt.length),
                    child: Image.memory(
                      albumArt,
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                    ),
                  )
                : SizedBox.expand(
                    key: const ValueKey('default'),
                    child: Center(
                      child: Opacity(
                        opacity: 0.12,
                        child: Image.asset(
                          'assets/icon.png',
                          width: size.width * 0.55,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ---- グラデーションオーバーレイ ----
class _GradientOverlay extends StatelessWidget {
  const _GradientOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.45, 0.72, 1.0],
              colors: [
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.75),
                Colors.black,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnAirGlow extends StatelessWidget {
  final bool isOn;
  const _OnAirGlow({required this.isOn});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: isOn ? 1 : 0,
        duration: const Duration(milliseconds: 600),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.0, 0.82),
              radius: 1.08,
              colors: [
                const Color(0xFFFF3B30).withValues(alpha: 0.18),
                Colors.transparent,
              ],
              stops: const [0.0, 0.72],
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ---- 楽曲情報（現在曲 + 次曲プレビュー）----
class _TrackInfo extends StatelessWidget {
  final DjProvider dj;
  final SettingsProvider settings;
  const _TrackInfo({required this.dj, required this.settings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dj.currentTrack != null) ...[
            Text(
              'NOW PLAYING',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF888888),
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              dj.currentTrack!.title,
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -0.5,
                shadows: [
                  Shadow(
                      color: Colors.black.withValues(alpha: 0.8),
                      blurRadius: 12)
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              dj.currentTrack!.artist,
              style: GoogleFonts.inter(
                fontSize: 15,
                color: const Color(0xFFAAAAAA),
                shadows: [
                  Shadow(
                      color: Colors.black.withValues(alpha: 0.8), blurRadius: 8)
                ],
              ),
            ),

            // 次曲プレビュー（nextTrack が取得できているときのみ表示）
            if (dj.nextTrack != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'NEXT',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF555555),
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MarqueeText(
                      text:
                          '${dj.nextTrack!.artist}  ·  ${dj.nextTrack!.title}',
                      style: GoogleFonts.inter(
                          fontSize: 11, color: const Color(0xFF666666)),
                    ),
                  ),
                ],
              ),
            ],
          ] else ...[
            Text(
              settings.isConfigured
                  ? 'Waiting for music...'
                  : settings.backendMode == DjBackendMode.remote
                      ? 'Configure host to begin'
                      : 'Select local models to begin',
              style: GoogleFonts.inter(
                  fontSize: 18, color: const Color(0xFF444444)),
            ),
            if (!settings.isConfigured) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen())),
                child: Text(settings.backendMode == DjBackendMode.remote
                    ? 'Set up host'
                    : 'Set up models'),
              ),
            ],
          ],

          // DJ処理中インジケーター
          if (dj.isProcessing) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: Color(0xFF888888)),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(_processingLabel(dj, settings),
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 12, color: const Color(0xFF666666))),
                ),
              ],
            ),
          ],

          // 直前のトーク枠の結果（再生 / 間に合わずスキップ）
          if (dj.isOnAir && !dj.isPlayingTalk && dj.lastTalkNote != null) ...[
            const SizedBox(height: 6),
            Text(dj.lastTalkNote!,
                style: GoogleFonts.inter(
                    fontSize: 11,
                    color: dj.lastTalkNote!.startsWith('Skipped')
                        ? const Color(0xFFB08A3A)
                        : const Color(0xFF555555))),
          ],

          // エラー表示
          if (dj.lastTalkError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF3A1A1A)),
              ),
              child: Text(dj.lastTalkError!,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: const Color(0xFFCC4444))),
            ),
          ],
        ],
      ),
    );
  }
}

String _processingLabel(DjProvider dj, SettingsProvider settings) {
  if (dj.isPlayingTalk) return 'On air: ${dj.playingLabel ?? 'DJ talk'}';
  final what = dj.isPreparingStationId ? 'station ID' : 'DJ talk';
  return settings.backendMode == DjBackendMode.remote
      ? 'Generating $what on remote host...'
      : 'Generating $what on this phone...';
}

// ---- 現在の DJ エンジン表示（タップで設定へ）----
class _EngineChip extends StatelessWidget {
  final SettingsProvider settings;
  final VoidCallback onTap;

  const _EngineChip({required this.settings, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final remote = settings.backendMode == DjBackendMode.remote;
    final label = remote ? 'REMOTE' : 'ON-DEVICE';
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF333333)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(remote ? Icons.computer : Icons.smartphone,
                  size: 13, color: const Color(0xFFAAAAAA)),
              const SizedBox(width: 5),
              Text(label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: const Color(0xFFAAAAAA),
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- マーキーテキスト（テキストが長い場合に自動横スクロール）----
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  final _scrollCtrl = ScrollController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleMarquee();
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _timer?.cancel();
      if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
      _scheduleMarquee();
    }
  }

  // 初回 2 秒待ってからスクロール開始
  void _scheduleMarquee() {
    _timer = Timer(const Duration(seconds: 2), _runMarquee);
  }

  Future<void> _runMarquee() async {
    if (!mounted || !_scrollCtrl.hasClients) return;
    final max = _scrollCtrl.position.maxScrollExtent;
    if (max <= 0) return; // 収まっていればスクロール不要

    await _scrollCtrl.animateTo(
      max,
      duration: Duration(milliseconds: (max * 20).round()),
      curve: Curves.linear,
    );
    if (!mounted) return;

    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted || !_scrollCtrl.hasClients) return;

    _scrollCtrl.jumpTo(0);
    _scheduleMarquee(); // 先頭に戻して再ループ
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _scrollCtrl,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, style: widget.style, maxLines: 1),
    );
  }
}
