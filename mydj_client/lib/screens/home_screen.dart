import 'dart:async';
import 'dart:typed_data';
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

class _HomeScreenState extends State<HomeScreen> {
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

  /// 起動時に現在再生中のトラックを取得
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
      (_) {
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
    _trackSubscription?.cancel();
    _trackEndingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final dj = context.watch<DjProvider>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(context, settings, dj),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // アルバムアート（上角丸）+ スワイプ
                _SwipeableAlbumArt(albumArt: dj.currentTrack?.albumArt),

                // グラデーションオーバーレイ
                const _GradientOverlay(),

                // 楽曲情報
                Positioned(
                  left: 0, right: 0, bottom: 0,
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

  AppBar _buildAppBar(BuildContext context, SettingsProvider settings, DjProvider dj) {
    // サービス ON 中はホスト接続確認の結果を優先表示する
    final connStatus = dj.isServiceEnabled
        ? (dj.hostConnected == true
            ? ConnectionStatus.connected
            : dj.hostConnected == false
                ? ConnectionStatus.error
                : ConnectionStatus.unconfigured)
        : settings.connectionStatus;

    return AppBar(
      backgroundColor: Colors.black,
      elevation: 0,
      title: Image.asset('assets/logo.png', height: 30),
      actions: [
        _ConnectionDot(status: connStatus),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.settings_outlined, size: 22, color: Colors.white),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context, DjProvider dj, SettingsProvider settings) {
    final isOn = dj.isServiceEnabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOn ? const Color(0xFFFF3B30) : const Color(0xFF444444),
                  boxShadow: isOn
                      ? [BoxShadow(color: const Color(0xFFFF3B30).withValues(alpha: 0.7), blurRadius: 10, spreadRadius: 1)]
                      : [],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isOn ? const Color(0xFFFF3B30) : const Color(0xFF333333),
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

// ---- スワイプ対応アルバムアート背景 ----
class _SwipeableAlbumArt extends StatefulWidget {
  final Uint8List? albumArt;
  const _SwipeableAlbumArt({this.albumArt});

  @override
  State<_SwipeableAlbumArt> createState() => _SwipeableAlbumArtState();
}

class _SwipeableAlbumArtState extends State<_SwipeableAlbumArt>
    with SingleTickerProviderStateMixin {
  final _notificationService = NotificationService();
  late final AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;
  bool _isSwiping = false;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slideAnim = Tween<Offset>(begin: Offset.zero, end: Offset.zero)
        .animate(_slideCtrl);
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSwipe(bool toNext) async {
    if (_isSwiping) return;
    setState(() => _isSwiping = true);

    // 触覚フィードバック
    HapticFeedback.lightImpact();

    // DJトークをスキップするフラグを立てる
    context.read<DjProvider>().suppressNextTalk();

    // スライドアウト
    final endOffset = Offset(toNext ? -1.2 : 1.2, 0);
    _slideAnim = Tween<Offset>(begin: Offset.zero, end: endOffset)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeIn));
    await _slideCtrl.forward();

    // スキップコマンド送信
    if (toNext) {
      await _notificationService.skipToNext();
    } else {
      await _notificationService.skipToPrevious();
    }

    // 反対側からスライドイン準備
    _slideCtrl.reset();
    _slideAnim = Tween<Offset>(
      begin: Offset(toNext ? 1.2 : -1.2, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut));
    await _slideCtrl.forward();

    setState(() => _isSwiping = false);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final albumArt = widget.albumArt;

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        const threshold = 120.0;
        final v = details.primaryVelocity ?? 0;
        if (v < -threshold) _handleSwipe(true);   // 左スワイプ → 次へ
        if (v > threshold) _handleSwipe(false);   // 右スワイプ → 前へ
      },
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SlideTransition(
          position: _slideAnim,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
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
    return SizedBox.expand(
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
    );
  }
}

// ---- 楽曲情報 ----
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
                shadows: [Shadow(color: Colors.black.withValues(alpha: 0.8), blurRadius: 12)],
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
                shadows: [Shadow(color: Colors.black.withValues(alpha: 0.8), blurRadius: 8)],
              ),
            ),
          ] else ...[
            Text(
              settings.isConfigured ? 'Waiting for music...' : 'Configure host to begin',
              style: GoogleFonts.inter(fontSize: 18, color: const Color(0xFF444444)),
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

          // DJ処理中
          if (dj.isProcessing) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF888888)),
                ),
                const SizedBox(width: 10),
                Text('Generating DJ talk...',
                    style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF666666))),
              ],
            ),
          ],

          // エラー
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
                  style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFFCC4444))),
            ),
          ],
        ],
      ),
    );
  }
}

// ---- 接続ステータスドット ----
class _ConnectionDot extends StatelessWidget {
  final ConnectionStatus status;
  const _ConnectionDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      ConnectionStatus.connected => const Color(0xFF44CC44),
      ConnectionStatus.error => const Color(0xFFCC4444),
      ConnectionStatus.unconfigured => const Color(0xFF444444),
    };
    return Container(
      width: 6, height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
