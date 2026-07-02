import 'package:flutter/material.dart';

import '../core/app_facade.dart';
import '../net/net_sensor.dart';
import '../net/push_courier.dart';
import '../vault/prefs_vault.dart';
import 'portal_stage.dart' deferred as portal;

// ============================================================
// PushInvitePage — pre-Portal promo for notification permission.
// ============================================================
// Visuals:
//   * Full-bleed artwork from assets/notif/ (vertical / horizontal).
//   * Two flat "coin" buttons at the bottom — big Accept, thinner Skip.
//   * NO golden glow gradient (the template uses one; this design is
//     rounded-white "coins" over the illustration, deliberately
//     distinct so the button hierarchy doesn't fingerprint match).
//
// Behaviour:
//   * Accept   -> asks the OS.  On decline we still record a 3-day
//                 skip so we don't nag the user immediately.
//   * Skip     -> record 3-day skip.
//   * Both flows always continue to PortalStage with the URL that
//     brought us here.
// ============================================================

class PushInvitePage extends StatefulWidget {
  const PushInvitePage({
    super.key,
    required this.vault,
    required this.courier,
    required this.netSensor,
    required this.contentUrl,
  });

  final PrefsVault vault;
  final PushCourier courier;
  final NetSensor netSensor;
  final String contentUrl;

  @override
  State<PushInvitePage> createState() => _PushInvitePageState();
}

class _PushInvitePageState extends State<PushInvitePage> {
  bool _busy = false;

  Future<void> _stashSkipDeadline() async {
    final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        AppFacade.notificationRetryDelaySeconds;
    await widget.vault.deferPushInvite(until);
  }

  Future<void> _accept() async {
    if (_busy) return;
    setState(() => _busy = true);
    final granted = await widget.courier.askPermission();
    if (!granted) await _stashSkipDeadline();
    if (!mounted) return;
    _openPortal();
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _stashSkipDeadline();
    if (!mounted) return;
    _openPortal();
  }

  Future<void> _openPortal() async {
    await portal.loadLibrary();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => portal.PortalStage(
          initialUrl: widget.contentUrl,
          vault: widget.vault,
          courier: widget.courier,
          netSensor: widget.netSensor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0E17),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          final backdrop = isLandscape
              ? 'assets/notif/notify_hor.webp'
              : 'assets/notif/notify_vert.webp';

          return Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                backdrop,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
              // Bottom gradient so the buttons never lose contrast.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.55, 1.0],
                    colors: [Color(0x00000000), Color(0xC0000000)],
                  ),
                ),
              ),

              _buttonsLayer(constraints, isLandscape),
            ],
          );
        },
      ),
    );
  }

  Widget _buttonsLayer(BoxConstraints constraints, bool isLandscape) {
    final width = constraints.maxWidth;
    final height = constraints.maxHeight;

    final acceptWidth =
        isLandscape ? width * 0.42 : width * 0.78;
    final skipWidth = acceptWidth * 0.62;

    return Positioned(
      left: 0,
      right: 0,
      bottom: height * (isLandscape ? 0.07 : 0.08),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CoinButton(
            label: 'Accept',
            width: acceptWidth,
            height: isLandscape ? 52 : 62,
            primary: true,
            enabled: !_busy,
            onTap: _accept,
          ),
          const SizedBox(height: 14),
          _CoinButton(
            label: 'Skip',
            width: skipWidth,
            height: isLandscape ? 40 : 46,
            primary: false,
            enabled: !_busy,
            onTap: _skip,
          ),
        ],
      ),
    );
  }
}

class _CoinButton extends StatefulWidget {
  const _CoinButton({
    required this.label,
    required this.width,
    required this.height,
    required this.primary,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final double width;
  final double height;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_CoinButton> createState() => _CoinButtonState();
}

class _CoinButtonState extends State<_CoinButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? const [Color(0xFFFFFFFF), Color(0xFFF3D179)]
        : const [Color(0xFFE9E4DA), Color(0xFFB8AC93)];
    final label = widget.primary
        ? const Color(0xFF3B2100)
        : const Color(0xFF20160A);
    final border = widget.primary
        ? const Color(0xFF3B2100)
        : const Color(0xFF20160A);

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: GestureDetector(
        onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: widget.enabled
            ? (_) {
                setState(() => _down = false);
                widget.onTap();
              }
            : null,
        onTapCancel: () => setState(() => _down = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: bg,
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(widget.height / 2),
            border: Border.all(color: border, width: 3),
            boxShadow: _down
                ? const []
                : const [
                    BoxShadow(
                      color: Color(0x8A000000),
                      blurRadius: 10,
                      offset: Offset(0, 5),
                    ),
                  ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                color: label,
                fontWeight: FontWeight.w900,
                fontSize: widget.primary ? 22 : 18,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
