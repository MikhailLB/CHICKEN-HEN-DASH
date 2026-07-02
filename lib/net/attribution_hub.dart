import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart';
import 'package:flutter/foundation.dart';

import '../core/analytics_bundle.dart';
import '../core/app_facade.dart';
import 'web_fetcher.dart';

// ============================================================
// AttributionHub — AppsFlyer wrapper + false-organic recovery.
// ============================================================
// The hub does three things:
//
//   1. Initialise the AppsFlyer SDK, register all three callbacks
//      (install conversion, app-open attribution, deep link).
//
//   2. Recover from AppsFlyer's known "organic on first callback" bug:
//      whenever the first payload comes back with af_status=="Organic"
//      we wait a few seconds and then hit the GCD REST endpoint
//      directly; the answer from GCD supersedes the callback data.
//
//   3. Fold everything into a single POST body that the backend expects
//      — the attribution fields, deep link fields, app-open fields,
//      followed by the device fields.  Deep link fields never overwrite
//      attribution fields (putIfAbsent semantics), attribution fields
//      always win.
// ============================================================

class AttributionHub {
  AppsflyerSdk? _sdk;

  Map<String, dynamic>? _installConversion;
  Map<String, dynamic>? _appOpenPayload;
  Map<String, dynamic>? _deepLinkPayload;

  final Completer<Map<String, dynamic>> _installCompleter = Completer();
  final Completer<void> _deepLinkCompleter = Completer();
  bool _sdkStarted = false;

  /// Set up all SDK callbacks and start the SDK.  Safe to call multiple
  /// times — subsequent calls are ignored.
  Future<void> ignite() async {
    if (_sdkStarted) return;
    _sdkStarted = true;

    final devKey = AppFacade.attributionKey;
    if (devKey.isEmpty) {
      // No AppsFlyer credentials yet.  Complete the futures with empty
      // payloads so the flow does not hang.
      _completeInstallOnce(<String, dynamic>{});
      _completeDeepLinkOnce();
      return;
    }

    try {
      _sdk = AppsflyerSdk(AppsFlyerOptions(
        afDevKey: devKey,
        appId: AppFacade.storeAppId,
        showDebug: kDebugMode,
        timeToWaitForATTUserAuthorization: 10,
      ));

      _sdk!.onInstallConversionData(_onInstallConversion);
      _sdk!.onAppOpenAttribution(_onAppOpenAttribution);
      _sdk!.onDeepLinking(_onDeepLink);

      await _sdk!.initSdk(
        registerConversionDataCallback: true,
        registerOnAppOpenAttributionCallback: true,
        registerOnDeepLinkingCallback: true,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[AttributionHub] initSdk failed: $e');
      _completeInstallOnce(<String, dynamic>{});
      _completeDeepLinkOnce();
    }
  }

  // -------- Callbacks ----------------------------------------------------

  Future<void> _onInstallConversion(Object? data) async {
    final payload = _extractPayload(data);
    if (payload.isEmpty) {
      _completeInstallOnce(<String, dynamic>{});
      return;
    }

    if ((payload['af_status']?.toString() ?? '').toLowerCase() == 'organic') {
      // False-organic recovery.
      await Future<void>.delayed(
        Duration(seconds: AppFacade.organicRecheckSeconds),
      );
      final rescued = await _requestGcd();
      _installConversion = rescued ?? payload;
    } else {
      _installConversion = payload;
    }
    _completeInstallOnce(_installConversion ?? <String, dynamic>{});
  }

  Future<void> _onAppOpenAttribution(Object? data) async {
    _appOpenPayload = _extractPayload(data);
  }

  Future<void> _onDeepLink(DeepLinkResult result) async {
    try {
      final click = result.deepLink?.clickEvent;
      if (click != null) {
        _deepLinkPayload = Map<String, dynamic>.from(click);
      }
    } catch (_) {}
    _completeDeepLinkOnce();
  }

  Map<String, dynamic> _extractPayload(Object? data) {
    if (data is Map) {
      final inner = data['payload'];
      if (inner is Map) return Map<String, dynamic>.from(inner);
      return Map<String, dynamic>.from(data);
    }
    return const <String, dynamic>{};
  }

  void _completeInstallOnce(Map<String, dynamic> payload) {
    if (!_installCompleter.isCompleted) {
      _installCompleter.complete(payload);
    }
  }

  void _completeDeepLinkOnce() {
    if (!_deepLinkCompleter.isCompleted) {
      _deepLinkCompleter.complete();
    }
  }

  // -------- Public accessors --------------------------------------------

  Future<Map<String, dynamic>> awaitAttribution({Duration? deadline}) {
    final d = deadline ?? AppFacade.attributionFirstLaunchDeadline;
    return _installCompleter.future
        .timeout(d, onTimeout: () => <String, dynamic>{});
  }

  Future<void> awaitDeepLink({Duration? deadline}) {
    final d = deadline ?? AppFacade.deepLinkDeadline;
    return _deepLinkCompleter.future.timeout(d, onTimeout: () {});
  }

  Future<String?> installId() async {
    if (_sdk == null) return null;
    try {
      return await _sdk!.getAppsFlyerUID();
    } catch (_) {
      return null;
    }
  }

  // -------- GCD recovery ------------------------------------------------

  Future<Map<String, dynamic>?> _requestGcd() async {
    final devKey = AppFacade.attributionKey;
    if (devKey.isEmpty) return null;
    final uid = await installId();
    if (uid == null || uid.isEmpty) return null;

    final appId = Platform.isIOS ? AppFacade.storeAppId : AppFacade.bundleId;
    final url = resolveGcdEndpoint(appId: appId, deviceId: uid);
    if (url.isEmpty) return null;

    try {
      final resp = await webFetcher
          .get(
            Uri.parse(url),
            headers: {'authorization': 'Bearer $devKey'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200 && resp.body.isNotEmpty) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  // -------- Body assembly -----------------------------------------------

  /// Composes the merged POST body that goes to `/config.php`.
  ///
  /// Ordering (per the backend contract):
  ///   1. All raw AppsFlyer install-conversion fields.
  ///   2. Deep link fields (only when not already set by step 1).
  ///   3. App-open attribution fields (also putIfAbsent).
  ///   4. Fixed device fields (always overwrite).
  Future<Map<String, dynamic>> assembleBody({
    required String locale,
    String? pushToken,
  }) async {
    final body = <String, dynamic>{};

    if (_installConversion != null) {
      body.addAll(_installConversion!);
    }
    _deepLinkPayload?.forEach((k, v) => body.putIfAbsent(k, () => v));
    _appOpenPayload?.forEach((k, v) => body.putIfAbsent(k, () => v));

    body['af_id']     = (await installId()) ?? '';
    body['bundle_id'] = AppFacade.bundleId;
    body['os']        = Platform.isAndroid ? 'Android' : 'iOS';
    body['store_id']  = AppFacade.storeId;
    body['locale']    = locale;
    if (pushToken != null && pushToken.isNotEmpty) {
      body['push_token'] = pushToken;
    }
    if (AppFacade.messagingProject.isNotEmpty) {
      body['firebase_project_id'] = AppFacade.messagingProject;
    }

    if (kDebugMode) {
      debugPrint('[AttributionHub] body: ${jsonEncode(body)}');
    }
    return body;
  }
}
