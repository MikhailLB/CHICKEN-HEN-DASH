import 'package:clarity_flutter/clarity_flutter.dart';

import '../env/insight_env.dart';

// ============================================================
// Insight — crash-safe facade over Microsoft Clarity.
// ============================================================
// Session replay captures the native Flutter surface (loading screen,
// push-invite screen, the game, and the WebView container).  The DOM
// inside the WebView is NOT recorded; the funnel there is reconstructed
// from custom events emitted by the injected JS probe.  These calls add
// the funnel signals that answer "where did the user drop off?".
//
// Every call is guarded so a Clarity failure can never crash the gray
// flow.  Never call the Clarity SDK directly — always go through
// [Insight].
// ============================================================

class Insight {
  const Insight._();

  static ClarityConfig get config => ClarityConfig(
        projectId: kClarityProjectId,
        // Verbose while wiring a new project, LogLevel.None for release.
        logLevel: LogLevel.None,
      );

  /// Group the session by AppsFlyer id + attach attribution tags.
  /// No-op on empty id so a missing af_id never wipes a good user id
  /// that was already set earlier in the session.
  static void identify(String? aid, {Map<String, String> tags = const {}}) {
    if (aid != null && aid.isNotEmpty) {
      _guard(() => Clarity.setCustomUserId(_clip(aid, 255)));
      tag('aid', aid);
    }
    tags.forEach(tag);
  }

  /// Native screen: sets the label AND emits a stable per-screen event.
  static void screen(String name) {
    screenName(name);
    event('screen_$name');
  }

  /// Sets the current screen label + mirrors it into the persistent
  /// `last_screen` tag (Clarity keeps the LAST tag value per session,
  /// so filtering by last_screen instantly shows the drop-off screen).
  static void screenName(String name) => _guard(() {
        Clarity.setCurrentScreenName(_clip(name, 255));
        Clarity.setCustomTag('last_screen', _clip(name, 255));
      });

  static void event(String name) =>
      _guard(() => Clarity.sendCustomEvent(_clip(name, 254)));

  static void tag(String key, String value) {
    if (value.isEmpty) return;
    _guard(() => Clarity.setCustomTag(key, _clip(value, 255)));
  }

  static String _clip(String v, int max) =>
      v.length <= max ? v : v.substring(0, max);

  static void _guard(void Function() body) {
    try {
      body();
    } catch (_) {}
  }
}
