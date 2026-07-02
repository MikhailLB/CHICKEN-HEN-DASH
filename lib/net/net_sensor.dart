import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

// ============================================================
// NetSensor — reliable "is the phone actually online" probe.
// ============================================================
// Rules baked in (learned the hard way — see gray_part_pitfalls.md):
//
//   * VPN, bluetooth and "other" are all valid connectivity carriers.
//     connectivity_plus reports them separately from wifi/mobile; if we
//     do not whitelist them the offline screen flashes every time the
//     user toggles their VPN.
//
//   * The DNS probe timeout is raised to 7 seconds because VPN tunnels
//     add latency that easily exceeds 3s.  Real "no route" errors throw
//     SocketException instantly so a longer budget costs nothing.
//
//   * Downstream code should ideally *debounce* the raw connectivity
//     stream by 700ms before showing the offline screen — see
//     [debouncedOfflineStream].
// ============================================================

const Set<ConnectivityResult> _carrierResults = {
  ConnectivityResult.wifi,
  ConnectivityResult.mobile,
  ConnectivityResult.ethernet,
  ConnectivityResult.vpn,
  ConnectivityResult.bluetooth,
  ConnectivityResult.other,
};

class NetSensor {
  final Connectivity _connectivity = Connectivity();

  /// Cheap check: any carrier + a short DNS lookup.
  Future<bool> isOnline() async {
    final results = await _connectivity.checkConnectivity();
    if (!results.any(_carrierResults.contains)) return false;

    try {
      final answer = await InternetAddress.lookup('cloudflare.com')
          .timeout(const Duration(seconds: 7));
      return answer.isNotEmpty && answer.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } catch (_) {
      // TimeoutException from lookup means VPN/DNS is unusable — treat
      // as offline so we can show the offline screen instead of a black
      // WebView.
      return false;
    }
  }

  Stream<List<ConnectivityResult>> get statusStream =>
      _connectivity.onConnectivityChanged;

  /// A stream of `true` events, each emitted only after the connection
  /// has been "none" for [settleWindow] milliseconds.  Perfect for
  /// deciding "yes, really navigate to the offline screen now".
  Stream<bool> debouncedOfflineStream({
    Duration settleWindow = const Duration(milliseconds: 700),
  }) {
    final controller = StreamController<bool>();
    Timer? pending;
    final sub = statusStream.listen((results) {
      final allNone = results.every((r) => r == ConnectivityResult.none) &&
          !results.any(_carrierResults.contains);
      if (!allNone) {
        pending?.cancel();
        pending = null;
        return;
      }
      pending?.cancel();
      pending = Timer(settleWindow, () {
        if (!controller.isClosed) controller.add(true);
      });
    });
    controller.onCancel = () {
      pending?.cancel();
      sub.cancel();
    };
    return controller.stream;
  }
}
