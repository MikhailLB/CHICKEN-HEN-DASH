import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'menu_screen.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _fillCtrl;
  late final AnimationController _dotsCtrl;
  Timer? _preTimer;
  double _staticProgress = 0.0;

  @override
  void initState() {
    super.initState();

    // Allow both orientations on loading screen.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _dotsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _fillCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );

    // Simulate loading progress in two phases:
    // 1) Slow crawl up to ~85% during "preload".
    // 2) Fast fill to 100% right before launch.
    _startLoading();
  }

  Future<void> _startLoading() async {
    // Phase 1: gradual crawl.
    const totalMs = 2200;
    const steps = 40;
    final stepMs = totalMs ~/ steps;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: stepMs));
      if (!mounted) return;
      setState(() {
        _staticProgress = (i / steps) * 0.85;
      });
    }
    // Phase 2: fast fill via animation.
    if (!mounted) return;
    _fillCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    await _fillCtrl.forward(from: 0);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => const MenuScreen(),
        transitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  double get _progress {
    if (_fillCtrl.isAnimating || _fillCtrl.isCompleted) {
      return 0.85 + 0.15 * _fillCtrl.value;
    }
    return _staticProgress;
  }

  @override
  void dispose() {
    _preTimer?.cancel();
    _fillCtrl.dispose();
    _dotsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFCC33),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isPortrait = constraints.maxHeight >= constraints.maxWidth;
          final asset = isPortrait
              ? 'assets/loading_vert.png'
              : 'assets/loading_hor.png';
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                asset,
                fit: BoxFit.cover,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: constraints.maxHeight * 0.08,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LoadingText(controller: _dotsCtrl),
                    const SizedBox(height: 16),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: constraints.maxWidth * 0.12,
                      ),
                      child: _ProgressBar(progress: _progress),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LoadingText extends StatelessWidget {
  const _LoadingText({required this.controller});
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final phase = (controller.value * 4).floor() % 4;
        final dots = '.' * phase;
        return Text(
          'Loading$dots',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 1.2,
            shadows: [
              Shadow(
                color: Color(0xAA5B3A00),
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      decoration: BoxDecoration(
        color: const Color(0xFF3B2100),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: progress.clamp(0.0, 1.0),
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFFFD84D), Color(0xFFFF8A00)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
