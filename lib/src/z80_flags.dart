class Z80Flags {
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

  int S;
  int Z;
  int Y;
  int H;
  int X;
  int P;
  int N;
  int C;

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
