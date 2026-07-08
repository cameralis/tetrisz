import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/ui/ui_sounds.dart';
import 'package:tetris/src/ui/versus_widgets.dart';

final class RecordingUiSounds implements UiSounds {
  final List<UiSfx> played = [];

  @override
  void play(UiSfx sfx) => played.add(sfx);

  @override
  void dispose() {}
}

Widget _host(Widget child) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: child),
  );
}

void main() {
  late RecordingUiSounds sounds;

  setUp(() {
    sounds = RecordingUiSounds();
    UiFeedback.install(sounds);
    UiFeedback.sfxVolume = 1.0;
  });

  tearDown(() {
    UiFeedback.install(const NoopUiSounds());
  });

  testWidgets('counts 3-2-1 with a beat per slam and a GO payoff', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const CountdownOverlay(duration: Duration(seconds: 3))),
    );

    // Mid-first beat: the 3 has slammed in.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('3'), findsOneWidget);
    expect(sounds.played.where((s) => s == UiSfx.confirm).length, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    expect(sounds.played.where((s) => s == UiSfx.confirm).length, 2);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    expect(sounds.played.where((s) => s == UiSfx.confirm).length, 3);

    // Countdown complete: GO bursts with its own sound.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GO'), findsOneWidget);
    expect(sounds.played, contains(UiSfx.toast));

    // Let the GO tail finish so no animations are pending.
    await tester.pump(CountdownOverlay.goTail);
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('number falls in from above before the slam', (tester) async {
    await tester.pumpWidget(
      _host(const CountdownOverlay(duration: Duration(seconds: 3))),
    );

    // Early in the fall the glyph sits above its resting position.
    await tester.pump(const Duration(milliseconds: 60));
    final fallingY = tester.getCenter(find.text('3')).dy;
    await tester.pump(const Duration(milliseconds: 700));
    final restingY = tester.getCenter(find.text('3')).dy;
    expect(fallingY, lessThan(restingY));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(CountdownOverlay.goTail);
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('overlay never intercepts pointer input', (tester) async {
    var tappedBehind = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tappedBehind = true,
              child: const SizedBox.expand(),
            ),
            const CountdownOverlay(duration: Duration(seconds: 3)),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tapAt(const Offset(100, 100));
    expect(tappedBehind, isTrue);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(CountdownOverlay.goTail);
    await tester.pump(const Duration(milliseconds: 50));
  });
}
