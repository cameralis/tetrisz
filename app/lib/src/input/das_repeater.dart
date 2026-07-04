/// Delayed Auto Shift for held gamepad directions, using the Guideline's
/// recommended handling: a piece shifts once on press (applied by the
/// caller), auto-repeat starts after ~167 ms and then fires every ~33 ms
/// (30 Hz).
///
/// When both directions are held the most recent press wins; releasing it
/// hands control back to the still-held direction with a fresh charge.
class DasRepeater {
  DasRepeater({this.delay = defaultDelay, this.interval = defaultInterval});

  static const defaultDelay = Duration(milliseconds: 167);
  static const defaultInterval = Duration(milliseconds: 33);

  // Backstop against a single enormous frame delta flooding the board.
  static const _maxRepeatsPerPoll = 20;

  final Duration delay;
  final Duration interval;

  final List<int> _held = <int>[];
  Duration _countdown = Duration.zero;

  /// -1 while repeating left, 1 while repeating right, 0 when idle.
  int get activeDirection => _held.isEmpty ? 0 : _held.last;

  /// Records a press of [direction] (-1 or 1). The caller performs the
  /// immediate first shift itself; this only schedules the auto-repeat.
  void press(int direction) {
    _held.remove(direction);
    _held.add(direction);
    _countdown = delay;
  }

  void release(int direction) {
    final wasActive = activeDirection == direction;
    _held.remove(direction);
    if (wasActive && _held.isNotEmpty) {
      _countdown = delay;
    }
  }

  void reset() {
    _held.clear();
  }

  /// Advances the timer by [elapsed] and returns how many auto-repeat shifts
  /// of [activeDirection] are due. Call once per frame while input is
  /// accepted; skipping calls while blocked freezes the charge.
  int poll(Duration elapsed) {
    if (_held.isEmpty) {
      return 0;
    }
    _countdown -= elapsed;
    var repeats = 0;
    while (_countdown <= Duration.zero && repeats < _maxRepeatsPerPoll) {
      repeats += 1;
      _countdown += interval;
    }
    return repeats;
  }
}
