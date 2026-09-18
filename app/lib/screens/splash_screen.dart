import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoCtrl;
  late final AnimationController _barCtrl;
  late final AnimationController _fadeCtrl;

  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoScale;
  late final Animation<double> _barProgress;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();

    // ロゴ フェードイン＋スケール
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoOpacity = CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOut);
    _logoScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOutCubic),
    );

    // プログレスバー
    _barCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _barProgress = CurvedAnimation(parent: _barCtrl, curve: Curves.easeInOut);

    // 画面フェードアウト
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeOut = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);

    _runSequence();
  }

  Future<void> _runSequence() async {
    // ロゴをフェードイン
    await _logoCtrl.forward();

    // プログレスバーを走らせながら設定をロード
    _barCtrl.forward();
    await context.read<SettingsProvider>().load();

    // バーが最低でも終端まで行くのを待つ
    await _barCtrl.forward();

    // 少し止まってから遷移
    await Future.delayed(const Duration(milliseconds: 200));
    await _fadeCtrl.forward();

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _barCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOut),
        child: Stack(
          children: [
            // ロゴ（中央）
            Center(
              child: FadeTransition(
                opacity: _logoOpacity,
                child: ScaleTransition(
                  scale: _logoScale,
                  child: Image.asset('assets/logo.png', width: 220),
                ),
              ),
            ),

            // プログレスバー（下部）
            Positioned(
              left: 0,
              right: 0,
              bottom: 60,
              child: FadeTransition(
                opacity: _logoOpacity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: AnimatedBuilder(
                    animation: _barProgress,
                    builder: (_, __) => _SlimProgressBar(
                      value: _barProgress.value,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlimProgressBar extends StatelessWidget {
  final double value;
  const _SlimProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: 2,
        color: const Color(0xFF1A1A1A),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withValues(alpha: 0.3),
                    Colors.white,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
