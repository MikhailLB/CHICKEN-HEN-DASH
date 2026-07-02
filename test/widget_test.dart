import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hendash/app_root.dart';

void main() {
  testWidgets('HenDashRoot smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const HenDashRoot(
        initial: Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
  });
}
