import 'analytics_bundle.dart';
import 'endpoint_bundle.dart';
import 'public_pages.dart';

// ============================================================
// AppFacade — one-stop lookup for every runtime constant.
// ============================================================
// Screens and services always read config through this facade, never by
// import from the encoded bundles directly.  That keeps call sites clean
// and makes it trivial to swap a value (e.g. for a QA build) by editing
// a single file.
// ============================================================

class AppFacade {
  AppFacade._();

  // ------ Identity -------------------------------------------------------

  /// Android application id / bundle identifier.  Must match
  /// `applicationId` in android/app/build.gradle.kts.
  static const String bundleId = 'com.hendash.hendash';

  /// Play-Store package id.  Same as [bundleId] on Android.
  static const String storeId = 'com.hendash.hendash';

  /// Display name used in notifications and the User-Agent identity tag.
  static const String appName = 'HenDash';

  /// iOS numeric App Store ID.  Empty on Android-only builds.
  static const String storeAppId = '';

  // ------ Behaviour tuning ----------------------------------------------

  /// How long to sit on the notification promo before we allow it back
  /// (used when the user tapped Skip or system-denied).  3 days.
  static const int notificationRetryDelaySeconds = 3 * 24 * 60 * 60;

  /// Delay between the initial "false-organic" callback and the GCD
  /// retry inside AttributionHub.
  static const int organicRecheckSeconds = 5;

  /// Bailout when the attribution SDK never delivers on first launch.
  static const Duration attributionFirstLaunchDeadline = Duration(seconds: 30);

  /// Shorter budget for returning users — the config request is optional
  /// because we already have a saved URL.
  static const Duration attributionReturningDeadline = Duration(seconds: 10);

  /// Deadline for the deep-link callback after `initSdk`.
  static const Duration deepLinkDeadline = Duration(seconds: 5);

  /// Max wait for the backend `/config.php` reply.
  static const Duration gateReplyTimeout = Duration(seconds: 15);

  // ------ Resolved endpoints --------------------------------------------

  static String get gateEndpoint      => resolveGateEndpoint();
  static String get attributionKey    => resolveAttributionKey();
  static String get messagingProject  => resolveMessagingProject();

  static const String privacyPolicyUrl = kPrivacyPolicyUrl;
  static const String supportUrl       = kSupportUrl;
  static const String mainSiteUrl      = kMainSiteUrl;
}
