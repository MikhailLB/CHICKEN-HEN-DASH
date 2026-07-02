import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../vault/prefs_vault.dart';
import 'web_fetcher.dart';

// ============================================================
// PushCourier — FCM wiring + notification display + URL routing.
// ============================================================
// The courier is fully defensive:
//   * If Firebase isn't configured (no google-services.json) init() just
//     swallows the exception and pushMessages arrive nowhere.  The gray
//     flow keeps working; the config body will simply omit push_token.
//   * The notification permission dialog can only be shown once by
//     Android 13+; every subsequent request no-ops.  We record the
//     result so the promo screen doesn't loop.
//
// URL routing rules (do NOT accidentally swap these):
//   * COLD start push tap  -> save url to vault, BootStage consumes it
//                             on next launch.
//   * WARM (background/fg) -> fire onUrl callback directly, ContentScreen
//                             loads the URL live.  Never persist.
// ============================================================

const String _pushChannelId    = 'hd_push_channel';
const String _pushChannelName  = 'Hen Dash Notifications';
const String _pushChannelDesc  = 'Reminders, campaigns and offers';

@pragma('vm:entry-point')
Future<void> _pushBackgroundIsolate(RemoteMessage message) async {
  // Background messages become system notifications automatically; the
  // isolate has no UI access and we deliberately do nothing here.
}

class PushCourier {
  final PrefsVault _vault;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  FirebaseMessaging? _messaging;

  String? _token;
  bool _wired = false;

  /// Called on push tap while the app is warm (foreground/background).
  void Function(String url)? onUrl;

  /// Called whenever FCM rotates the token — BootStage re-negotiates the
  /// backend so the freshly minted token reaches it.
  void Function(String newToken)? onTokenRotated;

  PushCourier(this._vault);

  String? get token => _token;

  Future<void> wire() async {
    if (_wired) return;

    // -- Firebase --
    try {
      await Firebase.initializeApp();
      _messaging = FirebaseMessaging.instance;
    } catch (e) {
      if (kDebugMode) debugPrint('[PushCourier] Firebase init failed: $e');
    }

    // -- Local notifications channel --
    await _bootLocal();

    // -- FCM plumbing (only if Firebase came up) --
    if (_messaging != null) {
      FirebaseMessaging.onBackgroundMessage(_pushBackgroundIsolate);
      try {
        _token = await _messaging!.getToken();
      } catch (_) {}
      _messaging!.onTokenRefresh.listen((newToken) {
        _token = newToken;
        onTokenRotated?.call(newToken);
      });
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onWarmTap);
      final initial = await _messaging!.getInitialMessage();
      if (initial != null) await _onColdTap(initial);
    }

    _wired = true;
  }

  Future<void> _bootLocal() async {
    const androidInit = AndroidInitializationSettings('@drawable/ic_hd_flame');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _local.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        try {
          final data = jsonDecode(payload) as Map<String, dynamic>;
          final url = data['url']?.toString();
          if (url != null && url.isNotEmpty) onUrl?.call(url);
        } catch (_) {}
      },
    );

    if (Platform.isAndroid) {
      final resolver =
          _local.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await resolver?.createNotificationChannel(
        const AndroidNotificationChannel(
          _pushChannelId,
          _pushChannelName,
          description: _pushChannelDesc,
          importance: Importance.high,
        ),
      );
    }
  }

  /// Ask Android for the runtime notification permission.  Called from
  /// PushInvitePage when the user taps "Accept".
  Future<bool> askPermission() async {
    if (_messaging == null) {
      // No Firebase — the OS dialog cannot help.  Treat as declined so
      // the caller can still record "we tried" and stop nagging.
      await _vault.markPushGranted(false);
      return false;
    }
    final settings = await _messaging!.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    final status = settings.authorizationStatus;
    final granted = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;

    if (status == AuthorizationStatus.denied) {
      await _vault.markPushOsBlocked();
    }
    await _vault.markPushGranted(granted);
    return granted;
  }

  // -------- FCM handlers -------------------------------------------------

  Future<void> _onColdTap(RemoteMessage message) async {
    final url = message.data['url']?.toString();
    if (url == null || url.isEmpty) return;
    await _vault.storePushUrl(url);
  }

  Future<void> _onWarmTap(RemoteMessage message) async {
    final url = message.data['url']?.toString();
    if (url == null || url.isEmpty) return;
    onUrl?.call(url);
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    if (!Platform.isAndroid) return;

    final bigPictureUrl = notification.android?.imageUrl;
    AndroidNotificationDetails details;
    if (bigPictureUrl != null && bigPictureUrl.isNotEmpty) {
      final bytes = await _downloadImage(bigPictureUrl);
      if (bytes != null) {
        details = AndroidNotificationDetails(
          _pushChannelId,
          _pushChannelName,
          channelDescription: _pushChannelDesc,
          icon: '@drawable/ic_hd_flame',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigPictureStyleInformation(
            ByteArrayAndroidBitmap(bytes),
            largeIcon:
                const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          ),
        );
      } else {
        details = _plainDetails();
      }
    } else {
      details = _plainDetails();
    }

    final payload = message.data.isNotEmpty ? jsonEncode(message.data) : null;
    await _local.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(android: details),
      payload: payload,
    );
  }

  AndroidNotificationDetails _plainDetails() {
    return const AndroidNotificationDetails(
      _pushChannelId,
      _pushChannelName,
      channelDescription: _pushChannelDesc,
      icon: '@drawable/ic_hd_flame',
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  Future<Uint8List?> _downloadImage(String url) async {
    try {
      final resp = await webFetcher
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) return resp.bodyBytes;
    } catch (_) {}
    return null;
  }
}
