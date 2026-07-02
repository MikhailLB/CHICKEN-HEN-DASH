import 'dart:convert';

import '../core/app_facade.dart';
import '../data/gate_reply.dart';
import '../vault/prefs_vault.dart';
import 'web_fetcher.dart';

// ============================================================
// BackendGate — talks to /config.php and caches the URL.
// ============================================================
// The gate is intentionally forgiving: any transport error, any
// non-200, any parse issue collapses into GateReply.failure(...) so the
// caller can decide whether to fall back to a saved URL, show the
// offline screen, or drop to the game.
// ============================================================

class BackendGate {
  final PrefsVault _vault;
  BackendGate(this._vault);

  Future<GateReply> negotiate(Map<String, dynamic> body) async {
    final endpoint = AppFacade.gateEndpoint;
    if (endpoint.isEmpty) {
      return GateReply.failure('endpoint-empty');
    }

    try {
      final response = await webFetcher
          .post(
            Uri.parse(endpoint),
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(AppFacade.gateReplyTimeout);

      if (response.statusCode != 200) {
        return GateReply.failure('http-${response.statusCode}');
      }
      if (response.body.isEmpty) {
        return GateReply.failure('empty-body');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return GateReply.failure('shape');
      }
      final reply = GateReply.fromJson(decoded);
      if (reply.ok && reply.url != null) {
        await _vault.writeGateUrl(reply.url!);
        await _vault.setGateExpiry(reply.expiresAt);
      }
      return reply;
    } catch (e) {
      return GateReply.failure(e.runtimeType.toString());
    }
  }

  Future<String?> cachedUrl() => _vault.readGateUrl();
}
