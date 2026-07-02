import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_root.dart';
import 'flow/boot_stage.dart';
import 'net/attribution_hub.dart';
import 'net/backend_gate.dart';
import 'net/net_sensor.dart';
import 'net/push_courier.dart';
import 'net/web_fetcher.dart';
import 'vault/prefs_vault.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase is optional at boot — the app must run even before Firebase
  // credentials arrive.  Any failure here is swallowed and every service
  // that depends on Firebase becomes a no-op.
  //
  // NOTE: we deliberately do NOT activate FirebaseAppCheck here.  Play
  // Integrity attestation fails on any build not installed via the Play
  // Store (side-loaded APK, internal QA drop, adb install …), and if the
  // Firebase project has App Check enforcement enabled for Messaging
  // every push will be silently dropped.  Add activation back only if
  // the backend absolutely requires it — and route release attestation
  // through a token you control (SafetyNet legacy, DeviceCheck, etc.).
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Warm the shared HTTP client so its User-Agent is populated with real
  // device info before the first request goes out.
  await webFetcher.warm();

  final vault = PrefsVault();
  await vault.boot();

  final netSensor      = NetSensor();
  final attributionHub = AttributionHub();
  final backendGate    = BackendGate(vault);
  final pushCourier    = PushCourier(vault);

  runApp(HenDashRoot(
    initial: BootStage(
      vault: vault,
      netSensor: netSensor,
      attributionHub: attributionHub,
      backendGate: backendGate,
      pushCourier: pushCourier,
    ),
  ));
}
