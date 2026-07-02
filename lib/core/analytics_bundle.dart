import '../crypto/xor_pipe.dart';

// ============================================================
// Analytics bundle — obfuscated AppsFlyer + Firebase credentials.
// ============================================================
// Values are byte streams produced by `dart run tool/encode_secrets.dart`.
// Empty arrays mean "not configured yet" and the corresponding service
// falls back to no-op behaviour — the app must keep working without them.
// ============================================================

/// Decoded AppsFlyer Dev Key.  Empty until credentials are provided.
String resolveAttributionKey() {
  const v = <int>[
    // TODO: paste bytes from tool/encode_secrets.dart once the AppsFlyer
    // Dev Key is known.  The gray flow still runs without it — the
    // config request just omits attribution fields.
  ];
  if (v.isEmpty) return '';
  return unwind(v);
}

/// Decoded Firebase project number ("Sender ID").  Empty until Firebase
/// is registered.  Reported to the backend so it can send test pushes to
/// this exact FCM project.
String resolveMessagingProject() {
  const v = <int>[
    // TODO: paste bytes from tool/encode_secrets.dart once Firebase is set.
  ];
  if (v.isEmpty) return '';
  return unwind(v);
}

/// Builds the GCD (Get Conversion Data) URL used to retry attribution
/// when AppsFlyer's first callback is a "false-organic".  Host + path
/// are stored separately for extra scrambling.
String resolveGcdEndpoint({required String appId, required String deviceId}) {
  const host = <int>[
    0xf0, 0x92, 0xfe, 0x0f, 0x64, 0x64, 0xc0, 0xee, 0x02, 0x6a, 0x2f, 0x13,
    0x98, 0x42, 0x77, 0xb2, 0xd5, 0xa3, 0xc9, 0xe4, 0x6f, 0x93, 0x91, 0xb2,
    0x7f, 0x4a, 0xc2, 0xd5,
  ];
  const path = <int>[
    0xb7, 0x87, 0xf8, 0x12, 0x65, 0x8b, 0xfd, 0x2b, 0xfa, 0x6b, 0x2c, 0x14,
    0x95, 0x06, 0xbf, 0x85, 0x93, 0x63, 0x85,
  ];
  if (host.isEmpty || path.isEmpty) return '';
  return '${unwind(host)}${unwind(path)}$appId?device_id=$deviceId';
}
