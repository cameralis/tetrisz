import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetris/src/ui/tetris_app.dart';

/// Live drive of navigation guarantees on the real app:
/// - the high-score era migration runs at startup against real preferences,
/// - system back (maybePop) cannot leave the board mid-round,
/// - the pause menu's Menu button is the sanctioned exit back home.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('era migration, blocked pop, and menu exit', (tester) async {
    // Seed a pre-rebalance profile: a high score with no scoring-era marker.
    final seededPreferences = await SharedPreferences.getInstance();
    await seededPreferences.setInt(tetrisHighScorePreferenceKey, 987654);
    await seededPreferences.remove(tetrisScoringEraPreferenceKey);
    await seededPreferences.remove(tetrisSavedGamePreferenceKey);

    await tester.pumpWidget(const TetrisApp(enableAudio: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-play')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('tetris-board')), findsOneWidget);

    // Migration ran against the real preference store during page load.
    await seededPreferences.reload();
    expect(seededPreferences.getInt(tetrisHighScorePreferenceKey), isNull);
    expect(
      seededPreferences.getInt(tetrisScoringEraPreferenceKey),
      tetrisCurrentScoringEra,
    );

    // A system back (edge swipe / Android back) must not leave the round.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('tetris-board')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-play')), findsNothing);

    // The explicit path out: pause, then the Menu button.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('PAUSED'), findsOneWidget);

    await tester.tap(find.byTooltip('Menu'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('home-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('tetris-board')), findsNothing);

    // Leaving mid-round persisted a resumable snapshot.
    await seededPreferences.reload();
    expect(
      seededPreferences.getString(tetrisSavedGamePreferenceKey),
      isNotNull,
    );
  });
}
