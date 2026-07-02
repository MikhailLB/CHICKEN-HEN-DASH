import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_screen.dart';
import 'webview_screen.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  int _best = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _loadBest();
  }

  Future<void> _loadBest() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _best = prefs.getInt('best_score') ?? 0;
    });
  }

  void _openGame() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const GameScreen()),
    );
    _loadBest();
  }

  void _openWeb(String title, String url) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewScreen(title: title, url: url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset('assets/bgmenu.webp', fit: BoxFit.cover),
          Container(color: const Color(0x22000000)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  const _Title(),
                  const Spacer(),
                  _ScorePanel(best: _best),
                  const SizedBox(height: 28),
                  _MenuButton(
                    label: 'PLAY',
                    color: const Color(0xFF43C64F),
                    onTap: _openGame,
                  ),
                  const SizedBox(height: 16),
                  _MenuButton(
                    label: 'PRIVACY POLICY',
                    color: const Color(0xFF3E82F7),
                    onTap: () => _openWeb(
                      'Privacy Policy',
                      'https://hendash.com/privacy-policy.html',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _MenuButton(
                    label: 'SUPPORT',
                    color: const Color(0xFFF77A2E),
                    onTap: () => _openWeb(
                      'Support',
                      'https://hendash.com/support.html',
                    ),
                  ),
                  const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Text(
          'CHICKEN',
          style: TextStyle(
            fontSize: 44,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: 2,
            height: 1.0,
            shadows: [
              Shadow(color: Color(0xFF7A3C00), offset: Offset(0, 4), blurRadius: 0),
              Shadow(color: Color(0x99000000), offset: Offset(0, 6), blurRadius: 10),
            ],
          ),
        ),
        Text(
          'HEN DASH',
          style: TextStyle(
            fontSize: 54,
            fontWeight: FontWeight.w900,
            color: Color(0xFFFFD84D),
            letterSpacing: 3,
            height: 1.05,
            shadows: [
              Shadow(color: Color(0xFF7A3C00), offset: Offset(0, 4), blurRadius: 0),
              Shadow(color: Color(0x99000000), offset: Offset(0, 8), blurRadius: 12),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScorePanel extends StatelessWidget {
  const _ScorePanel({required this.best});
  final int best;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xCC5B3A00),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white, width: 3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.emoji_events, color: Color(0xFFFFD84D), size: 26),
          const SizedBox(width: 10),
          Text(
            'BEST  $best',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 62,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(18),
        elevation: 4,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white, width: 3),
            ),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                  shadows: [
                    Shadow(
                      color: Color(0x99000000),
                      offset: Offset(0, 2),
                      blurRadius: 4,
                    ),
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
