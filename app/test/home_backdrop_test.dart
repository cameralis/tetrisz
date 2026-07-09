import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/ui/home_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ambient backdrop restarts after a long visit to another page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump(const Duration(milliseconds: 100));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();

    // Outlast the bounded 45s ambient run while covered: the animation clock
    // keeps advancing under the muted ticker, so without the restart hook the
    // rain would come back completed and permanently frozen.
    await tester.pump(const Duration(seconds: 50));

    navigator.pop();
    await tester.pump();
    // Let the pop transition finish so the covering route reports dismissed.
    await tester.pump(const Duration(seconds: 1));

    expect(
      tester.binding.transientCallbackCount,
      greaterThan(0),
      reason: 'the ambient rain should be ticking again after returning home',
    );
  });
}
