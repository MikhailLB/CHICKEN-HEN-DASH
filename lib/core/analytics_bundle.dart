import '../crypto/xor_pipe.dart';

// ============================================================
// Analytics bundle — obfuscated AppsFlyer + Firebase credentials.
// ============================================================
// Values are byte streams produced by `dart run tool/encode_secrets.dart`.
// Empty arrays mean "not configured yet" and the corresponding service
// falls back to no-op behaviour — the app must keep working without them.
// ============================================================

/// Decoded AppsFlyer Dev Key.
String resolveAttributionKey() {
  const v = <int>[
    0xcc, 0x83, 0xf4, 0x17, 0x66, 0x9e, 0x07, 0xf2, 0xeb, 0x52, 0xff, 0xf6,
    0x68, 0x2a, 0x90, 0xbe, 0x99, 0x6a, 0xbf, 0xd8, 0x45, 0x62,
  ];
  if (v.isEmpty) return '';
  return unwind(v);
}

/// Decoded Firebase project number ("Sender ID").
/// Reported to the backend so it can send test pushes to this exact
/// FCM project.
String resolveMessagingProject() {
  const v = <int>[
    0xc1, 0x54, 0xbc, 0xd8, 0x24, 0x5d, 0xca, 0xf4, 0xcd, 0x40, 0x02, 0xd2,
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
