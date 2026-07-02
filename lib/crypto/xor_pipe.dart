import 'dart:typed_data';

// ============================================================
// XorPipe — additive stream deobfuscator for embedded secrets.
// ============================================================
// Sensitive strings (config endpoint, AppsFlyer key, Firebase project#,
// GCD host, UA fragments) are shipped as opaque byte arrays.  At runtime
// [unwind] rehydrates them into UTF-8 strings.
//
// The scheme deliberately mixes an additive stream with a position
// offset so the resulting byte histogram does not look like a plain
// XOR-with-constant.  Two encoded copies of the same plaintext land on
// completely different byte patterns after a single seed change.
//
// Encoding side lives in tool/encode_secrets.dart; keep the two files in
// sync — any change to [_streamKey] here must be paired with a re-encode.
// ============================================================

/// Seed phrase driving the byte stream.
///
/// IMPORTANT: this string is the *only* thing you need to change to
/// invalidate every previously encoded secret in this project.  After a
/// change, re-run `dart run tool/encode_secrets.dart` and paste the new
/// arrays into `lib/core/endpoint_bundle.dart` and
/// `lib/core/analytics_bundle.dart`.
const String _seedPhrase = 'hd-flame-r0ad!';

/// Produces a 24-byte pseudo-random stream from [_seedPhrase] using
/// xorshift32.  24 (not 16) so multi-byte position wrap-around lands on
/// a different modulus than the AdventureRoad template.
Uint8List _streamKey() {
  var state = 0x1E85A7C3;
  for (final unit in _seedPhrase.codeUnits) {
    state = ((state ^ unit) * 0x01000193) & 0xFFFFFFFF;
    // xorshift32
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= (state >> 17) & 0xFFFFFFFF;
    state ^= (state << 5)  & 0xFFFFFFFF;
    state &= 0xFFFFFFFF;
  }

  final key = Uint8List(24);
  for (var i = 0; i < key.length; i++) {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= (state >> 17) & 0xFFFFFFFF;
    state ^= (state << 5)  & 0xFFFFFFFF;
    state &= 0xFFFFFFFF;
    key[i] = (state ^ (i * 0x9E)) & 0xFF;
  }
  return key;
}

final Uint8List _kStream = _streamKey();

/// Position offset baked into the encoding so the same key byte lands on
/// a distinct output at every offset.  Multiplier + step chosen so the
/// per-position offset cycles every 256 positions.
int _posOffset(int i) => (i * 7 + (i >> 3) * 11 + 41) & 0xFF;

/// Reverses the additive stream applied by tool/encode_secrets.dart.
/// Returns the original UTF-8 string.
String unwind(List<int> encoded) {
  final len = encoded.length;
  if (len == 0) return '';
  final out = Uint8List(len);
  for (var i = 0; i < len; i++) {
    final k = _kStream[i % _kStream.length];
    out[i] = (encoded[i] - k - _posOffset(i)) & 0xFF;
  }
  return String.fromCharCodes(out);
}

/// Convenience: joins a list of encoded chunks (host, path, query) and
/// unwinds each independently.  Useful when a URL is split for extra
/// obfuscation.
String unwindJoin(List<List<int>> parts, [String glue = '']) {
  if (parts.isEmpty) return '';
  final buf = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) buf.write(glue);
    buf.write(unwind(parts[i]));
  }
  return buf.toString();
}
