import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tetris/src/ui/components.dart';
import 'package:tetris/src/ui/ui_sounds.dart';

final class RecordingUiSounds implements UiSounds {
  final List<UiSfx> played = [];

  @override
  void play(UiSfx sfx) => played.add(sfx);

  @override
  void dispose() {}
}

/// Wraps a widget the way pages present components: dark app, centered.
Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: child,
        ),
      ),
    ),
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

  group('TetrisButton', () {
    testWidgets('fires onPressed and plays confirm sound on tap', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          TetrisButton(
            onPressed: () => pressed += 1,
            child: const Text('Play'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();

      expect(pressed, 1);
      expect(sounds.played, contains(UiSfx.confirm));
    });

    testWidgets('disabled button neither fires nor sounds', (tester) async {
      await tester.pumpWidget(
        _host(const TetrisButton(onPressed: null, child: Text('Play'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Play'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(sounds.played, isEmpty);
    });

    testWidgets('activates via keyboard Enter when focused', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          TetrisButton(
            autofocus: true,
            onPressed: () => pressed += 1,
            child: const Text('Play'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(pressed, 1);
      expect(sounds.played, contains(UiSfx.confirm));
    });

    testWidgets('activates via ActivateIntent (gamepad navigator path)', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          TetrisButton(
            autofocus: true,
            onPressed: () => pressed += 1,
            child: const Text('Play'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Exactly what GamepadUiNavigator does for the South button.
      final context = FocusManager.instance.primaryFocus!.context!;
      Actions.maybeInvoke(context, const ActivateIntent());
      await tester.pumpAndSettle();

      expect(pressed, 1);
    });

    testWidgets('autofocus at mount stays silent, later traversal ticks', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TetrisButton(
                autofocus: true,
                onPressed: () {},
                child: const Text('First'),
              ),
              TetrisButton(onPressed: () {}, child: const Text('Second')),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(sounds.played, isEmpty, reason: 'autofocus must not tick');

      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(sounds.played, contains(UiSfx.tick));
    });

    testWidgets('hover plays a tick', (tester) async {
      // Hover/focus highlight callbacks only fire in traditional highlight
      // mode (as on desktop); the test binding defaults to touch.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
      });
      await tester.pumpWidget(
        _host(TetrisButton(onPressed: () {}, child: const Text('Play'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('Play')));
      await tester.pumpAndSettle();

      expect(sounds.played, contains(UiSfx.tick));
    });

    testWidgets('press animates the face down and releases back', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(TetrisButton(onPressed: () {}, child: const Text('Play'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Play')),
      );
      // First pump establishes the ticker epoch; the second advances it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      Transform faceTransform() {
        // The innermost translate wrapping the face reflects press depth.
        final transforms = tester
            .widgetList<Transform>(
              find.descendant(
                of: find.byType(TetrisButton),
                matching: find.byType(Transform),
              ),
            )
            .toList();
        return transforms.last;
      }

      final pressedDy = faceTransform().transform.getTranslation().y;
      expect(pressedDy, greaterThan(2.5), reason: 'face slams down ~4px');

      await gesture.up();
      await tester.pumpAndSettle();
      final restedDy = faceTransform().transform.getTranslation().y;
      expect(restedDy.abs(), lessThan(0.01), reason: 'face settles at rest');
    });
  });

  group('TetrisListTile', () {
    testWidgets('tappable tile fires onTap with sound', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        _host(
          TetrisListTile(
            onTap: () => tapped += 1,
            title: const Text('Bindings'),
            subtitle: const Text('Sub'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text('Bindings'));
      await tester.pumpAndSettle();

      expect(tapped, 1);
      expect(sounds.played, contains(UiSfx.confirm));
    });

    testWidgets('static tile renders without interaction wiring', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const TetrisListTile(title: Text('Info'))),
      );
      expect(find.text('Info'), findsOneWidget);
      expect(find.byType(TetrisPressable), findsNothing);
    });
  });

  group('TetrisTextField', () {
    testWidgets('accepts input and ticks on focus', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(TetrisTextField(controller: controller, label: 'Name')),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'SZABI');

      expect(controller.text, 'SZABI');
      expect(sounds.played, contains(UiSfx.tick));
    });
  });

  group('TetrisIconButton', () {
    testWidgets('respects minimum hit target and fires', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        _host(
          TetrisIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onPressed: () => pressed += 1,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final size = tester.getSize(find.byType(TetrisIconButton));
      expect(size.width, greaterThanOrEqualTo(40));
      expect(size.height, greaterThanOrEqualTo(40));

      await tester.tap(find.byType(TetrisIconButton));
      await tester.pumpAndSettle();
      expect(pressed, 1);
    });
  });
}
