/// Server response shape returned by `/config.php`.
///
/// Success (route through WebView):
///   { "ok": true, "url": "https://...", "expires": 1789012345 }
///
/// Rejection (route into the local game):
///   { "ok": false, "message": "organic" }
class GateReply {
  final bool ok;
  final String? url;
  final int? expiresAt;
  final String? errorHint;
  final String? rawMessage;

  const GateReply._({
    required this.ok,
    this.url,
    this.expiresAt,
    this.errorHint,
    this.rawMessage,
  });

  factory GateReply.ok(String url, {int? expires, String? message}) =>
      GateReply._(ok: true, url: url, expiresAt: expires, rawMessage: message);

  factory GateReply.reject({String? message}) =>
      GateReply._(ok: false, rawMessage: message);

  factory GateReply.failure(String hint) =>
      GateReply._(ok: false, errorHint: hint);

  factory GateReply.fromJson(Map<String, dynamic> json) {
    final ok = json['ok'] == true;
    final url = json['url']?.toString();
    final expires = _asInt(json['expires']);
    final message = json['message']?.toString();
    if (ok && url != null && url.isNotEmpty) {
      return GateReply.ok(url, expires: expires, message: message);
    }
    return GateReply.reject(message: message);
  }

  bool get hasUrl => (url != null) && url!.isNotEmpty;

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
