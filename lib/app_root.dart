import 'package:flutter/material.dart';

/// Root MaterialApp wrapper.  Holds the theme and the initial widget so
/// [main] can inject BootStage without touching MaterialApp scaffolding.
class HenDashRoot extends StatelessWidget {
  const HenDashRoot({super.key, required this.initial});

  final Widget initial;

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
      home: initial,
    );
  }
}
