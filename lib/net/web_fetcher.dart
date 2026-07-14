import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;

import '../crypto/xor_pipe.dart';

// ============================================================
// WebFetcher — real-device User-Agent HTTP transport.
// ============================================================
// Every gray-flow HTTP request (config endpoint, GCD retry, notification
// image download, ...) flows through the singleton [webFetcher] client
// so we can stamp a single User-Agent string on all of them.  The same
// string is applied to the WebView via `setUserAgent(...)` in
// portal_stage.dart — traffic must look consistent to the backend.
//
// The UA carries no app identifiers — the bundle id / app name travel
// exclusively in the POST body of the config request so the WebView
// contents never expose them to the rendered page.  The Chrome /
// WebKit fragments are XOR-encoded so they don't stand out in
// `strings ...apk`.
// ============================================================

class WebFetcher extends http.BaseClient {
  final http.Client _underlying = http.Client();

  /// Fallback UA — used until [warm] returns.  Deliberately generic so
  /// initial config requests don't fingerprint this app as "cold start".
  String _stampedAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/132.0.6834.163 Mobile Safari/537.36';

  bool _warmed = false;

  /// Populate [userAgent] with a real device signature.  Called once
  /// during app boot; failures fall back to the fallback UA.
  Future<void> warm() async {
    if (_warmed) return;
    _warmed = true;

    final chromeVersion = _decodedChromeVersion();
    final webkitVersion = _decodedWebkitVersion();

    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        // Chrome's real UA carries the marketing release ("16"), NOT
        // the API level ("36").  Using sdkInt here made the WebView
        // masquerade as an impossible "Android 36" build, which sticks
        // out in anti-fraud fingerprints.
        final release = _sanitize(info.version.release);
        final osVersion =
            release.isEmpty ? '${info.version.sdkInt}' : release;
        final model = _sanitize(info.model);
        final brand = _sanitize(info.brand);
        final build = info.display.isNotEmpty
            ? _sanitize(info.display)
            : _sanitize(info.id);
        _stampedAgent =
            'Mozilla/5.0 (Linux; Android $osVersion; $brand $model Build/$build) '
            'AppleWebKit/$webkitVersion (KHTML, like Gecko) '
            'Chrome/$chromeVersion Mobile Safari/$webkitVersion';
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        final ver = info.systemVersion.replaceAll('.', '_');
        _stampedAgent =
            'Mozilla/5.0 (iPhone; CPU iPhone OS $ver like Mac OS X) '
            'AppleWebKit/$webkitVersion (KHTML, like Gecko) '
            'Version/${info.systemVersion} Mobile/15E148 '
            'Safari/$webkitVersion';
      }
    } catch (_) {
      // Keep fallback UA.
    }
  }

  String get userAgent => _stampedAgent;

  String _sanitize(String value) {
    // Strip characters that would break the UA parser on the backend.
    return value.replaceAll(RegExp(r'[\r\n\t]'), '').trim();
  }

  String _decodedChromeVersion() {
    const v = <int>[
      0xb9, 0x51, 0xbc, 0xcd, 0x21, 0x58, 0xc7, 0xf7, 0xce, 0x3b, 0xf9, 0xd1,
      0x6a, 0x0a,
    ];
    final s = unwind(v);
    return s.isEmpty ? '132.0.6834.163' : s;
  }

  String _decodedWebkitVersion() {
    const v = <int>[
      0xbd, 0x51, 0xc1, 0xcd, 0x24, 0x60,
    ];
    final s = unwind(v);
    return s.isEmpty ? '537.36' : s;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.putIfAbsent('User-Agent', () => userAgent);
    return _underlying.send(request);
  }

  @override
  void close() => _underlying.close();
}

/// Shared instance — call [WebFetcher.warm] once during main().
final WebFetcher webFetcher = WebFetcher();
