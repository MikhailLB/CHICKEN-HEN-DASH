import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/loading_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const HenDashApp());
}

class HenDashApp extends StatelessWidget {
  const HenDashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hen Dash',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFCC33)),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const LoadingScreen(),
    );
  }
}
