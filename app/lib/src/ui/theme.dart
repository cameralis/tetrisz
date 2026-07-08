import 'dart:ui';

/// Shared palette for every screen. Pages must not redeclare these; gameplay
/// painters may keep private aliases pointed here so hot paths stay const.
abstract final class TetrisColors {
  static const background = Color(0xFF07080A);
  static const panel = Color(0xFF1B1D22);
  static const panelRaised = Color(0xFF272A31);
  static const text = Color(0xFFF3F6FA);
  static const mutedText = Color(0xFFA5ADBA);
  static const accent = Color(0xFF44D7FF);
  static const onAccent = Color(0xFF07080A);
  static const danger = Color(0xFFFF4D5E);
  static const ok = Color(0xFF58D957);
  static const outline = Color(0x33FFFFFF);
  static const outlineFaint = Color(0x14FFFFFF);
  static const gridLine = Color(0x12FFFFFF);

  /// Darker shades drawn as the bottom "edge" of chunky pressable surfaces,
  /// as if each control were a block resting on the board.
  static const accentEdge = Color(0xFF23768F);
  static const panelEdge = Color(0xFF0F1114);
  static const dangerEdge = Color(0xFF8C2A34);
}
