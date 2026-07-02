import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/game_assets.dart';
import '../game/game_painter.dart';
import '../game/game_state.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin {
  final GameAssets _assets = GameAssets();
  GameState? _state;
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _camY = 0;
  bool _ready = false;
  bool _savedScore = false;
  int _bestScore = 0;
  static const int _cols = 5;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _ticker = Ticker(_onTick);
    _prepare();
  }

  Future<void> _prepare() async {
    await _assets.load();
    final prefs = await SharedPreferences.getInstance();
    _bestScore = prefs.getInt('best_score') ?? 0;
    final gs = GameState(cols: _cols);
    gs.init(_assets);
    _state = gs;
    _ready = true;
    _lastTick = Duration.zero;
    _ticker.start();
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (!_ready || _state == null) return;
    double dt;
    if (_lastTick == Duration.zero) {
      dt = 0;
    } else {
      dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    }
    _lastTick = elapsed;
    if (dt > 0.05) dt = 0.05; // avoid big jumps
    _state!.update(dt, _assets);

    _updateCamera(dt);
    if (_state!.gameOver && !_savedScore) {
      _savedScore = true;
      _saveScore();
    }
    if (mounted) setState(() {});
  }

  void _updateCamera(double dt) {
    final st = _state!;
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final cellSize = size.width / _cols;
    // Rows visible above the chicken (want chicken ~65% down).
    final rowsBelow = 0.35 * size.height / cellSize;
    final desired = st.chickenRowD - rowsBelow + 1;
    if (desired > _camY) {
      _camY += (desired - _camY) * (1 - _decay(dt, 6));
    } else if (!st.gameOver && st.maxRowReached > 4) {
      // Auto-scroll forward once the player is past the starter zone.
      final creep = 0.30 + (st.maxRowReached / 60).clamp(0.0, 0.9);
      _camY += creep * dt;
    }

    // Kill if chicken is pushed off the bottom of the screen by the camera.
    final chickenScreenY =
        size.height - (st.chickenRowD - _camY) * cellSize - cellSize;
    if (chickenScreenY > size.height + cellSize && !st.gameOver) {
      st.forceKill();
    }
  }

  double _decay(double dt, double rate) {
    // exp(-rate * dt), stable for damping
    var v = 1.0;
    for (var i = 0; i < 4; i++) {
      v *= (1 - rate * dt / 4).clamp(0.0, 1.0);
    }
    return v;
  }

  Future<void> _saveScore() async {
    final prefs = await SharedPreferences.getInstance();
    final score = _state!.computeFinalScore();
    if (score > _bestScore) {
      await prefs.setInt('best_score', score);
      _bestScore = score;
    }
  }

  void _restart() {
    setState(() {
      _savedScore = false;
      _camY = 0;
      _lastTick = Duration.zero;
      final gs = GameState(cols: _cols);
      gs.init(_assets);
      _state = gs;
    });
  }

  void _exit() {
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // Gesture handling
  Offset? _dragStart;

  void _onPanStart(DragStartDetails d) {
    _dragStart = d.localPosition;
  }

  void _onPanEnd(DragEndDetails d) {
    _dragStart = null;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_dragStart == null || _state == null) return;
    final delta = d.localPosition - _dragStart!;
    const threshold = 24.0;
    if (delta.distance < threshold) return;
    // Dominant axis.
    if (delta.dx.abs() > delta.dy.abs()) {
      if (delta.dx > 0) {
        _state!.tryMove(1, 0, _assets);
      } else {
        _state!.tryMove(-1, 0, _assets);
      }
    } else {
      if (delta.dy < 0) {
        _state!.tryMove(0, 1, _assets); // swipe up = forward
      } else {
        _state!.tryMove(0, -1, _assets); // swipe down = backward
      }
    }
    _dragStart = null;
  }

  void _onTap(TapUpDetails d) {
    if (_state == null) return;
    final size = context.size;
    if (size == null) return;
    final pos = d.localPosition;
    // Divide screen in tap zones.
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h / 2;
    final dx = pos.dx - cx;
    final dy = pos.dy - cy;
    if (dx.abs() > dy.abs()) {
      _state!.tryMove(dx > 0 ? 1 : -1, 0, _assets);
    } else {
      _state!.tryMove(0, dy < 0 ? 1 : -1, _assets);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _state == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFFFCC33),
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF7BC24A),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cellSize = constraints.maxWidth / _cols;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            onTapUp: _onTap,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: GamePainter(
                      state: _state!,
                      assets: _assets,
                      cellSize: cellSize,
                      camY: _camY,
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  top: MediaQuery.of(context).padding.top + 8,
                  child: _CircleBtn(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: _exit,
                  ),
                ),
                if (_state!.gameOver)
                  Positioned.fill(
                    child: _GameOverPanel(
                      distance: _state!.maxRowReached,
                      multiplier: _state!.multiplier,
                      score: _state!.computeFinalScore(),
                      best: _bestScore,
                      onRetry: _restart,
                      onMenu: _exit,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC5B3A00),
      shape: const CircleBorder(
        side: BorderSide(color: Colors.white, width: 2.5),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _GameOverPanel extends StatelessWidget {
  const _GameOverPanel({
    required this.distance,
    required this.multiplier,
    required this.score,
    required this.best,
    required this.onRetry,
    required this.onMenu,
  });

  final int distance;
  final double multiplier;
  final int score;
  final int best;
  final VoidCallback onRetry;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0x99000000),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF5B3A00),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'GAME OVER',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 16),
              _statRow('Distance', '$distance'),
              _statRow('Multiplier', 'x${multiplier.toStringAsFixed(2)}'),
              const Divider(color: Colors.white54, height: 24),
              _statRow('Score', '$score', big: true),
              _statRow('Best', '$best'),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _pillBtn(
                      'RETRY',
                      const Color(0xFF43C64F),
                      onRetry,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _pillBtn(
                      'MENU',
                      const Color(0xFF3E82F7),
                      onMenu,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, {bool big = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white70,
              fontSize: big ? 20 : 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: big ? const Color(0xFFFFD84D) : Colors.white,
              fontSize: big ? 30 : 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pillBtn(String label, Color color, VoidCallback onTap) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white, width: 3),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
