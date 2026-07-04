import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gamepads/gamepads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../input/control_bindings.dart';
import '../input/gamepad_service.dart';

const _textColor = Color(0xFFF3F6FA);
const _mutedTextColor = Color(0xFFA5ADBA);
const _accentColor = Color(0xFF44D7FF);
const _panelColor = Color(0xFF1B1D22);

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
      if (!mounted) {
        return;
      }
      setState(() {
        _gamepadBindings = gamepadBindings;
        _touchBindings = touchBindings;
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
          style: TextStyle(color: _textColor, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeader('CONTROLLER'),
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
            const SizedBox(height: 20),
            const _SectionHeader('TOUCH'),
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
    return Card(
      color: _panelColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          Icons.sports_esports,
          color: _connected.isEmpty ? _mutedTextColor : _accentColor,
        ),
        title: Text(
          _connected.isEmpty ? 'No controller detected' : names,
          style: const TextStyle(color: _textColor, fontSize: 14),
        ),
        subtitle: Text(
          widget.gamepad == null
              ? 'Controller support is unavailable here.'
              : 'Xbox and PlayStation controllers work over Bluetooth or '
                    'USB. Tap an action below, then press the button to bind.',
          style: const TextStyle(color: _mutedTextColor, fontSize: 12),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.refresh, color: _mutedTextColor),
          onPressed: widget.gamepad == null
              ? null
              : () => unawaited(_refreshConnected()),
        ),
        isThreeLine: true,
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
      backgroundColor: _panelColor,
      title: Text(
        'Bind ${widget.action.label}',
        style: const TextStyle(color: _textColor, fontSize: 16),
      ),
      content: const Text(
        'Press a button, direction, or stick on your controller…',
        style: TextStyle(color: _mutedTextColor, fontSize: 13),
      ),
      actions: [
        TextButton(
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
    return Card(
      color: _panelColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('gamepad-action-${action.name}'),
        onTap: captureEnabled ? onCapture : null,
        title: Text(
          action.label,
          style: const TextStyle(color: _textColor, fontSize: 14),
        ),
        subtitle: controls.isEmpty
            ? const Text(
                'Not bound',
                style: TextStyle(color: _mutedTextColor, fontSize: 12),
              )
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
                          color: _textColor,
                          fontSize: 11,
                        ),
                        backgroundColor: const Color(0xFF272A31),
                        side: const BorderSide(color: Color(0x22FFFFFF)),
                        deleteIconColor: _mutedTextColor,
                        onDeleted: () => onUnbind(control),
                      ),
                  ],
                ),
              ),
        trailing: Icon(
          Icons.add_circle_outline,
          color: captureEnabled ? _accentColor : _mutedTextColor,
        ),
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
    return Card(
      color: _panelColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                gesture.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _textColor, fontSize: 14),
              ),
            ),
            DropdownButton<GameAction?>(
              key: ValueKey('touch-gesture-${gesture.name}'),
              value: action,
              hint: const Text(
                'None',
                style: TextStyle(color: _mutedTextColor, fontSize: 13),
              ),
              dropdownColor: _panelColor,
              style: const TextStyle(color: _textColor, fontSize: 13),
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
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.settings_backup_restore, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(foregroundColor: _accentColor),
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
          color: _mutedTextColor,
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: _mutedTextColor,
          fontSize: 11,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
