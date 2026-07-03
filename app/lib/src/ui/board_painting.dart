import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../game/tetromino.dart';

/// Shared low-level board painting helpers, used by the main board painter
/// in tetris_app.dart and the opponent mini-board in versus mode.

Rect cellRect(Offset origin, double cellSize, num x, num y) {
  return Rect.fromLTWH(
    origin.dx + x.toDouble() * cellSize,
    origin.dy + y.toDouble() * cellSize,
    cellSize,
    cellSize,
  );
}

void drawMino(
  Canvas canvas,
  Offset origin,
  double cellSize,
  num x,
  num y,
  Tetromino type,
) {
  final rect = cellRect(origin, cellSize, x, y).deflate(cellSize * 0.06);
  final radius = Radius.circular(cellSize * 0.14);
  final color = colorForTetromino(type);
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, radius),
    Paint()..color = color,
  );
  final highlight = Rect.fromLTWH(
    rect.left + cellSize * 0.08,
    rect.top + cellSize * 0.08,
    rect.width - cellSize * 0.16,
    math.max(1, rect.height * 0.18),
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(highlight, Radius.circular(cellSize * 0.08)),
    Paint()..color = Colors.white.withValues(alpha: 0.22),
  );
}

Color colorForTetromino(Tetromino type) {
  return switch (type) {
    Tetromino.i => const Color(0xFF43D9FF),
    Tetromino.j => const Color(0xFF3568FF),
    Tetromino.l => const Color(0xFFFF9E2C),
    Tetromino.o => const Color(0xFFFFE156),
    Tetromino.s => const Color(0xFF58D957),
    Tetromino.z => const Color(0xFFFF4D5E),
    Tetromino.t => const Color(0xFFD85BFF),
    Tetromino.garbage => const Color(0xFF7A8291),
  };
}
