import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/run_mode.dart';

// ============================================================
// PrefsVault — persistent state for the gray flow.
// ============================================================
// Two backing stores are used on purpose:
//   * SharedPreferences for tiny booleans/ints/labels (no crypto tax).
//   * FlutterSecureStorage for the actual URLs — they live in the
//     Android EncryptedSharedPreferences file so a rooted user cannot
//     easily surface them.
//
// Every "compound" question the flow ever asks (e.g. "should the push
// promo appear right now?") is answered here rather than in the calling
// screen — keeps flow code tight.
// ============================================================

class PrefsVault {
  // Non-sensitive keys (SharedPreferences)
  static const _kMode              = 'hd_run_mode';
  static const _kUrlExpiresAt      = 'hd_url_expires_at';
  static const _kPushSkipUntil     = 'hd_push_skip_until';
  static const _kPushGranted       = 'hd_push_granted';
  static const _kPushOsDenied      = 'hd_push_os_denied';
  static const _kBestScoreCarryOver = 'hd_carry_best_score';

  // Sensitive keys (FlutterSecureStorage)
  static const _kSavedGateUrl      = 'hd_saved_gate_url';
  static const _kPushDeepLinkUrl   = 'hd_push_url';

  late final SharedPreferences _prefs;
  final FlutterSecureStorage _sealed = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      // EncryptedSharedPreferences is deprecated in v10+, existing data
      // is migrated to custom ciphers automatically.  We just keep the
      // reset-on-error safety net.
      resetOnError: true,
    ),
  );

  Future<void> boot() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // -------- Run mode -----------------------------------------------------

  RunMode get mode => RunMode.fromLabel(_prefs.getString(_kMode));

  Future<void> setMode(RunMode mode) =>
      _prefs.setString(_kMode, mode.label);

  // -------- Backend URL cache -------------------------------------------

  Future<String?> readGateUrl() => _sealed.read(key: _kSavedGateUrl);

  Future<void> writeGateUrl(String url) =>
      _sealed.write(key: _kSavedGateUrl, value: url);

  Future<void> setGateExpiry(int? unixSeconds) async {
    if (unixSeconds == null) {
      await _prefs.remove(_kUrlExpiresAt);
    } else {
      await _prefs.setInt(_kUrlExpiresAt, unixSeconds);
    }
  }

  bool get isGateUrlExpired {
    final expires = _prefs.getInt(_kUrlExpiresAt);
    if (expires == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= expires;
  }

  // -------- Push permission ---------------------------------------------

  bool get pushGranted     => _prefs.getBool(_kPushGranted) ?? false;
  bool get pushOsBlocked   => _prefs.getBool(_kPushOsDenied) ?? false;
  int? get pushSkipUntil   => _prefs.getInt(_kPushSkipUntil);

  Future<void> markPushGranted(bool granted) =>
      _prefs.setBool(_kPushGranted, granted);

  Future<void> markPushOsBlocked() =>
      _prefs.setBool(_kPushOsDenied, true);

  Future<void> deferPushInvite(int untilUnixSeconds) =>
      _prefs.setInt(_kPushSkipUntil, untilUnixSeconds);

  /// True whenever the push promo should be presented.  Encodes every
  /// rule from the guide: skip if already granted, skip if the OS
  /// already told us "no" (dialog will never open again on API 33+),
  /// skip while the "3 day cool-down" is active.
  bool shouldOfferPush() {
    if (pushGranted) return false;
    if (pushOsBlocked) return false;
    final until = pushSkipUntil;
    if (until == null) return true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= until;
  }

  // -------- One-shot push deep link -------------------------------------

  Future<String?> readAndClearPushUrl() async {
    final url = await _sealed.read(key: _kPushDeepLinkUrl);
    if (url != null) await _sealed.delete(key: _kPushDeepLinkUrl);
    return url;
  }

  Future<void> storePushUrl(String url) =>
      _sealed.write(key: _kPushDeepLinkUrl, value: url);

  // -------- Best score bridge -------------------------------------------
  //
  // The white game reads/writes `best_score` via a stand-alone
  // SharedPreferences call in menu_screen.dart / game_screen.dart.  We
  // avoid touching those to keep the game fully independent — this
  // helper just exists so future gray/white bridging can flow through
  // one file rather than sprinkled reads.
  int readBestScoreCarry() => _prefs.getInt(_kBestScoreCarryOver) ?? 0;
  Future<void> writeBestScoreCarry(int v) =>
      _prefs.setInt(_kBestScoreCarryOver, v);
}
