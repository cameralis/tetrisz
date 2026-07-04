import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:tetris/src/input/control_bindings.dart';
import 'package:tetris/src/input/das_repeater.dart';
import 'package:tetris/src/input/gamepad_service.dart';

NormalizedGamepadEvent _buttonEvent(
  GamepadButton button,
  double value, {
  String pad = 'pad-1',
}) {
  return NormalizedGamepadEvent(
    gamepadId: pad,
    timestamp: 0,
    value: value,
    button: button,
    rawEvent: GamepadEvent(
      gamepadId: pad,
      timestamp: 0,
      type: KeyType.button,
      key: 'test',
      value: value,
    ),
  );
}

NormalizedGamepadEvent _axisEvent(
  GamepadAxis axis,
  double value, {
  String pad = 'pad-1',
}) {
  return NormalizedGamepadEvent(
    gamepadId: pad,
    timestamp: 0,
    value: value,
    axis: axis,
    rawEvent: GamepadEvent(
      gamepadId: pad,
      timestamp: 0,
      type: KeyType.analog,
      key: 'test',
      value: value,
    ),
  );
}

void main() {
  group('GamepadBindings', () {
    test('guideline defaults follow tetris.wiki controller mappings', () {
      final bindings = GamepadBindings.guideline();
      // Up = locking hard drop, down = non-locking soft drop, left/right =
      // shift, on both the d-pad and the left stick.
      expect(bindings.actionFor(GamepadControl.dpadUp), GameAction.hardDrop);
      expect(bindings.actionFor(GamepadControl.dpadDown), GameAction.softDrop);
      expect(bindings.actionFor(GamepadControl.dpadLeft), GameAction.moveLeft);
      expect(
        bindings.actionFor(GamepadControl.dpadRight),
        GameAction.moveRight,
      );
      expect(
        bindings.actionFor(GamepadControl.leftStickUp),
        GameAction.hardDrop,
      );
      expect(
        bindings.actionFor(GamepadControl.leftStickDown),
        GameAction.softDrop,
      );
      expect(
        bindings.actionFor(GamepadControl.leftStickLeft),
        GameAction.moveLeft,
      );
      expect(
        bindings.actionFor(GamepadControl.leftStickRight),
        GameAction.moveRight,
      );
      // Left fire button rotates counterclockwise, right fire button rotates
      // clockwise (A/Cross + X/Square vs B/Circle + Y/Triangle).
      expect(
        bindings.actionFor(GamepadControl.buttonSouth),
        GameAction.rotateCounterClockwise,
      );
      expect(
        bindings.actionFor(GamepadControl.buttonWest),
        GameAction.rotateCounterClockwise,
      );
      expect(
        bindings.actionFor(GamepadControl.buttonEast),
        GameAction.rotateClockwise,
      );
      expect(
        bindings.actionFor(GamepadControl.buttonNorth),
        GameAction.rotateClockwise,
      );
      expect(bindings.actionFor(GamepadControl.leftBumper), GameAction.hold);
      expect(bindings.actionFor(GamepadControl.rightBumper), GameAction.hold);
      expect(bindings.actionFor(GamepadControl.start), GameAction.pause);
      // Everything else starts unbound.
      expect(bindings.actionFor(GamepadControl.leftTrigger), isNull);
      expect(bindings.actionFor(GamepadControl.rightStickUp), isNull);
      expect(bindings.actionFor(GamepadControl.select), isNull);
    });

    test('encode/decode round trip preserves custom bindings', () {
      final custom = GamepadBindings.guideline()
          .bind(GamepadControl.leftTrigger, GameAction.hold)
          .unbind(GamepadControl.dpadUp);
      final decoded = GamepadBindings.decode(custom.encode());
      expect(decoded.actionFor(GamepadControl.leftTrigger), GameAction.hold);
      expect(decoded.actionFor(GamepadControl.dpadUp), isNull);
      expect(decoded.actionFor(GamepadControl.dpadDown), GameAction.softDrop);
    });

    test('decode falls back to guideline defaults on bad input', () {
      expect(
        GamepadBindings.decode(null).actionFor(GamepadControl.dpadUp),
        GameAction.hardDrop,
      );
      expect(
        GamepadBindings.decode('not json').actionFor(GamepadControl.dpadUp),
        GameAction.hardDrop,
      );
      expect(
        GamepadBindings.decode('[1,2]').actionFor(GamepadControl.dpadUp),
        GameAction.hardDrop,
      );
    });

    test('decode skips unknown controls and actions', () {
      final decoded = GamepadBindings.decode(
        '{"warpDrive":"hardDrop","dpadUp":"teleport","buttonSouth":"hold"}',
      );
      expect(decoded.actionFor(GamepadControl.dpadUp), isNull);
      expect(decoded.actionFor(GamepadControl.buttonSouth), GameAction.hold);
    });

    test('controlsFor lists every control bound to an action', () {
      final bindings = GamepadBindings.guideline();
      expect(bindings.controlsFor(GameAction.hold), [
        GamepadControl.leftBumper,
        GamepadControl.rightBumper,
      ]);
      final rebound = bindings.bind(
        GamepadControl.leftBumper,
        GameAction.pause,
      );
      expect(rebound.controlsFor(GameAction.hold), [
        GamepadControl.rightBumper,
      ]);
    });
  });

  group('TouchBindings', () {
    test('defaults keep the shipped gesture scheme', () {
      final bindings = TouchBindings.defaults();
      expect(
        bindings.actionFor(TouchGesture.tapLeft),
        GameAction.rotateCounterClockwise,
      );
      expect(
        bindings.actionFor(TouchGesture.tapRight),
        GameAction.rotateClockwise,
      );
      expect(bindings.actionFor(TouchGesture.swipeUp), GameAction.hold);
      expect(bindings.actionFor(TouchGesture.swipeDown), GameAction.hardDrop);
      expect(bindings.actionFor(TouchGesture.longPress), GameAction.softDrop);
    });

    test('round trip preserves explicit unbinds', () {
      final custom = TouchBindings.defaults()
          .bind(TouchGesture.swipeUp, null)
          .bind(TouchGesture.tapLeft, GameAction.hardDrop);
      final decoded = TouchBindings.decode(custom.encode());
      expect(decoded.actionFor(TouchGesture.swipeUp), isNull);
      expect(decoded.actionFor(TouchGesture.tapLeft), GameAction.hardDrop);
      expect(decoded.actionFor(TouchGesture.longPress), GameAction.softDrop);
    });

    test('gestures missing from persisted JSON keep their defaults', () {
      final decoded = TouchBindings.decode('{"tapRight":"hold"}');
      expect(decoded.actionFor(TouchGesture.tapRight), GameAction.hold);
      expect(decoded.actionFor(TouchGesture.swipeDown), GameAction.hardDrop);
    });
  });

  group('DasRepeater', () {
    test('auto-repeat starts after the delay and fires at the interval', () {
      final das = DasRepeater();
      das.press(-1);
      expect(das.activeDirection, -1);
      expect(das.poll(const Duration(milliseconds: 100)), 0);
      expect(das.poll(const Duration(milliseconds: 66)), 0);
      expect(das.poll(const Duration(milliseconds: 1)), 1);
      expect(das.poll(const Duration(milliseconds: 33)), 1);
      expect(das.poll(const Duration(milliseconds: 99)), 3);
    });

    test('most recent direction wins and recharges the delay', () {
      final das = DasRepeater();
      das.press(-1);
      expect(das.poll(const Duration(milliseconds: 200)), greaterThan(0));
      das.press(1);
      expect(das.activeDirection, 1);
      expect(das.poll(const Duration(milliseconds: 166)), 0);
      expect(das.poll(const Duration(milliseconds: 1)), 1);
    });

    test('releasing the active direction falls back to the held one', () {
      final das = DasRepeater();
      das.press(-1);
      das.press(1);
      das.release(1);
      expect(das.activeDirection, -1);
      // The fallback direction restarts with a full charge.
      expect(das.poll(const Duration(milliseconds: 166)), 0);
      expect(das.poll(const Duration(milliseconds: 2)), 1);
      das.release(-1);
      expect(das.activeDirection, 0);
      expect(das.poll(const Duration(milliseconds: 500)), 0);
    });

    test('releasing the inactive direction does not recharge', () {
      final das = DasRepeater();
      das.press(-1);
      das.press(1);
      expect(das.poll(const Duration(milliseconds: 160)), 0);
      das.release(-1);
      expect(das.activeDirection, 1);
      expect(das.poll(const Duration(milliseconds: 7)), 1);
    });

    test('a single huge frame delta cannot flood the board', () {
      final das = DasRepeater();
      das.press(1);
      expect(das.poll(const Duration(seconds: 30)), lessThanOrEqualTo(20));
    });
  });

  group('GamepadService', () {
    test('buttons produce deduplicated press/release edges', () async {
      final source = StreamController<NormalizedGamepadEvent>();
      final service = GamepadService(events: source.stream);
      final events = <GamepadControlEvent>[];
      service.controlEvents.listen(events.add);

      source
        ..add(_buttonEvent(GamepadButton.a, 1))
        ..add(_buttonEvent(GamepadButton.a, 1))
        ..add(_buttonEvent(GamepadButton.a, 0))
        ..add(_buttonEvent(GamepadButton.dpadLeft, 1));
      await pumpEventQueue();

      expect(events, hasLength(3));
      expect(events[0].control, GamepadControl.buttonSouth);
      expect(events[0].pressed, isTrue);
      expect(events[1].control, GamepadControl.buttonSouth);
      expect(events[1].pressed, isFalse);
      expect(events[2].control, GamepadControl.dpadLeft);
      expect(events[2].pressed, isTrue);
    });

    test('stick axes become directions with hysteresis', () async {
      final source = StreamController<NormalizedGamepadEvent>();
      final service = GamepadService(events: source.stream);
      final events = <GamepadControlEvent>[];
      service.controlEvents.listen(events.add);

      source
        ..add(_axisEvent(GamepadAxis.leftStickX, 0.4)) // below press threshold
        ..add(_axisEvent(GamepadAxis.leftStickX, 0.6)) // press right
        ..add(_axisEvent(GamepadAxis.leftStickX, 0.4)) // within hysteresis
        ..add(_axisEvent(GamepadAxis.leftStickX, 0.2)) // release right
        ..add(_axisEvent(GamepadAxis.leftStickX, -0.8)) // press left
        ..add(_axisEvent(GamepadAxis.leftStickX, 0)); // release left
      await pumpEventQueue();

      expect(events, hasLength(4));
      expect(events[0].control, GamepadControl.leftStickRight);
      expect(events[0].pressed, isTrue);
      expect(events[1].control, GamepadControl.leftStickRight);
      expect(events[1].pressed, isFalse);
      expect(events[2].control, GamepadControl.leftStickLeft);
      expect(events[2].pressed, isTrue);
      expect(events[3].control, GamepadControl.leftStickLeft);
      expect(events[3].pressed, isFalse);
    });

    test('stick up/down follow the plugin sign convention', () async {
      final source = StreamController<NormalizedGamepadEvent>();
      final service = GamepadService(events: source.stream);
      final events = <GamepadControlEvent>[];
      service.controlEvents.listen(events.add);

      source
        ..add(_axisEvent(GamepadAxis.leftStickY, 1)) // up = +1
        ..add(_axisEvent(GamepadAxis.leftStickY, -1)) // down = -1
        ..add(_axisEvent(GamepadAxis.leftStickY, 0));
      await pumpEventQueue();

      expect(events.map((e) => (e.control, e.pressed)).toList(), [
        (GamepadControl.leftStickUp, true),
        (GamepadControl.leftStickUp, false),
        (GamepadControl.leftStickDown, true),
        (GamepadControl.leftStickDown, false),
      ]);
    });

    test(
      'trigger reported as both axis and button collapses to one edge',
      () async {
        final source = StreamController<NormalizedGamepadEvent>();
        final service = GamepadService(events: source.stream);
        final events = <GamepadControlEvent>[];
        service.controlEvents.listen(events.add);

        source
          ..add(_axisEvent(GamepadAxis.leftTrigger, 0.9))
          ..add(_buttonEvent(GamepadButton.leftTrigger, 1))
          ..add(_buttonEvent(GamepadButton.leftTrigger, 0))
          ..add(_axisEvent(GamepadAxis.leftTrigger, 0));
        await pumpEventQueue();

        expect(events, hasLength(2));
        expect(events[0].control, GamepadControl.leftTrigger);
        expect(events[0].pressed, isTrue);
        expect(events[1].pressed, isFalse);
      },
    );

    test('pads track pressed state independently', () async {
      final source = StreamController<NormalizedGamepadEvent>();
      final service = GamepadService(events: source.stream);
      final events = <GamepadControlEvent>[];
      service.controlEvents.listen(events.add);

      source
        ..add(_buttonEvent(GamepadButton.a, 1, pad: 'xbox'))
        ..add(_buttonEvent(GamepadButton.a, 1, pad: 'dualsense'))
        ..add(_buttonEvent(GamepadButton.a, 0, pad: 'xbox'));
      await pumpEventQueue();

      expect(events, hasLength(3));
      expect(events[0].gamepadId, 'xbox');
      expect(events[1].gamepadId, 'dualsense');
      expect(events[2].gamepadId, 'xbox');
      expect(events[2].pressed, isFalse);
    });
  });
}
