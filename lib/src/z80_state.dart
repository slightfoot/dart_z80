part of 'z80_cpu.dart';

class Z80State {
  Z80State({
    int a = 0x00,
    int b = 0x00,
    int c = 0x00,
    int d = 0x00,
    int e = 0x00,
    int h = 0x00,
    int l = 0x00,
    int aPrime = 0x00,
    int bPrime = 0x00,
    int cPrime = 0x00,
    int dPrime = 0x00,
    int ePrime = 0x00,
    int hPrime = 0x00,
    int lPrime = 0x00,
    int ix = 0x0000,
    int iy = 0x0000,
    int i = 0x00,
    int r = 0x00,
    int sp = 0xdff0,
    int pc = 0x0000,
    Z80Flags? flags,
    Z80Flags? flagsPrime,
    int interruptMode = 0,
    int iff1 = 0,
    int iff2 = 0,
    bool halted = false,
    bool doDelayedDi = false,
    bool doDelayedEi = false,
    int cycleCounter = 0,
  })  : _a = a,
        _b = b,
        _c = c,
        _d = d,
        _e = e,
        _h = h,
        _l = l,
        _aPrime = aPrime,
        _bPrime = bPrime,
        _cPrime = cPrime,
        _dPrime = dPrime,
        _ePrime = ePrime,
        _hPrime = hPrime,
        _lPrime = lPrime,
        _ix = ix,
        _iy = iy,
        _i = i,
        _r = r,
        _sp = sp,
        _pc = pc,
        _flags = flags ?? Z80Flags(),
        _flagsPrime = flagsPrime ?? Z80Flags(),
        _interruptMode = interruptMode,
        _iff1 = iff1,
        _iff2 = iff2,
        _halted = halted,
        _doDelayedDi = doDelayedDi,
        _doDelayedEi = doDelayedEi,
        _cycleCounter = cycleCounter;

  // All right, let's initialize the registers.
  // First, the standard 8080 registers.
  int _a;
  int _b;
  int _c;
  int _d;
  int _e;
  int _h;
  int _l;

  // Now the special Z80 copies of the 8080 registers
  // (the ones used for the SWAP instruction and such).
  int _aPrime;
  int _bPrime;
  int _cPrime;
  int _dPrime;
  int _ePrime;
  int _hPrime;
  int _lPrime;

  // And now the Z80 index registers.
  int _ix;
  int _iy;

  // Then the "utility" registers: the interrupt vector,
  // the memory refresh, the stack pointer, and the program counter.
  int _i;
  int _r;
  int _sp;
  int _pc;

  // We don't keep an F register for the flags,
  // because most of the time we're only accessing a single flag,
  // so we optimize for that case and use utility functions
  // for the rarer occasions when we need to access the whole register.
  Z80Flags _flags;
  Z80Flags _flagsPrime;

  // And finally we have the interrupt mode and flip-flop registers.
  int _interruptMode;
  int _iff1;
  int _iff2;

  // These are all specific to this implementation, not Z80 features.
  // Keep track of whether we've had a HALT instruction called.
  bool _halted;

  // EI and DI wait one instruction before they take effect;
  // these flags tell us when we're in that wait state.
  bool _doDelayedDi;
  bool _doDelayedEi;

  // This tracks the number of cycles spent in a single instruction run,
  // including processing any prefixes and handling interrupts.
  int _cycleCounter;

  Z80State get state => clone();

  set state(Z80State value) {
    _a = value._a;
    _b = value._b;
    _c = value._c;
    _d = value._d;
    _e = value._e;
    _h = value._h;
    _l = value._l;
    _aPrime = value._aPrime;
    _bPrime = value._bPrime;
    _cPrime = value._cPrime;
    _dPrime = value._dPrime;
    _ePrime = value._ePrime;
    _hPrime = value._hPrime;
    _lPrime = value._lPrime;
    _ix = value._ix;
    _iy = value._iy;
    _i = value._i;
    _r = value._r;
    _sp = value._sp;
    _pc = value._pc;
    _flags = value._flags.clone();
    _flagsPrime = value._flagsPrime.clone();
    _interruptMode = value._interruptMode;
    _iff1 = value._iff1;
    _iff2 = value._iff2;
    _halted = value._halted;
    _doDelayedDi = value._doDelayedDi;
    _doDelayedEi = value._doDelayedEi;
    _cycleCounter = value._cycleCounter;
  }

  Z80State clone() {
    return Z80State(
      a: _a,
      b: _b,
      c: _c,
      d: _d,
      e: _e,
      h: _h,
      l: _l,
      aPrime: _aPrime,
      bPrime: _bPrime,
      cPrime: _cPrime,
      dPrime: _dPrime,
      ePrime: _ePrime,
      hPrime: _hPrime,
      lPrime: _lPrime,
      ix: _ix,
      iy: _iy,
      i: _i,
      r: _r,
      sp: _sp,
      pc: _pc,
      flags: _flags,
      flagsPrime: _flagsPrime,
      interruptMode: _interruptMode,
      iff1: _iff1,
      iff2: _iff2,
      halted: _halted,
      doDelayedDi: _doDelayedDi,
      doDelayedEi: _doDelayedEi,
      cycleCounter: _cycleCounter,
    );
  }

  factory Z80State.fromJson(Map<String, dynamic> state) {
    return Z80State(
      a: state['a'] as int,
      b: state['b'] as int,
      c: state['c'] as int,
      d: state['d'] as int,
      e: state['e'] as int,
      h: state['h'] as int,
      l: state['l'] as int,
      aPrime: state['a_prime'] as int,
      bPrime: state['b_prime'] as int,
      cPrime: state['c_prime'] as int,
      dPrime: state['d_prime'] as int,
      ePrime: state['e_prime'] as int,
      hPrime: state['h_prime'] as int,
      lPrime: state['l_prime'] as int,
      ix: state['ix'] as int,
      iy: state['iy'] as int,
      i: state['i'] as int,
      r: state['r'] as int,
      sp: state['sp'] as int,
      pc: state['pc'] as int,
      flags: Z80Flags.fromJson(state['flags']),
      flagsPrime: Z80Flags.fromJson(state['flags_prime']),
      interruptMode: state['imode'] as int,
      iff1: state['iff1'] as int,
      iff2: state['iff2'] as int,
      halted: state['halted'] as bool,
      doDelayedDi: state['do_delayed_di'] as bool,
      doDelayedEi: state['do_delayed_ei'] as bool,
      cycleCounter: state['cycle_counter'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'b': _b,
      'a': _a,
      'c': _c,
      'd': _d,
      'e': _e,
      'h': _h,
      'l': _l,
      'a_prime': _aPrime,
      'b_prime': _bPrime,
      'c_prime': _cPrime,
      'd_prime': _dPrime,
      'e_prime': _ePrime,
      'h_prime': _hPrime,
      'l_prime': _lPrime,
      'ix': _ix,
      'iy': _iy,
      'i': _i,
      'r': _r,
      'sp': _sp,
      'pc': _pc,
      'flags': _flags.toJson(),
      'flags_prime': _flagsPrime.toJson(),
      'imode': _interruptMode,
      'iff1': _iff1,
      'iff2': _iff2,
      'halted': _halted,
      'do_delayed_di': _doDelayedDi,
      'do_delayed_ei': _doDelayedEi,
      'cycle_counter': _cycleCounter
    };
  }

  @override
  String toString() {
    final hash = hashCode.toUnsigned(20).toRadixString(16).padLeft(5, '0');
    return 'Z80State($hash)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Z80State &&
          runtimeType == other.runtimeType &&
          _a == other._a &&
          _b == other._b &&
          _c == other._c &&
          _d == other._d &&
          _e == other._e &&
          _h == other._h &&
          _l == other._l &&
          _aPrime == other._aPrime &&
          _bPrime == other._bPrime &&
          _cPrime == other._cPrime &&
          _dPrime == other._dPrime &&
          _ePrime == other._ePrime &&
          _hPrime == other._hPrime &&
          _lPrime == other._lPrime &&
          _ix == other._ix &&
          _iy == other._iy &&
          _i == other._i &&
          _r == other._r &&
          _sp == other._sp &&
          _pc == other._pc &&
          _flags == other._flags &&
          _flagsPrime == other._flagsPrime &&
          _interruptMode == other._interruptMode &&
          _iff1 == other._iff1 &&
          _iff2 == other._iff2 &&
          _halted == other._halted &&
          _doDelayedDi == other._doDelayedDi &&
          _doDelayedEi == other._doDelayedEi &&
          _cycleCounter == other._cycleCounter;

  @override
  int get hashCode =>
      _a.hashCode ^
      _b.hashCode ^
      _c.hashCode ^
      _d.hashCode ^
      _e.hashCode ^
      _h.hashCode ^
      _l.hashCode ^
      _aPrime.hashCode ^
      _bPrime.hashCode ^
      _cPrime.hashCode ^
      _dPrime.hashCode ^
      _ePrime.hashCode ^
      _hPrime.hashCode ^
      _lPrime.hashCode ^
      _ix.hashCode ^
      _iy.hashCode ^
      _i.hashCode ^
      _r.hashCode ^
      _sp.hashCode ^
      _pc.hashCode ^
      _flags.hashCode ^
      _flagsPrime.hashCode ^
      _interruptMode.hashCode ^
      _iff1.hashCode ^
      _iff2.hashCode ^
      _halted.hashCode ^
      _doDelayedDi.hashCode ^
      _doDelayedEi.hashCode ^
      _cycleCounter.hashCode;
}
