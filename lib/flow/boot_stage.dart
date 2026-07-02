import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/run_mode.dart';
import '../net/attribution_hub.dart';
import '../net/backend_gate.dart';
import '../net/net_sensor.dart';
import '../net/push_courier.dart';
import '../vault/prefs_vault.dart';
import '../screens/menu_screen.dart';
import 'offline_notice_page.dart';
import 'push_invite_page.dart';
import 'portal_stage.dart' deferred as portal;

// ============================================================
// BootStage — first screen the user sees; decides gray/white.
// ============================================================
// The visual side keeps the HenDash yellow loading art (loading_vert.png
// / loading_hor.png) with the horizontal progress bar the user already
// approved.  The behavioural side runs the gray-flow state machine:
//
//   RunMode.fresh
//     · If we're offline → OfflineNoticePage.
//     · Ignite AttributionHub, wait for attribution + deep-link, POST
//       to /config.php.
//     · ok+url  → RunMode.webview → PushInvitePage (or PortalStage).
//     · otherwise → RunMode.game → MenuScreen.
//
//   RunMode.webview
//     · Push URL in the vault takes precedence — open PortalStage.
//     · Otherwise ignite AttributionHub, refresh, then PortalStage.
//     · Fall back to saved URL on network failure.
//
//   RunMode.game
//     · Skip the whole gray-flow.  Straight into MenuScreen.
//
// The loading UI is intentionally a *progress bar* (not a video) so
// this build renders identically on devices that can't decode webm/mp4.
// ============================================================

class BootStage extends StatefulWidget {
  const BootStage({
    super.key,
    required this.vault,
    required this.netSensor,
    required this.attributionHub,
    required this.backendGate,
    required this.pushCourier,
  });

  final PrefsVault vault;
  final NetSensor netSensor;
  final AttributionHub attributionHub;
  final BackendGate backendGate;
  final PushCourier pushCourier;

  @override
  State<BootStage> createState() => _BootStageState();
}

class _BootStageState extends State<BootStage> with TickerProviderStateMixin {
  late final AnimationController _dotsCtrl;
  late final AnimationController _pulseCtrl;

  double _progress = 0.0;
  Timer? _slowTicker;
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();

    // Allow both orientations on the boot screen — the artwork ships in
    // vertical and horizontal variants.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _dotsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pumpProgress(target: 0.35, over: const Duration(milliseconds: 900));
    _routeAfterBoot();
  }

  // -------- Progress bar helpers ---------------------------------------

  void _pumpProgress({required double target, required Duration over}) {
    _slowTicker?.cancel();
    final t = target.clamp(0.0, 1.0);
    if (t <= _progress) return;
    final start = _progress;
    final delta = t - start;
    final steps = 24;
    final tick = Duration(
      milliseconds: (over.inMilliseconds / steps).ceil(),
    );
    var i = 0;
    _slowTicker = Timer.periodic(tick, (timer) {
      i++;
      if (!mounted) {
        timer.cancel();
        return;
      }
      final v = start + delta * (i / steps);
      setState(() => _progress = v.clamp(0.0, 1.0));
      if (i >= steps) timer.cancel();
    });
  }

  Future<void> _finishProgress() async {
    _slowTicker?.cancel();
    const dur = Duration(milliseconds: 300);
    final start = _progress;
    final delta = 1.0 - start;
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(dur ~/ steps);
      if (!mounted) return;
      setState(() => _progress = (start + delta * (i / steps)).clamp(0.0, 1.0));
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
  }

  // -------- Routing -----------------------------------------------------

  Future<void> _routeAfterBoot() async {
    // Wire push courier + token rotation callback FIRST so late
    // callbacks fired while attribution is still running still land.
    widget.pushCourier.onTokenRotated = _onTokenRotated;
    await widget.pushCourier.wire().catchError((_) {});

    switch (widget.vault.mode) {
      case RunMode.game:
        _pumpProgress(target: 0.9, over: const Duration(milliseconds: 500));
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await _finishProgress();
        _handOffToGame();
        return;

      case RunMode.webview:
        await _routeReturningOnline();
        return;

      case RunMode.fresh:
        await _routeFirstLaunch();
        return;
    }
  }

  Future<void> _routeFirstLaunch() async {
    final online = await widget.netSensor.isOnline();
    if (!online) {
      _handOffOffline();
      return;
    }
    _pumpProgress(target: 0.55, over: const Duration(milliseconds: 700));

    await widget.attributionHub.ignite();
    await Future.wait([
      widget.attributionHub.awaitAttribution(),
      widget.attributionHub.awaitDeepLink(),
    ]);

    _pumpProgress(target: 0.8, over: const Duration(milliseconds: 400));

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);

    if (reply.ok && reply.hasUrl) {
      await widget.vault.setMode(RunMode.webview);
      await _finishProgress();
      _handOffToPortal(reply.url!);
    } else {
      await widget.vault.setMode(RunMode.game);
      await _finishProgress();
      _handOffToGame();
    }
  }

  Future<void> _routeReturningOnline() async {
    final online = await widget.netSensor.isOnline();

    // 1. Push URL wins over everything.
    final pushUrl = await widget.vault.readAndClearPushUrl();
    if (pushUrl != null && pushUrl.isNotEmpty) {
      await _finishProgress();
      _handOffToPortal(pushUrl);
      return;
    }

    if (!online) {
      final cached = await widget.backendGate.cachedUrl();
      if (cached != null && cached.isNotEmpty) {
        // Still show offline first — if the WebView starts on a dead
        // network it will crash into the black error page.
        _handOffOffline();
      } else {
        _handOffOffline();
      }
      return;
    }

    _pumpProgress(target: 0.55, over: const Duration(milliseconds: 600));

    await widget.attributionHub.ignite();
    await Future.wait([
      widget.attributionHub
          .awaitAttribution(deadline: const Duration(seconds: 10)),
      widget.attributionHub.awaitDeepLink(),
    ]);

    _pumpProgress(target: 0.85, over: const Duration(milliseconds: 400));

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);

    await _finishProgress();

    if (reply.ok && reply.hasUrl) {
      _handOffToPortal(reply.url!);
      return;
    }
    final cached = await widget.backendGate.cachedUrl();
    if (cached != null && cached.isNotEmpty) {
      _handOffToPortal(cached);
    } else {
      _handOffOffline();
    }
  }

  Future<void> _onTokenRotated(String newToken) async {
    // Re-negotiate the backend so the freshly minted token reaches it.
    try {
      final locale = Platform.localeName.replaceAll('-', '_');
      final body = await widget.attributionHub.assembleBody(
        locale: locale,
        pushToken: newToken,
      );
      await widget.backendGate.negotiate(body);
    } catch (_) {}
  }

  // -------- Handoffs ----------------------------------------------------

  void _handOffToGame() {
    if (_handedOff || !mounted) return;
    _handedOff = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 350),
        pageBuilder: (_, _, _) => const MenuScreen(),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  Future<void> _handOffToPortal(String url) async {
    if (_handedOff || !mounted) return;
    _handedOff = true;
    await portal.loadLibrary();
    await portal.primePortalEngine();
    if (!mounted) return;

    if (widget.vault.shouldOfferPush()) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PushInvitePage(
            vault: widget.vault,
            courier: widget.pushCourier,
            netSensor: widget.netSensor,
            contentUrl: url,
          ),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => portal.PortalStage(
            initialUrl: url,
            vault: widget.vault,
            courier: widget.pushCourier,
            netSensor: widget.netSensor,
          ),
        ),
      );
    }
  }

  void _handOffOffline() {
    if (_handedOff || !mounted) return;
    _handedOff = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OfflineNoticePage(
          retryBuilder: (_) => BootStage(
            vault: widget.vault,
            netSensor: widget.netSensor,
            attributionHub: widget.attributionHub,
            backendGate: widget.backendGate,
            pushCourier: widget.pushCourier,
          ),
        ),
      ),
    );
  }

  // -------- Lifecycle ---------------------------------------------------

  @override
  void dispose() {
    _slowTicker?.cancel();
    _dotsCtrl.dispose();
    _pulseCtrl.dispose();
    widget.pushCourier.onTokenRotated = null;
    super.dispose();
  }

  // -------- Rendering ---------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFCC33),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isPortrait = constraints.maxHeight >= constraints.maxWidth;
          final backdrop = isPortrait
              ? 'assets/loading_vert.png'
              : 'assets/loading_hor.png';
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                backdrop,
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
                    _AnimatedDots(controller: _dotsCtrl),
                    const SizedBox(height: 16),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: constraints.maxWidth * 0.12,
                      ),
                      child: _RibbonProgress(
                        progress: _progress,
                        pulse: _pulseCtrl,
                      ),
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

class _AnimatedDots extends StatelessWidget {
  const _AnimatedDots({required this.controller});
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final phase = (controller.value * 4).floor() % 4;
        final dots = '.' * phase;
        return Text(
          'Loading$dots',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 1.4,
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

class _RibbonProgress extends StatelessWidget {
  const _RibbonProgress({required this.progress, required this.pulse});
  final double progress;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, _) {
        final glow = 0.35 + pulse.value * 0.35;
        return Container(
          height: 24,
          decoration: BoxDecoration(
            color: const Color(0xFF3B2100),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF9900).withValues(alpha: glow),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
              const BoxShadow(
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
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFFFFEA7A), Color(0xFFFF8A00)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
