import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../net/net_sensor.dart';
import '../net/push_courier.dart';
import '../net/web_fetcher.dart';
import '../vault/prefs_vault.dart';
import 'offline_notice_page.dart';

// ============================================================
// PortalStage — the gray-mode WebView shell.
// ============================================================
// Everything about this screen is defensive; the WebView must not
// leak the native error page, must never exit the app on back-press,
// and must silently swallow the affiliate networks' redirect chains.
//
// The JavaScript payloads (safe-area killer + keyboard scroll fix) are
// deliberately written in a different style from other in-house builds
// — variable names, control flow and CSS selectors intentionally
// diverge so the built binary does not hash-match sibling apps.
// ============================================================

/// Warmup hook — allows main() to lazy-load this file via deferred
/// import.  Nothing has to happen here yet; the deferred call itself is
/// enough to keep the WebView engine out of the game-mode boot path.
Future<void> primePortalEngine() async {}

class PortalStage extends StatefulWidget {
  const PortalStage({
    super.key,
    required this.initialUrl,
    required this.vault,
    required this.courier,
    required this.netSensor,
  });

  final String initialUrl;
  final PrefsVault vault;
  final PushCourier courier;
  final NetSensor netSensor;

  @override
  State<PortalStage> createState() => _PortalStageState();
}

class _PortalStageState extends State<PortalStage>
    with WidgetsBindingObserver {
  late final WebViewController _view;
  bool _spinning = true;
  bool _routedOffline = false;
  StreamSubscription<bool>? _offlineDebounced;

  String? _lastMainFrame;
  int _redirectRetries = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _applyImmersive();

    _view = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(webFetcher.userAgent)
      ..setBackgroundColor(Colors.black)
      ..enableZoom(false)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _spinning = true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _spinning = false);
          _redirectRetries = 0;
          _stripSiteInsets();
          _wireKeyboardShifter();
        },
        onWebResourceError: _onError,
        onNavigationRequest: _decideNavigation,
        onHttpError: (_) {},
      ));

    _configureAndroidBridge();
    _view.loadRequest(Uri.parse(widget.initialUrl));

    widget.courier.onUrl = (url) {
      if (!mounted) return;
      _view.loadRequest(Uri.parse(url));
    };

    // Debounced offline stream — filters VPN flicker so we don't
    // pop to the offline screen for 700ms of transient "none".
    _offlineDebounced = widget.netSensor.debouncedOfflineStream().listen((_) {
      _slideToOffline();
    });
  }

  void _applyImmersive() {
    // Edge-to-edge (not sticky-immersive) so the system bars remain
    // visible and the platform reports a valid viewPadding.  The
    // WebView is inset by that padding so page content always sits
    // inside the visually safe rectangle — no notches, no gesture bar,
    // no camera cutouts poking into the layout.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _applyImmersive();
  }

  // -------- Android-only WebView tweaks --------------------------------

  void _configureAndroidBridge() {
    if (!Platform.isAndroid) return;
    final platform = _view.platform;
    if (platform is! AndroidWebViewController) return;

    // Autoplay video without requiring a first tap.
    platform.setMediaPlaybackRequiresUserGesture(false);

    // File picker for <input type="file">.
    platform.setOnShowFileSelector(_pickFiles);

    // Third-party cookies — needed by nearly all partner sites.
    final cookies = AndroidWebViewCookieManager(
      AndroidWebViewCookieManagerCreationParams
          .fromPlatformWebViewCookieManagerCreationParams(
        const PlatformWebViewCookieManagerCreationParams(),
      ),
    );
    cookies.setAcceptThirdPartyCookies(platform, true);
  }

  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: params.mode == FileSelectorMode.openMultiple,
        type: FileType.any,
      );
      if (result == null) return const [];
      return result.files
          .where((f) => f.path != null)
          .map((f) => Uri.file(f.path!).toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // -------- Navigation gates --------------------------------------------

  NavigationDecision _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;

    final scheme = uri.scheme.toLowerCase();
    const passThrough = {'http', 'https', 'about', 'data', 'blob'};

    if (passThrough.contains(scheme)) {
      if (request.isMainFrame) _lastMainFrame = request.url;
      return NavigationDecision.navigate;
    }

    // Everything else (intent://, tel://, mailto://, market://, ...)
    // hands off to the OS.
    _openExternally(uri);
    return NavigationDecision.prevent;
  }

  Future<void> _openExternally(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _onError(WebResourceError err) async {
    if (err.isForMainFrame != true) return;

    final blurb = err.description.toLowerCase();

    // 1. Redirect loop — retry the last main-frame URL a few times.
    final looped = err.errorCode == -1007 ||
        err.errorCode == -9 ||
        blurb.contains('too_many_redirects') ||
        blurb.contains('too many redirects');
    if (looped && _lastMainFrame != null && _redirectRetries < 3) {
      _redirectRetries++;
      _view.loadRequest(Uri.parse(_lastMainFrame!));
      return;
    }

    // 2. Instantly cover the WebView so Chrome's built-in error page
    //    isn't visible while we decide what to do.
    if (mounted) setState(() => _spinning = true);

    // 3. DNS / disconnect errors -> straight to offline screen.  These
    //    codes are the ones that pop the black-robot error page.
    final dnsOrDisconnect = err.errorCode == -105 ||
        err.errorCode == -106 ||
        err.errorCode == -21  ||
        blurb.contains('name_not_resolved') ||
        blurb.contains('internet_disconnected') ||
        blurb.contains('network_changed');
    if (dnsOrDisconnect) {
      _slideToOffline();
      return;
    }

    // 4. Anything else: verify with a DNS probe first.
    _verifyThenMaybeOffline();
  }

  Future<void> _verifyThenMaybeOffline() async {
    final online = await widget.netSensor.isOnline();
    if (online || !mounted) return;
    _slideToOffline();
  }

  Future<void> _slideToOffline() async {
    if (_routedOffline || !mounted) return;
    _routedOffline = true;
    final currentUrl = await _view.currentUrl() ?? widget.initialUrl;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => OfflineNoticePage(
          retryBuilder: (_) => PortalStage(
            initialUrl: currentUrl,
            vault: widget.vault,
            courier: widget.courier,
            netSensor: widget.netSensor,
          ),
        ),
      ),
    );
  }

  // -------- JS injections -----------------------------------------------

  /// Neutralises `env(safe-area-inset-*)` on the loaded site so notched
  /// devices don't sport white bars along the top or bottom of the
  /// WebView.  Also re-applies on client-side route changes.
  void _stripSiteInsets() {
    _view.runJavaScript(r'''
(function(){
  if (window.__hdInsetKillActive) return;
  window.__hdInsetKillActive = true;

  var STYLE_ID = 'hd-inset-strip';
  var CSS = [
    ':root{',
      '--safe-area-inset-top:0px!important;',
      '--safe-area-inset-right:0px!important;',
      '--safe-area-inset-bottom:0px!important;',
      '--safe-area-inset-left:0px!important;',
      '--sat:0px!important;--sar:0px!important;',
      '--sab:0px!important;--sal:0px!important;',
      '--safe-top:0px!important;--safe-right:0px!important;',
      '--safe-bottom:0px!important;--safe-left:0px!important;',
    '}',
    'html,body,#app,#root,#__next,#__nuxt,#__layout,',
    '.mobile-header,.app-shell,.viewport-shell{',
      'padding-top:0!important;',
      'padding-left:0!important;',
      'padding-right:0!important;',
      'margin-top:0!important;',
    '}'
  ].join('');

  function keyboardVisible(){
    if (!window.visualViewport) return false;
    return window.visualViewport.height < window.innerHeight * 0.75;
  }

  function patch(){
    if (keyboardVisible()) return;
    var head = document.head || document.documentElement;
    if (!head) return;
    var meta = document.querySelector('meta[name="viewport"]');
    if (meta){
      var content = meta.getAttribute('content') || '';
      if (!/viewport-fit\s*=\s*contain/i.test(content)){
        content = content.replace(/,?\s*viewport-fit\s*=\s*\w+/ig,'').trim();
        meta.setAttribute('content', content + (content ? ', ' : '') + 'viewport-fit=contain');
      }
    }
    var node = document.getElementById(STYLE_ID);
    if (!node){
      node = document.createElement('style');
      node.id = STYLE_ID;
      head.appendChild(node);
    }
    if (node.textContent !== CSS) node.textContent = CSS;
    if (head.lastElementChild !== node) head.appendChild(node);
  }

  patch();

  ['pushState','replaceState'].forEach(function(fn){
    var orig = history[fn];
    if (!orig) return;
    history[fn] = function(){
      var r = orig.apply(this, arguments);
      setTimeout(patch, 90);
      setTimeout(patch, 420);
      return r;
    };
  });
  window.addEventListener('popstate', function(){ setTimeout(patch, 90); });
  // Watchdog for lazy-injected shells.  Skips while the keyboard is up
  // so the viewport meta rewrite doesn't jitter mid-animation.
  setInterval(patch, 2400);
})();
''');
  }

  /// Scrolls the currently focused input above the keyboard when the
  /// visual viewport shrinks.  Uses `behavior:'auto'` (not `smooth`) —
  /// smooth scroll animates concurrently with the keyboard slide-up and
  /// visibly jitters on some Android WebViews.
  void _wireKeyboardShifter() {
    _view.runJavaScript(r'''
(function(){
  if (window.__hdKbShifter) return;
  window.__hdKbShifter = true;

  function isEditable(el){
    if (!el) return false;
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') return true;
    return el.isContentEditable === true;
  }

  function bringIntoView(){
    var el = document.activeElement;
    if (!isEditable(el)) return;
    var vp = window.visualViewport;
    if (vp){
      var rect = el.getBoundingClientRect();
      var top = vp.offsetTop;
      var bottom = top + vp.height;
      if (rect.bottom > bottom - 24 || rect.top < top){
        el.scrollIntoView({ block: 'nearest', behavior: 'auto' });
      }
    } else {
      el.scrollIntoView({ block: 'nearest', behavior: 'auto' });
    }
  }

  document.addEventListener('focusin', function(e){
    if (isEditable(e.target)) setTimeout(bringIntoView, 360);
  });

  if (window.visualViewport){
    var previous = window.visualViewport.height;
    window.visualViewport.addEventListener('resize', function(){
      var height = window.visualViewport.height;
      if (height < previous) setTimeout(bringIntoView, 140);
      previous = height;
    });
  }
})();
''');
  }

  // -------- Lifecycle ---------------------------------------------------

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offlineDebounced?.cancel();
    widget.courier.onUrl = null;
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  Future<bool> _handleBack() async {
    if (await _view.canGoBack()) {
      await _view.goBack();
    }
    // Never exit the app via back — this is the whole point.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Padding respects notches, curved corners and gesture bars on every
    // side.  In immersive-sticky mode Android reports viewPadding as the
    // system-reserved area even when the bars are hidden, so this keeps
    // the WebView content inside the visually safe rectangle.
    final viewPadding = MediaQuery.of(context).viewPadding;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: viewPadding.top,
                bottom: viewPadding.bottom,
                left: viewPadding.left,
                right: viewPadding.right,
              ),
              child: WebViewWidget(controller: _view),
            ),
            if (_spinning)
              const ColoredBox(
                color: Color(0xA0000000),
                child: Center(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFFFFCC33)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
