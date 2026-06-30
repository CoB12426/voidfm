import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/dj_provider.dart';
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

  late final AnimationController _panelCtrl;
  double _panelDragExtent = 1.0;

  @override
  void initState() {
    super.initState();
    _panelCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
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
            hostAddress: settings.hostAddress,
            port: settings.port,
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
            hostAddress: settings.hostAddress,
            port: settings.port,
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
    _panelCtrl.dispose();
    _trackSubscription?.cancel();
    _trackEndingSubscription?.cancel();
    super.dispose();
  }

  void _onPanelDragUpdate(DragUpdateDetails details) {
    _panelCtrl.stop();
    final delta = -details.delta.dy / _panelDragExtent;
    _panelCtrl.value = (_panelCtrl.value + delta).clamp(0.0, 1.0);
  }

  void _onPanelDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldOpen =
        velocity < -450 || (velocity <= 450 && _panelCtrl.value > 0.32);
    if (shouldOpen && _panelCtrl.value < 1.0) {
      HapticFeedback.lightImpact();
    }
    final target = shouldOpen ? 1.0 : 0.0;
    final distance = (target - _panelCtrl.value).abs();
    _panelCtrl.animateTo(
      target,
      duration: Duration(milliseconds: (180 + 220 * distance).round()),
      curve: shouldOpen ? Curves.easeOutCubic : Curves.easeInOutCubic,
    );
  }

  void _openTalkPanel() {
    HapticFeedback.lightImpact();
    _panelCtrl.animateTo(
      1.0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  void _closeTalkPanel() {
    _panelCtrl.animateTo(
      0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
    );
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
      appBar: _buildAppBar(context, connStatus),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final panelHeight = _resolvePanelHeight(constraints.maxHeight);
                const panelPeekHeight = 42.0;
                _panelDragExtent = panelHeight;

                final panelStack = Stack(
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

                    // 楽曲情報 + DJトークパネル（アニメーション付き）
                    AnimatedBuilder(
                      animation: _panelCtrl,
                      builder: (context, _) {
                        final f = _panelCtrl.value;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Opacity(
                                opacity: (1.0 - f * 0.5).clamp(0.0, 1.0),
                                child: Transform.translate(
                                  offset: Offset(0, -panelHeight * 0.42 * f),
                                  child: _TrackInfo(dj: dj, settings: settings),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: panelHeight,
                              child: IgnorePointer(
                                ignoring: f < 0.02,
                                child: Transform.translate(
                                  offset: Offset(
                                    0,
                                    (panelHeight - panelPeekHeight) * (1.0 - f),
                                  ),
                                  child: _DjTalkPanel(
                                    script: dj.lastTalkScript,
                                    isGenerating: dj.isGeneratingTalk,
                                    onClose: _closeTalkPanel,
                                    onDragUpdate: _onPanelDragUpdate,
                                    onDragEnd: _onPanelDragEnd,
                                  ),
                                ),
                              ),
                            ),
                            if (f < 0.02)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: panelPeekHeight,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _openTalkPanel,
                                  onVerticalDragUpdate: _onPanelDragUpdate,
                                  onVerticalDragEnd: _onPanelDragEnd,
                                  child: _TalkPanelPeek(
                                    isGenerating: dj.isGeneratingTalk,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                );
                // パネルが全開のときは外側 GestureDetector を外し、
                // SingleChildScrollView がスクロールを受け取れるようにする。
                // ドラッグ操作はパネルのハンドル部分が担う。
                return AnimatedBuilder(
                  animation: _panelCtrl,
                  child: panelStack,
                  builder: (_, child) {
                    if (_panelCtrl.value >= 0.999) return child!;
                    return GestureDetector(
                      onVerticalDragUpdate: _onPanelDragUpdate,
                      onVerticalDragEnd: _onPanelDragEnd,
                      behavior: HitTestBehavior.opaque,
                      child: child!,
                    );
                  },
                );
              },
            ),
          ),
          _buildFooter(context, dj, settings),
        ],
      ),
    );
  }

  double _resolvePanelHeight(double availableHeight) {
    if (availableHeight <= 0) return 1.0;

    final preferred = availableHeight * 0.78;
    final maxHeight = (availableHeight - 8).clamp(1.0, availableHeight);
    final minReadable = (availableHeight < 420 ? availableHeight * 0.68 : 320.0)
        .clamp(1.0, maxHeight);
    return preferred.clamp(minReadable, maxHeight).toDouble();
  }

  AppBar _buildAppBar(BuildContext context, ConnectionStatus status) {
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
        if (dotColor != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
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
                      hostAddress: settings.hostAddress,
                      port: settings.port,
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
                  : 'Configure host to begin',
              style: GoogleFonts.inter(
                  fontSize: 18, color: const Color(0xFF444444)),
            ),
            if (!settings.isConfigured) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen())),
                child: const Text('Set up host'),
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
                Text('Generating DJ talk...',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: const Color(0xFF666666))),
              ],
            ),
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

// ---- DJトークパネル（スワイプアップで表示）----
class _DjTalkPanel extends StatelessWidget {
  final String? script;
  final bool isGenerating;
  final VoidCallback onClose;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  const _DjTalkPanel({
    required this.isGenerating,
    required this.onClose,
    this.script,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final text = script?.trim();
    final hasScript = text != null && text.isNotEmpty;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ドラッグハンドル + ヘッダー（下スワイプでパネルを閉じる）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: onDragUpdate,
            onVerticalDragEnd: onDragEnd,
            child: Column(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Container(
                      width: 36,
                      height: 3,
                      decoration: BoxDecoration(
                        color: const Color(0xFF3A3A3A),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 14, 14),
                  child: Row(
                    children: [
                      const Icon(Icons.mic, size: 13, color: Color(0xFF666666)),
                      const SizedBox(width: 6),
                      Text(
                        'DJ TALK',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF666666),
                          letterSpacing: 1.5,
                        ),
                      ),
                      if (isGenerating) ...[
                        const SizedBox(width: 10),
                        const _GeneratingBadge(),
                      ],
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        tooltip: 'Close DJ talk',
                        onPressed: onClose,
                        icon: const Icon(
                          Icons.keyboard_arrow_down,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 台本テキスト
          Expanded(
            child: Scrollbar(
              radius: const Radius.circular(999),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  0,
                  24,
                  28 + MediaQuery.paddingOf(context).bottom,
                ),
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                child: hasScript
                    ? Text(
                        text,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          height: 1.7,
                          color: const Color(0xFFCCCCCC),
                        ),
                      )
                    : Text(
                        'DJトーク待機中...',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: const Color(0xFF444444),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TalkPanelPeek extends StatelessWidget {
  final bool isGenerating;
  const _TalkPanelPeek({
    required this.isGenerating,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 9, 24, 0),
        child: Row(
          children: [
            const Icon(Icons.mic, size: 13, color: Color(0xFF777777)),
            const SizedBox(width: 7),
            Text(
              'DJ TALK',
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF777777),
                letterSpacing: 1.4,
              ),
            ),
            if (isGenerating) ...[
              const SizedBox(width: 10),
              const _GeneratingBadge(),
            ],
            const Spacer(),
            const Icon(
              Icons.keyboard_arrow_up,
              size: 18,
              color: Color(0xFF777777),
            ),
          ],
        ),
      ),
    );
  }
}

class _GeneratingBadge extends StatelessWidget {
  const _GeneratingBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.4,
            color: Color(0xFF888888),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          'GENERATING',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF888888),
            letterSpacing: 0.8,
          ),
        ),
      ],
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
