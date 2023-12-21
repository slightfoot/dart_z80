import 'z80_cpu.dart';

/// Z80 CPU Flags
///
/// Stores all CPU Flags for the [Z80CPU]
///
/// Note: that the only way to read the [X], [Y] and [N] can
/// only be read using PUSH AF instruction.
///
class Z80Flags {
  /// Constructs a new [Z80Flags]
  Z80Flags({
    this.S = 0,
    this.Z = 0,
    this.Y = 0,
    this.H = 0,
    this.X = 0,
    this.P = 0,
    this.N = 0,
    this.C = 0,
  });

  /// Sign Flag
  ///
  /// Set if the 2-complement value is negative.
  /// It’s simply a copy of the most significant bit.
  int S;

  /// Zero Flag
  ///
  /// Set if the result is zero.
  int Z;

  /// Undocumented. Contains a copy of bit 5 of the result.
  int Y;

  /// Half Carry Flag
  ///
  /// The half-carry of an addition / subtraction (from bit 3 to 4).
  /// Needed for BCD correction with DAA.
  int H;

  /// Undocumented. Contains a copy of bit 3 of the result.
  int X;

  /// Parity / Overflow Flag
  ///
  /// This flag can either be the parity of the result (PF), or the 2-compliment
  /// signed overflow (VF): set if 2-compliment value doesnt fit in the register.
  int P;

  /// Add / Subtract Flag
  ///
  /// Shows whether the last operation was an addition (0) or an subtraction (1).
  /// This information is needed for DAA.
  int N;

  /// Carry Flag
  ///
  /// The carry flag, set if there was a carry after the most significant bit.
  int C;

  /// Clones the current CPU flags
  Z80Flags clone() {
    return Z80Flags(
      S: S,
      Z: Z,
      Y: Y,
      H: H,
      X: X,
      P: P,
      N: N,
      C: C,
    );
  }

  /// Loads the CPU flags from a [Map]
  factory Z80Flags.fromJson(Map<String, dynamic> flags) {
    return Z80Flags(
      S: flags['S'] as int,
      Z: flags['Z'] as int,
      Y: flags['Y'] as int,
      H: flags['H'] as int,
      X: flags['X'] as int,
      P: flags['P'] as int,
      N: flags['N'] as int,
      C: flags['C'] as int,
    );
  }

  /// Saves current CPU flags to a [Map]
  Map<String, dynamic> toJson() {
    return {
      'S': S,
      'Z': Z,
      'Y': Y,
      'H': H,
      'X': X,
      'P': P,
      'N': N,
      'C': C,
    };
  }
}
