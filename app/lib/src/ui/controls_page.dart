import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../input/control_bindings.dart';
import '../input/gamepad_service.dart';
import '../platform_support.dart';
import 'components.dart';
import 'theme.dart';

/// Rebinding screen for gamepad buttons and touch gestures. Gamepad rows
/// capture the next physical press; touch rows pick an action from a list.
/// Changes persist immediately and apply from the next game page launch.
class ControlsPage extends StatefulWidget {
  const ControlsPage({super.key, this.gamepad});

  /// `null` (tests, or a platform without the plugin) hides live controller
  /// status and disables capture; touch rebinding still works.
  final GamepadService? gamepad;

  @override
  State<ControlsPage> createState() => _ControlsPageState();
}

class _ControlsPageState extends State<ControlsPage> {
  GamepadBindings _gamepadBindings = GamepadBindings.guideline();
  TouchBindings _touchBindings = TouchBindings.defaults();
  KeyboardBindings _keyboardBindings = KeyboardBindings.standard();
  List<GamepadController> _connected = const [];
  StreamSubscription<GamepadControlEvent>? _activitySubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBindings());
    unawaited(_refreshConnected());
    // Any input from a pad we have not seen yet (e.g. one paired while this
    // page is open) refreshes the connected list.
    _activitySubscription = widget.gamepad?.controlEvents.listen((event) {
      if (!_connected.any((pad) => pad.id == event.gamepadId)) {
        unawaited(_refreshConnected());
      }
    });
  }

  @override
  void dispose() {
    unawaited(_activitySubscription?.cancel() ?? Future.value());
    super.dispose();
  }

  Future<void> _loadBindings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final gamepadBindings = GamepadBindings.decode(
        preferences.getString(tetrisGamepadBindingsPreferenceKey),
      );
      final touchBindings = TouchBindings.decode(
        preferences.getString(tetrisTouchBindingsPreferenceKey),
      );
      final keyboardBindings = KeyboardBindings.decode(
        preferences.getString(tetrisKeyboardBindingsPreferenceKey),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _gamepadBindings = gamepadBindings;
        _touchBindings = touchBindings;
        _keyboardBindings = keyboardBindings;
      });
    } catch (_) {}
  }

  Future<void> _refreshConnected() async {
    final gamepad = widget.gamepad;
    if (gamepad == null) {
      return;
    }
    final connected = await gamepad.listGamepads();
    if (!mounted) {
      return;
    }
    setState(() {
      _connected = connected;
    });
  }

  Future<void> _saveGamepadBindings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        tetrisGamepadBindingsPreferenceKey,
        _gamepadBindings.encode(),
      );
    } catch (_) {}
  }

  Future<void> _saveTouchBindings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        tetrisTouchBindingsPreferenceKey,
        _touchBindings.encode(),
      );
    } catch (_) {}
  }

  Future<void> _saveKeyboardBindings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        tetrisKeyboardBindingsPreferenceKey,
        _keyboardBindings.encode(),
      );
    } catch (_) {}
  }

  Future<void> _captureKeyBinding(GameAction action) async {
    final key = await showDialog<LogicalKeyboardKey>(
      context: context,
      builder: (_) => _KeyboardBindingCaptureDialog(action: action),
    );
    if (key == null || !mounted) {
      return;
    }
    setState(() {
      _keyboardBindings = _keyboardBindings.bind(key, action);
    });
    unawaited(_saveKeyboardBindings());
  }

  void _unbindKey(LogicalKeyboardKey key) {
    setState(() {
      _keyboardBindings = _keyboardBindings.unbind(key);
    });
    unawaited(_saveKeyboardBindings());
  }

  void _resetKeyboardBindings() {
    setState(() {
      _keyboardBindings = KeyboardBindings.standard();
    });
    unawaited(_saveKeyboardBindings());
  }

  Future<void> _captureBinding(GameAction action) async {
    final gamepad = widget.gamepad;
    if (gamepad == null) {
      return;
    }
    final control = await showDialog<GamepadControl>(
      context: context,
      builder: (_) => _BindingCaptureDialog(gamepad: gamepad, action: action),
    );
    if (control == null || !mounted) {
      return;
    }
    setState(() {
      _gamepadBindings = _gamepadBindings.bind(control, action);
    });
    unawaited(_saveGamepadBindings());
  }

  void _unbind(GamepadControl control) {
    setState(() {
      _gamepadBindings = _gamepadBindings.unbind(control);
    });
    unawaited(_saveGamepadBindings());
  }

  void _resetGamepadBindings() {
    setState(() {
      _gamepadBindings = GamepadBindings.guideline();
    });
    unawaited(_saveGamepadBindings());
  }

  void _setTouchBinding(TouchGesture gesture, GameAction? action) {
    setState(() {
      _touchBindings = _touchBindings.bind(gesture, action);
    });
    unawaited(_saveTouchBindings());
  }

  void _resetTouchBindings() {
    setState(() {
      _touchBindings = TouchBindings.defaults();
    });
    unawaited(_saveTouchBindings());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text(
          'Controls',
          style: TextStyle(color: TetrisColors.text, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const TetrisSectionHeader('CONTROLLER'),
            _buildControllerStatusTile(),
            for (final action in GameAction.values)
              _GamepadActionTile(
                action: action,
                controls: _gamepadBindings.controlsFor(action),
                captureEnabled: widget.gamepad != null,
                onCapture: () => unawaited(_captureBinding(action)),
                onUnbind: _unbind,
              ),
            _ResetButton(
              key: const ValueKey('controls-reset-gamepad'),
              label: 'Reset to Guideline defaults',
              onPressed: _resetGamepadBindings,
            ),
            if (isDesktopPlatform) ...[
              const SizedBox(height: 20),
              const TetrisSectionHeader('KEYBOARD'),
              for (final action in GameAction.values)
                _KeyboardActionTile(
                  action: action,
                  keys: _keyboardBindings.keysFor(action),
                  onCapture: () => unawaited(_captureKeyBinding(action)),
                  onUnbind: _unbindKey,
                ),
              _ResetButton(
                key: const ValueKey('controls-reset-keyboard'),
                label: 'Reset to defaults',
                onPressed: _resetKeyboardBindings,
              ),
            ],
            const SizedBox(height: 20),
            const TetrisSectionHeader('TOUCH'),
            for (final gesture in TouchGesture.values)
              _TouchGestureTile(
                gesture: gesture,
                action: _touchBindings.actionFor(gesture),
                onChanged: (action) => _setTouchBinding(gesture, action),
              ),
            _ResetButton(
              key: const ValueKey('controls-reset-touch'),
              label: 'Reset to defaults',
              onPressed: _resetTouchBindings,
            ),
            const SizedBox(height: 12),
            const _FootnoteTile(
              'Dragging horizontally always moves the piece. Soft Drop on a '
              'tap or swipe steps one row; on Long Press it keeps dropping '
              'while held.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControllerStatusTile() {
    final names = _connected.map((pad) => pad.name).join(', ');
    return TetrisListTile(
      leading: Icon(
        Icons.sports_esports,
        color: _connected.isEmpty
            ? TetrisColors.mutedText
            : TetrisColors.accent,
      ),
      title: Text(_connected.isEmpty ? 'No controller detected' : names),
      subtitle: Text(
        widget.gamepad == null
            ? 'Controller support is unavailable here.'
            : 'Xbox and PlayStation controllers work over Bluetooth or '
                  'USB. Tap an action below, then press the button to bind.',
      ),
      trailing: TetrisIconButton(
        icon: Icons.refresh,
        size: 38,
        color: TetrisColors.mutedText,
        tooltip: 'Rescan controllers',
        onPressed: widget.gamepad == null
            ? null
            : () => unawaited(_refreshConnected()),
      ),
    );
  }
}

/// Waits for the next button/direction press on any connected pad and pops
/// with the captured [GamepadControl].
class _BindingCaptureDialog extends StatefulWidget {
  const _BindingCaptureDialog({required this.gamepad, required this.action});

  final GamepadService gamepad;
  final GameAction action;

  @override
  State<_BindingCaptureDialog> createState() => _BindingCaptureDialogState();
}

class _BindingCaptureDialogState extends State<_BindingCaptureDialog> {
  StreamSubscription<GamepadControlEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    // The press being captured must not double as UI navigation (moving
    // focus or activating buttons behind the dialog).
    widget.gamepad.blockUiNavigation();
    _subscription = widget.gamepad.controlEvents.listen((event) {
      if (event.pressed && mounted) {
        Navigator.of(context).pop(event.control);
      }
    });
  }

  @override
  void dispose() {
    widget.gamepad.unblockUiNavigation();
    unawaited(_subscription?.cancel() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TetrisColors.panel,
      title: Text(
        'Bind ${widget.action.label}',
        style: const TextStyle(color: TetrisColors.text, fontSize: 16),
      ),
      content: const Text(
        'Press a button, direction, or stick on your controller…',
        style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
      ),
      actions: [
        TetrisButton(
          variant: TetrisButtonVariant.ghost,
          compact: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _GamepadActionTile extends StatelessWidget {
  const _GamepadActionTile({
    required this.action,
    required this.controls,
    required this.captureEnabled,
    required this.onCapture,
    required this.onUnbind,
  });

  final GameAction action;
  final List<GamepadControl> controls;
  final bool captureEnabled;
  final VoidCallback onCapture;
  final ValueChanged<GamepadControl> onUnbind;

  @override
  Widget build(BuildContext context) {
    return TetrisListTile(
      key: ValueKey('gamepad-action-${action.name}'),
      onTap: captureEnabled ? onCapture : null,
      title: Text(action.label),
      subtitle: controls.isEmpty
          ? const Text('Not bound')
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final control in controls)
                    InputChip(
                      key: ValueKey('binding-${action.name}-${control.name}'),
                      label: Text(control.label),
                      labelStyle: const TextStyle(
                        color: TetrisColors.text,
                        fontSize: 11,
                      ),
                      backgroundColor: TetrisColors.panelRaised,
                      side: const BorderSide(color: Color(0x22FFFFFF)),
                      deleteIconColor: TetrisColors.mutedText,
                      onDeleted: () => onUnbind(control),
                    ),
                ],
              ),
            ),
      trailing: Icon(
        Icons.add_circle_outline,
        color: captureEnabled ? TetrisColors.accent : TetrisColors.mutedText,
      ),
    );
  }
}

/// Waits for the next key press and pops with its [LogicalKeyboardKey]. Esc
/// cancels the capture (and stays bindable via the standard defaults).
class _KeyboardBindingCaptureDialog extends StatelessWidget {
  const _KeyboardBindingCaptureDialog({required this.action});

  final GameAction action;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // Bind on key-down; swallow the up/repeat edges so a held key can't
        // leak to the buttons behind the dialog.
        if (event is! KeyDownEvent) {
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pop(event.logicalKey);
        }
        return KeyEventResult.handled;
      },
      child: AlertDialog(
        backgroundColor: TetrisColors.panel,
        title: Text(
          'Bind ${action.label}',
          style: const TextStyle(color: TetrisColors.text, fontSize: 16),
        ),
        content: const Text(
          'Press any key to bind it. Esc cancels.',
          style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
        ),
        actions: [
          TetrisButton(
            variant: TetrisButtonVariant.ghost,
            compact: true,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _KeyboardActionTile extends StatelessWidget {
  const _KeyboardActionTile({
    required this.action,
    required this.keys,
    required this.onCapture,
    required this.onUnbind,
  });

  final GameAction action;
  final List<LogicalKeyboardKey> keys;
  final VoidCallback onCapture;
  final ValueChanged<LogicalKeyboardKey> onUnbind;

  @override
  Widget build(BuildContext context) {
    return TetrisListTile(
      key: ValueKey('keyboard-action-${action.name}'),
      onTap: onCapture,
      title: Text(action.label),
      subtitle: keys.isEmpty
          ? const Text('Not bound')
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final key in keys)
                    InputChip(
                      key: ValueKey(
                        'key-binding-${action.name}-${key.keyId}',
                      ),
                      label: Text(describeLogicalKey(key)),
                      labelStyle: const TextStyle(
                        color: TetrisColors.text,
                        fontSize: 11,
                      ),
                      backgroundColor: TetrisColors.panelRaised,
                      side: const BorderSide(color: Color(0x22FFFFFF)),
                      deleteIconColor: TetrisColors.mutedText,
                      onDeleted: () => onUnbind(key),
                    ),
                ],
              ),
            ),
      trailing: const Icon(
        Icons.add_circle_outline,
        color: TetrisColors.accent,
      ),
    );
  }
}

class _TouchGestureTile extends StatelessWidget {
  const _TouchGestureTile({
    required this.gesture,
    required this.action,
    required this.onChanged,
  });

  final TouchGesture gesture;
  final GameAction? action;
  final ValueChanged<GameAction?> onChanged;

  @override
  Widget build(BuildContext context) {
    return TetrisPanel(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              gesture.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: TetrisColors.text, fontSize: 14),
            ),
          ),
          DropdownButton<GameAction?>(
            key: ValueKey('touch-gesture-${gesture.name}'),
            value: action,
            hint: const Text(
              'None',
              style: TextStyle(color: TetrisColors.mutedText, fontSize: 13),
            ),
            dropdownColor: TetrisColors.panel,
            style: const TextStyle(color: TetrisColors.text, fontSize: 13),
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              const DropdownMenuItem<GameAction?>(
                value: null,
                child: Text('None'),
              ),
              for (final candidate in GameAction.values)
                DropdownMenuItem<GameAction?>(
                  value: candidate,
                  child: Text(candidate.label),
                ),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TetrisButton(
        variant: TetrisButtonVariant.ghost,
        compact: true,
        icon: Icons.settings_backup_restore,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

class _FootnoteTile extends StatelessWidget {
  const _FootnoteTile(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: TetrisColors.mutedText,
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}
