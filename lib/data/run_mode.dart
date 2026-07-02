// The persisted decision about which flow this install runs.
//
//   fresh    -> first launch (or user cleared prefs); go through the
//               attribution flow and let the backend decide.
//   webview  -> backend previously answered `ok: true` — treat this
//               install as a paid one and try to open the WebView.
//   game     -> backend previously answered `ok: false` — always show
//               the native game, never talk to the backend again.
enum RunMode {
  fresh,
  webview,
  game;

  static RunMode fromLabel(String? label) {
    switch (label) {
      case 'webview':
        return RunMode.webview;
      case 'game':
        return RunMode.game;
      default:
        return RunMode.fresh;
    }
  }

  String get label {
    switch (this) {
      case RunMode.webview:
        return 'webview';
      case RunMode.game:
        return 'game';
      case RunMode.fresh:
        return 'fresh';
    }
  }
}
