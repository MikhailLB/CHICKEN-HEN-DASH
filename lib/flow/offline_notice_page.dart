import 'package:flutter/material.dart';

// ============================================================
// OfflineNoticePage — full-bleed "no internet" screen.
// ============================================================
// The background is the artist-supplied "no wifi" illustration; we
// swap between the vertical / horizontal variant on orientation change
// and paint a single "Retry" pill over it.  The button hits
// [retryBuilder] which rebuilds whichever screen was in trouble
// (BootStage or PortalStage).
// ============================================================

class OfflineNoticePage extends StatefulWidget {
  const OfflineNoticePage({super.key, required this.retryBuilder});

  final WidgetBuilder retryBuilder;

  @override
  State<OfflineNoticePage> createState() => _OfflineNoticePageState();
}

class _OfflineNoticePageState extends State<OfflineNoticePage>
    with TickerProviderStateMixin {
  late final AnimationController _pressCtrl;
  bool _reconnecting = false;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      lowerBound: 0.94,
      upperBound: 1.0,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  Future<void> _onRetry() async {
    if (_reconnecting) return;
    await _pressCtrl.reverse();
    await _pressCtrl.forward();
    setState(() => _reconnecting = true);
    // Small delay so the spinner isn't a single frame flash.
    await Future<void>.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: widget.retryBuilder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14161C),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          final backdrop = isLandscape
              ? 'assets/nowifi/nowifi_hor.webp'
              : 'assets/nowifi/nowifi_vert.webp';
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                backdrop,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
              // Soft vignette so the button stays readable regardless of art.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x88000000),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: constraints.maxHeight *
                    (isLandscape ? 0.10 : 0.09),
                child: ScaleTransition(
                  scale: _pressCtrl,
                  child: _RetryPill(
                    busy: _reconnecting,
                    onTap: _onRetry,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RetryPill extends StatelessWidget {
  const _RetryPill({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: busy ? null : onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: const LinearGradient(
                colors: [Color(0xFFFFEA7A), Color(0xFFFFBB1E)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF4B2A00),
                        ),
                      ),
                    )
                  : const Text(
                      'TRY AGAIN',
                      style: TextStyle(
                        color: Color(0xFF3B2100),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
