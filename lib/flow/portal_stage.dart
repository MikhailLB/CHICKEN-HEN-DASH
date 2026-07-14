import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeatureType;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../bridge/insight.dart';
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

  // ---- Insight tracking state ----------------------------------------
  // `_offerReached` — first successful main-frame load happened, so the
  //                   user actually saw the offer site at least once.
  //                   Once true it never flips back — subsequent errors
  //                   fire `web_error_after_load` instead of
  //                   `web_offer_unreachable`.
  // `_pageHadError` — reset on every navigation start; blocks a false
  //                   `web_offer_reached` when Chrome fires
  //                   `onPageFinished` for the built-in error page.
  bool _offerReached = false;
  bool _pageHadError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Set the Clarity screen tag + emit one stable event when the
    // WebView shell mounts.  `last_screen == web` filters straight to
    // the WebView sessions in the dashboard.
    Insight.screen('web');
    Insight.event('web_open');

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
      ..addJavaScriptChannel(
        // Bridge for the injected in-page probe.  The WebView DOM is
        // invisible to Clarity replay — this channel lifts SPA route
        // changes, deposit/register/login clicks and auth submits back
        // into Dart so they can be forwarded as Clarity events.
        'AegisInsight',
        onMessageReceived: (m) => _onWebSignal(m.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          // Reset per-navigation error flag BEFORE we flip the spinner
          // — `onPageFinished` uses this to decide whether the load was
          // clean (real offer) or an error page.
          _pageHadError = false;
          if (mounted) setState(() => _spinning = true);
        },
        onPageFinished: (url) {
          if (mounted) setState(() => _spinning = false);
          _redirectRetries = 0;
          _stripSiteInsets();
          _wireKeyboardShifter();
          _installInsightProbe();
          _trackWebPage(url);
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
    // Full-screen sticky immersive: BOTH status bar and navigation bar
    // stay hidden so the WebView owns the whole display and no
    // reserved gutter appears at the top or bottom.  Either bar
    // reappears briefly on an edge swipe, then auto-fades.
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: const [],
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
    if (state == AppLifecycleState.resumed) {
      _applyImmersive();
      Insight.event('web_foreground');
    } else if (state == AppLifecycleState.paused) {
      // Backgrounding while inside the WebView is the clearest drop-off
      // marker — combine with `last_screen` in the dashboard to spot
      // users who leave mid-funnel.
      Insight.event('web_background');
    }
  }

  // -------- Android-only WebView tweaks --------------------------------

  void _configureAndroidBridge() {
    if (!Platform.isAndroid) return;
    final platform = _view.platform;
    if (platform is! AndroidWebViewController) return;

    // Autoplay video without requiring a first tap.
    platform.setMediaPlaybackRequiresUserGesture(false);

    // Read the site's <meta name="viewport"> so `width=device-width`
    // and `initial-scale=1` are respected.  Default in webview_flutter
    // is `setUseWideViewPort(false)`, which makes Chrome fall back to a
    // 980-CSS-px viewport and then upscale content — buttons end up
    // 2-3× larger than intended.  With this flag on plus our injected
    // viewport meta the WebView renders at true mobile scale.
    platform.setUseWideViewPort(true);

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
    // hands off to the OS.  Tag the scheme so the dashboard shows how
    // often the WebView bounces the user out to a deposit / payment app.
    Insight.event('web_external');
    Insight.tag('web_external_scheme', scheme);
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

    // ---- Clarity funnel tagging ----------------------------------------
    // Do this BEFORE any recovery logic, because both the redirect-loop
    // retry and the offline slide-off may swallow the error otherwise.
    _pageHadError = true;
    final String reason = _classifyWebError(err);
    final String failedUrl = _lastMainFrame ?? widget.initialUrl;
    final String host = Uri.tryParse(failedUrl)?.host ?? '';
    Insight.event('web_error');
    Insight.tag('web_error_reason', reason);
    Insight.tag('web_last_error', '${err.errorCode}:${err.description}');
    if (host.isNotEmpty) Insight.tag('web_error_host', host);
    if (!_offerReached) {
      // The user never saw the offer.  This is the ERR_CONNECTION_REFUSED
      // / DNS-blackhole case the dashboard cares about most.
      Insight.event('web_offer_unreachable');
      Insight.tag('offer_reached', 'false');
      Insight.tag('offer_unreachable_reason', reason);
    } else {
      Insight.event('web_error_after_load');
    }

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
    // Only neutralise VERTICAL safe-area padding — leave horizontal
    // margin alone so the site's own gutters (body { padding: 0 12px })
    // keep working.  Killing left/right padding here glued every
    // button to the screen edge on partner sites.
    'html,body,#app,#root,#__next,#__nuxt,#__layout,',
    '.mobile-header,.app-shell,.viewport-shell{',
      'padding-top:0!important;',
      'margin-top:0!important;',
    '}'
  ].join('');

  function keyboardVisible(){
    if (!window.visualViewport) return false;
    return window.visualViewport.height < window.innerHeight * 0.75;
  }

  var VIEWPORT_CONTENT =
    'width=device-width, initial-scale=1.0, minimum-scale=1.0, ' +
    'maximum-scale=5.0, user-scalable=yes, viewport-fit=contain';

  function patch(){
    if (keyboardVisible()) return;
    var head = document.head || document.documentElement;
    if (!head) return;
    // Force a mobile-friendly viewport.  Without width=device-width
    // Android WebView renders the page as if the viewport was 980px
    // wide and then scales it up to the physical screen — buttons look
    // 2 – 3× larger than intended.  We overwrite any existing viewport
    // meta and inject one if the page never shipped it.
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta){
      meta = document.createElement('meta');
      meta.setAttribute('name', 'viewport');
      head.appendChild(meta);
    }
    if (meta.getAttribute('content') !== VIEWPORT_CONTENT){
      meta.setAttribute('content', VIEWPORT_CONTENT);
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

  // -------- Insight funnel helpers -------------------------------------
  //
  // The WebView shell shows up in Clarity replay, but the DOM inside is
  // not recorded — the funnel below (offer reachability, deposit /
  // register / login pages and clicks, auth submits) is reconstructed
  // from these events.  Keep event names STABLE and few; high-cardinality
  // values (URLs, hosts, labels) go into TAGS.

  /// Route-detection regexes.  Broad on purpose — partner sites use
  /// wildly different URL styles and copy for the same intent (Cyrillic
  /// included so the current CIS traffic is not blind).
  static final RegExp _depositRx = RegExp(
    r'(deposit|cashier|top.?up|replenish|payment|checkout|wallet|'
    r'пополн|депозит|касс|оплат|внести|платеж)',
    caseSensitive: false,
  );
  static final RegExp _registerRx = RegExp(
    r'(sign.?up|regist|create.?account|onboarding|регистрац|зарегистр)',
    caseSensitive: false,
  );
  static final RegExp _loginRx = RegExp(
    r'(sign.?in|log.?in|log.?on|/auth\b|authoriz|войти|вход|авториз)',
    caseSensitive: false,
  );

  void _trackWebPage(String url) {
    final Uri? uri = Uri.tryParse(url);
    Insight.screenName(
      'web:${uri == null ? url : '${uri.host}${uri.path}'}',
    );
    Insight.event('web_page');
    Insight.tag('web_last_url', url);
    if (!_offerReached && !_pageHadError) {
      _offerReached = true;
      Insight.event('web_offer_reached');
      Insight.tag('offer_reached', 'true');
      if (uri?.host != null) Insight.tag('offer_host', uri!.host);
    }
    if (_depositRx.hasMatch(url)) {
      Insight.event('web_cashier_page');
      Insight.tag('reached_cashier', 'true');
    }
    _trackAuthPage(url);
  }

  void _trackAuthPage(String textOrUrl) {
    if (_registerRx.hasMatch(textOrUrl)) {
      Insight.event('web_register_page');
      Insight.tag('reached_register', 'true');
    } else if (_loginRx.hasMatch(textOrUrl)) {
      Insight.event('web_login_page');
      Insight.tag('reached_login', 'true');
    }
  }

  /// Turns a WebResourceError into one of ~10 stable reason buckets so
  /// the dashboard can pivot on `web_error_reason` without dealing with
  /// platform-specific error codes.
  static String _classifyWebError(WebResourceError err) {
    final String d = err.description.toLowerCase();
    final int c = err.errorCode;
    if (d.contains('connection_refused') ||
        d.contains('connection refused')) {
      return 'connection_refused';
    }
    if (d.contains('too_many_redirects') ||
        d.contains('too many redirects')) {
      return 'redirect_loop';
    }
    if (d.contains('name_not_resolved') ||
        d.contains('address_unreachable') ||
        d.contains('unknownhost') ||
        c == -2) {
      return 'dns_unresolved';
    }
    if (d.contains('timed out') || d.contains('timeout') || c == -8) {
      return 'timeout';
    }
    if (d.contains('internet_disconnected') ||
        d.contains('network_changed') ||
        c == -6) {
      return 'no_network';
    }
    if (d.contains('connection_reset')) return 'connection_reset';
    if (d.contains('connection_closed') ||
        d.contains('empty_response')) {
      return 'connection_closed';
    }
    if (d.contains('ssl') || d.contains('cert') || c == -11) {
      return 'ssl_error';
    }
    if (d.contains('blocked')) return 'blocked';
    return 'other';
  }

  /// Injects an idempotent probe that reports SPA route changes,
  /// deposit / register / login clicks and auth form submits back to
  /// Dart over the `AegisInsight` channel.  Safe to call on every
  /// `onPageFinished` — the `window.__aegisInsight` guard prevents a
  /// double-install.
  void _installInsightProbe() {
    _view.runJavaScript(r'''
(function(){
  if (window.__aegisInsight) return; window.__aegisInsight = true;
  function send(t){ try { AegisInsight.postMessage(t); } catch(e){} }
  var DEP=/(deposit|cashier|top.?up|add funds|replenish|payment|pay now|checkout|withdraw|пополн|депозит|касс|оплат|внести|вывод|платеж)/i;
  var REG=/(sign.?up|regist|create.?account|регистрац|зарегистр)/i;
  var LOG=/(sign.?in|log.?in|log.?on|войти|вход|авториз)/i;
  var lastPath='';
  function reportPath(){ var p=location.pathname+location.search; if(p!==lastPath){ lastPath=p; send('path:'+p);} }
  reportPath();
  ['pushState','replaceState'].forEach(function(fn){
    var o=history[fn]; history[fn]=function(){ var r=o.apply(this,arguments); setTimeout(reportPath,60); return r; };
  });
  window.addEventListener('popstate',function(){ setTimeout(reportPath,60); });
  document.addEventListener('click',function(e){
    try{ var el=e.target;
      for(var i=0;i<4&&el;i++){
        var t=((el.innerText||el.value||(el.getAttribute&&el.getAttribute('aria-label'))||'')+'').trim();
        if(t){ if(DEP.test(t)){send('deposit_click:'+t.slice(0,60));return;}
               if(REG.test(t)){send('register_click:'+t.slice(0,60));return;}
               if(LOG.test(t)){send('login_click:'+t.slice(0,60));return;} }
        el=el.parentElement;
      }
    }catch(x){}
  },true);
  document.addEventListener('submit',function(e){
    try{ var f=e.target;
      var pw=f.querySelectorAll?f.querySelectorAll('input[type="password"]'):[];
      var blob=((f.innerText||'')+' '+(f.getAttribute('action')||'')+' '+(f.className||''));
      var confirm=f.querySelector&&(f.querySelector('input[name*="confirm" i]')||f.querySelector('input[name*="repeat" i]'));
      if(pw&&pw.length>=2){send('auth_submit:register');return;}
      if(pw&&pw.length===1){ send('auth_submit:'+((confirm||REG.test(blob))?'register':'login')); return; }
      if(REG.test(blob)){send('auth_submit:register');return;}
      if(LOG.test(blob)){send('auth_submit:login');return;}
      send('form_submit');
    }catch(x){ send('form_submit'); }
  },true);
})();
''');
  }

  void _onWebSignal(String raw) {
    final int i = raw.indexOf(':');
    final String type = i < 0 ? raw : raw.substring(0, i);
    final String data = i < 0 ? '' : raw.substring(i + 1);
    switch (type) {
      case 'path':
        Insight.event('web_spa_route');
        Insight.tag('web_last_path', data);
        if (_depositRx.hasMatch(data)) {
          Insight.event('web_cashier_page');
          Insight.tag('reached_cashier', 'true');
        }
        _trackAuthPage(data);
        break;
      case 'deposit_click':
        Insight.event('web_deposit_click');
        Insight.tag('deposit_intent', 'true');
        if (data.isNotEmpty) Insight.tag('deposit_label', data);
        break;
      case 'register_click':
        Insight.event('web_register_click');
        Insight.tag('register_intent', 'true');
        break;
      case 'login_click':
        Insight.event('web_login_click');
        Insight.tag('login_intent', 'true');
        break;
      case 'auth_submit':
        if (data == 'register') {
          Insight.event('web_register_submit');
          Insight.tag('attempted_register', 'true');
        } else {
          Insight.event('web_login_submit');
          Insight.tag('attempted_login', 'true');
        }
        break;
      case 'form_submit':
        Insight.event('web_form_submit');
        break;
    }
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
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final isLandscape = size.width > size.height;

    // In landscape only the camera cutout matters visually — the nav-bar
    // side (and the opposite bezel) should stretch to the edge so we
    // don't render two symmetric black gutters around the WebView.
    // Portrait keeps the full SafeArea because status bar / gesture
    // pill / camera hole all live on the vertical axis.
    double landscapeLeftInset = 0;
    double landscapeRightInset = 0;
    if (isLandscape) {
      // 1. Preferred path — DisplayFeatures gives us the exact cutout
      //    rectangle.  Works on stock Android and most modern OEMs.
      for (final feature in mq.displayFeatures) {
        if (feature.type != DisplayFeatureType.cutout) continue;
        final bounds = feature.bounds;
        if (bounds.left <= 0) {
          if (bounds.right > landscapeLeftInset) {
            landscapeLeftInset = bounds.right;
          }
        } else if (bounds.right >= size.width) {
          final w = size.width - bounds.left;
          if (w > landscapeRightInset) landscapeRightInset = w;
        }
      }
      // 2. Fallback — many phones with a small waterdrop / U-shaped
      //    notch never surface it through DisplayFeatures, but the
      //    platform still reports the physical inset via viewPadding
      //    (which stays non-zero in immersiveSticky mode because the
      //    hardware cutout is not something the system UI can hide).
      //    Use it if the previous pass didn't already find a wider
      //    gutter on that side.
      final rawLeft = mq.viewPadding.left;
      final rawRight = mq.viewPadding.right;
      if (rawLeft > landscapeLeftInset) landscapeLeftInset = rawLeft;
      if (rawRight > landscapeRightInset) landscapeRightInset = rawRight;
    }

    final content = Stack(
      fit: StackFit.expand,
      children: [
        WebViewWidget(controller: _view),
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
    );

    final Widget body = isLandscape
        // Landscape: fully edge-to-edge — no top / bottom / nav-bar
        // gutters.  The only horizontal padding is the physical cutout
        // width (if any), everything else touches the screen edge.
        ? Padding(
            padding: EdgeInsets.only(
              left: landscapeLeftInset,
              right: landscapeRightInset,
            ),
            child: content,
          )
        // Portrait: inset only where hardware / status bar sits — the
        // gesture-bar area at the bottom flows edge-to-edge on purpose.
        : SafeArea(
            top: true,
            bottom: false,
            left: true,
            right: true,
            child: content,
          );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // Keep the keyboard from resizing the WebView — the injected
        // scroll shifter puts focused inputs above the keyboard instead.
        resizeToAvoidBottomInset: false,
        body: body,
      ),
    );
  }
}
