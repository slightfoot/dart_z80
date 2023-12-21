/// Emulator for the Zilog Z80 microprocessor.
///
/// Author: Molly Howell
/// Ported to Dart: Simon Lightfoot
///
/// Remarks:
///  This module is a simple, straightforward instruction interpreter.
///  There is no fancy dynamic recompilation or cycle-accurate emulation.
///
///  The code and the comments in this file assume that the reader is familiar
///  with the Z80 architecture. If you're not, here are some references I use:
///
///  Z80 instruction set tables
///     http://clrhome.org/table/
///
///  The official manual
///     http://www.zilog.com/docs/z80/um0080.pdf
///
///  The Undocumented Z80, Documented
///     http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf
///
/// Copyright (C) Molly Howell
///
/// This code is released under the MIT license,
/// a copy of which is available in the associated LICENSE file,
/// or at http://opensource.org/licenses/MIT
///
library;

import 'package:z80/src/z80_core.dart';
import 'package:z80/src/z80_flags.dart';

part 'z80_state.dart';

typedef Z80Instruction = void Function();

class Z80CPU extends Z80State {
  Z80CPU(this._core) {
    _setupInstructions();
    _setupInstructionsED();
    _setupInstructionsDD();
  }

  final Z80Core _core;

  late final List<Z80Instruction> _instructions;
  late final List<Z80Instruction?> _instructionsED;
  late final List<Z80Instruction?> _instructionsDD;

  /// Reset CPU
  ///
  /// Re-initialize the processor as if a reset or power on had occurred.
  void reset() {
    // These registers are the ones that have predictable states
    //  immediately following a power-on or a reset.
    // The others are left alone, because their states are unpredictable.
    _sp = 0xdff0;
    _pc = 0x0000;
    _a = 0x00;
    _r = 0x00;
    _flagsReg = 0;
    // Start up with interrupts disabled.
    _interruptMode = 0;
    _iff1 = 0;
    _iff2 = 0;
    // Don't start halted or in a delayed DI or EI.
    _halted = false;
    _doDelayedDi = false;
    _doDelayedEi = false;
    // Obviously we've not used any cycles yet.
    _cycleCounter = 0;
  }

  /// Runs a single instruction
  ///
  /// The number of T cycles the instruction took to run, plus any
  /// time that went into handling interrupts that fired while
  /// this instruction was executing
  int runInstruction() {
    if (!_halted) {
      // If the previous instruction was a DI or an EI,
      //  we'll need to disable or enable interrupts
      //  after whatever instruction we're about to run is finished.
      var doingDelayedDi = false, doingDelayedEi = false;
      if (_doDelayedDi) {
        _doDelayedDi = false;
        doingDelayedDi = true;
      } else if (_doDelayedEi) {
        _doDelayedEi = false;
        doingDelayedEi = true;
      }
      // R is incremented at the start of every instruction cycle,
      // before the instruction actually runs.
      //
      // The high bit of R is not affected by this increment,
      // it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      // Read the byte at the PC and run the instruction it encodes.
      final opcode = _core.memRead(_pc);
      _decodeInstruction(opcode);
      _pc = (_pc + 1) & 0xffff;
      // Actually do the delayed interrupt disable/enable if we have one.
      if (doingDelayedDi) {
        _iff1 = 0;
        _iff2 = 0;
      } else if (doingDelayedEi) {
        _iff1 = 1;
        _iff2 = 1;
      }
      // And finally clear out the cycle counter for the next instruction
      //  before returning it to the emulator core.
      final retValue = _cycleCounter;
      _cycleCounter = 0;
      return retValue;
    } else {
      // While we're halted, claim that we spent a cycle doing nothing,
      //  so that the rest of the emulator can still proceed.
      return 1;
    }
  }

  /// Simulates pulsing the processor's INT (or NMI) pin
  ///
  /// [nonMaskable] - true if this is a non-maskable interrupt
  /// [data] - the value to be placed on the data bus, if needed
  void interrupt(bool nonMaskable, int data) {
    if (nonMaskable) {
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      // Non-maskable interrupts are always handled the same way;
      //  clear IFF1 and then do a CALL 0x0066.
      // Also, all interrupts reset the HALT state.
      _halted = false;
      _iff2 = _iff1;
      _iff1 = 0;
      _pushWord(_pc);
      _pc = 0x66;
      _cycleCounter += 11;
    } else if (_iff1 != 0) {
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      _halted = false;
      _iff1 = 0;
      _iff2 = 0;
      if (_interruptMode == 0) {
        // In the 8080-compatible interrupt mode,
        //  decode the content of the data bus as an instruction and run it.
        // it's probably a RST instruction, which pushes (PC+1) onto the stack
        // so we should decrement PC before we decode the instruction
        _pc = (_pc - 1) & 0xffff;
        _decodeInstruction(data);
        _pc = (_pc + 1) & 0xffff; // increment PC upon return
        _cycleCounter += 2;
      } else if (_interruptMode == 1) {
        // Mode 1 is always just RST 0x38.
        _pushWord(_pc);
        _pc = 0x38;
        _cycleCounter += 13;
      } else if (_interruptMode == 2) {
        // Mode 2 uses the value on the data bus as in index
        //  into the vector table pointer to by the I register.
        _pushWord(_pc);
        // The Z80 manual says that this address must be 2-byte aligned,
        //  but it doesn't appear that this is actually the case on the hardware,
        //  so we don't attempt to enforce that here.
        var vectorAddress = ((_i << 8) | data);
        _pc = _core.memRead(vectorAddress) | (_core.memRead((vectorAddress + 1) & 0xffff) << 8);
        _cycleCounter += 19;
      }
    }
  }

  void _decodeInstruction(int opcode) {
    // The register-to-register loads and ALU instructions
    // are all so uniform that we can decode them directly
    // instead of going into the instruction array for them.
    //
    // This function gets the operand for all of these instructions.
    int getOperand(int opcode) {
      switch (opcode & 0x07) {
        case 0:
          return _b;
        case 1:
          return _c;
        case 2:
          return _d;
        case 3:
          return _e;
        case 4:
          return _h;
        case 5:
          return _l;
        case 6:
          return _core.memRead(_l | (_h << 8));
        default:
          return _a;
      }
    }

    // Handle HALT right up front, because it fouls up our LD decoding
    //  by falling where LD (HL), (HL) ought to be.
    if (opcode == 0x76) {
      _halted = true;
    } else if ((opcode >= 0x40) && (opcode < 0x80)) {
      // This entire range is all 8-bit register loads.
      // Get the operand and assign it to the correct destination.
      var operand = getOperand(opcode);
      switch ((opcode & 0x38) >> 3) {
        case 0:
          _b = operand;
          break;
        case 1:
          _c = operand;
          break;
        case 2:
          _d = operand;
          break;
        case 3:
          _e = operand;
          break;
        case 4:
          _h = operand;
          break;
        case 5:
          _l = operand;
          break;
        case 6:
          _core.memWrite(_l | (_h << 8), operand);
          break;
        case 7:
          _a = operand;
          break;
      }
    } else if ((opcode >= 0x80) && (opcode < 0xc0)) {
      // These are the 8-bit register ALU instructions.
      // We'll get the operand and then use this "jump table"
      //  to call the correct utility function for the instruction.
      var operand = getOperand(opcode),
          opArray = [_doAdd, _doAddCarry, _doSub, _doSubCarry, _doAnd, _doXor, _doOr, _doCompare];
      opArray[(opcode & 0x38) >> 3](operand);
    } else {
      // This is one of the less formulaic instructions;
      // we'll get the specific function for it from our array.
      _instructions[opcode]();
    }
    // Update the cycle counter with however many cycles
    // the base instruction took.
    //
    // If this was a prefixed instruction, then
    // the prefix handler has added its extra cycles already.
    _cycleCounter += cycleCounts[opcode];
  }

  int _getSignedOffsetByte(int value) {
    // This function requires some explanation.
    // We just use JavaScript Number variables for our registers,
    // not like a typed array or anything.
    //
    // That means that, when we have a byte value that's supposed
    // to represent a signed offset, the value we actually see
    // isn't signed at all, it's just a small integer.
    //
    // So, this function converts that byte into something JavaScript
    // will recognize as signed, so we can easily do arithmetic with it.
    //
    // First, we clamp the value to a single byte, just in case.
    value &= 0xff;
    // We don't have to do anything if the value is positive.
    if (value & 0x80 != 0) {
      // But if the value is negative, we need to manually un-two's-compliment it.
      // I'm going to assume you can figure out what I meant by that,
      // because I don't know how else to explain it.
      //
      // We could also just do value |= 0xffffff00, but I prefer
      // not caring how many bits are in the integer representation
      // of a JavaScript number in the currently running browser.
      value = -((0xff & ~value) + 1);
    }
    return value;
  }

  // We need the whole F register for some reason. Probably a
  // PUSH AF instruction, so make the F register out of
  // our separate flags.
  int get _flagsReg =>
      (_flags.S << 7) |
      (_flags.Z << 6) |
      (_flags.Y << 5) |
      (_flags.H << 4) |
      (_flags.X << 3) |
      (_flags.P << 2) |
      (_flags.N << 1) |
      (_flags.C);

  // This is the same as the above for the F' register.
  int get _flagsPrimeReg =>
      (_flagsPrime.S << 7) |
      (_flagsPrime.Z << 6) |
      (_flagsPrime.Y << 5) |
      (_flagsPrime.H << 4) |
      (_flagsPrime.X << 3) |
      (_flagsPrime.P << 2) |
      (_flagsPrime.N << 1) |
      (_flagsPrime.C);

  // We need to set the F register, probably for a POP AF,
  //  so break out the given value into our separate flags.
  set _flagsReg(int operand) {
    _flags.S = (operand & 0x80) >> 7;
    _flags.Z = (operand & 0x40) >> 6;
    _flags.Y = (operand & 0x20) >> 5;
    _flags.H = (operand & 0x10) >> 4;
    _flags.X = (operand & 0x08) >> 3;
    _flags.P = (operand & 0x04) >> 2;
    _flags.N = (operand & 0x02) >> 1;
    _flags.C = (operand & 0x01);
  }

  // Again, this is the same as the above for F'.
  set _flagsPrimeReg(int operand) {
    _flagsPrime.S = (operand & 0x80) >> 7;
    _flagsPrime.Z = (operand & 0x40) >> 6;
    _flagsPrime.Y = (operand & 0x20) >> 5;
    _flagsPrime.H = (operand & 0x10) >> 4;
    _flagsPrime.X = (operand & 0x08) >> 3;
    _flagsPrime.P = (operand & 0x04) >> 2;
    _flagsPrime.N = (operand & 0x02) >> 1;
    _flagsPrime.C = (operand & 0x01);
  }

  set _flagsXY(int result) {
    // Most of the time, the undocumented flags (sometimes called X and Y,
    // or 3 and 5), take their values from the corresponding bits of the
    // result of the instruction, or from some other related value.
    //
    // This is a utility function to set those flags based on those bits.
    _flags.Y = (result & 0x20) >> 5;
    _flags.X = (result & 0x08) >> 3;
  }

  int _parity(int value) {
    // We could try to actually calculate the parity every time,
    // but why calculate what you can pre-calculate?
    const parityBits = <int>[
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0, //
      1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, //
    ];
    return parityBits[value];
  }

  void _pushWord(int operand) {
    // Pretty obvious what this function does; given a 16-bit value,
    // decrement the stack pointer, write the high byte to the new
    // stack pointer location, then repeat for the low byte.
    _sp = (_sp - 1) & 0xffff;
    _core.memWrite(_sp, (operand & 0xff00) >> 8);
    _sp = (_sp - 1) & 0xffff;
    _core.memWrite(_sp, operand & 0x00ff);
  }

  int _popWord() {
    // Again, not complicated; read a byte off the top of the stack,
    // increment the stack pointer, rinse and repeat.
    var value = _core.memRead(_sp) & 0xff;
    _sp = (_sp + 1) & 0xffff;
    value |= _core.memRead(_sp) << 8;
    _sp = (_sp + 1) & 0xffff;
    return value;
  }

  /// Now, the way most instructions work in this emulator is that they set up
  /// their operands according to their addressing mode, and then they call a
  /// utility function that handles all variations of that instruction.
  ///
  /// Those utility functions begin here.
  void _doCondAbsJump(bool condition) {
    // This function implements the JP [condition],nn instructions.
    if (condition) {
      // We're taking this jump, so write the new PC,
      //  and then decrement the thing we just wrote,
      //  because the instruction decoder increments the PC
      //  unconditionally at the end of every instruction
      //  and we need to counteract that so we end up at the jump target.
      _pc = _core.memRead((_pc + 1) & 0xffff) | (_core.memRead((_pc + 2) & 0xffff) << 8);
      _pc = (_pc - 1) & 0xffff;
    } else {
      // We're not taking this jump, just move the PC past the operand.
      _pc = (_pc + 2) & 0xffff;
    }
  }

  void _doCondRelJump(bool condition) {
    // This function implements the JR [condition],n instructions.
    if (condition) {
      // We need a few more cycles to actually take the jump.
      _cycleCounter += 5;
      // Calculate the offset specified by our operand.
      var offset = _getSignedOffsetByte(_core.memRead((_pc + 1) & 0xffff));
      // Add the offset to the PC, also skipping past this instruction.
      _pc = (_pc + offset + 1) & 0xffff;
    } else {
      // No jump happening, just skip the operand.
      _pc = (_pc + 1) & 0xffff;
    }
  }

  void _doCondCall(bool condition) {
    // This function is the CALL [condition],nn instructions.
    // If you've seen the previous functions, you know this drill.
    if (condition) {
      _cycleCounter += 7;
      _pushWord((_pc + 3) & 0xffff);
      _pc = _core.memRead((_pc + 1) & 0xffff) | (_core.memRead((_pc + 2) & 0xffff) << 8);
      _pc = (_pc - 1) & 0xffff;
    } else {
      _pc = (_pc + 2) & 0xffff;
    }
  }

  void _doCondReturn(bool condition) {
    if (condition) {
      _cycleCounter += 6;
      _pc = (_popWord() - 1) & 0xffff;
    }
  }

  void _doReset(int address) {
    // The RST [address] instructions go through here.
    _pushWord((_pc + 1) & 0xffff);
    _pc = (address - 1) & 0xffff;
  }

  void _doAdd(int operand) {
    // This is the ADD A, [operand] instructions.
    // We'll do the literal addition, which includes any overflow,
    //  so that we can more easily figure out whether we had
    //  an overflow or a carry and set the flags accordingly.
    var result = _a + operand;

    // The great majority of the work for the arithmetic instructions
    //  turns out to be setting the flags rather than the actual operation.
    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = (((operand & 0x0f) + (_a & 0x0f)) & 0x10) != 0 ? 1 : 0;
    // An overflow has happened if the sign bits of the accumulator and the operand
    //  don't match the sign bit of the result value.
    _flags.P = ((_a & 0x80) == (operand & 0x80)) && ((_a & 0x80) != (result & 0x80)) ? 1 : 0;
    _flags.N = 0;
    _flags.C = (result & 0x100) != 0 ? 1 : 0;

    _a = result & 0xff;
    _flagsXY = _a;
  }

  void _doAddCarry(int operand) {
    var result = _a + operand + _flags.C;

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = (((operand & 0x0f) + (_a & 0x0f) + _flags.C) & 0x10) != 0 ? 1 : 0;
    _flags.P = ((_a & 0x80) == (operand & 0x80)) && ((_a & 0x80) != (result & 0x80)) ? 1 : 0;
    _flags.N = 0;
    _flags.C = (result & 0x100) != 0 ? 1 : 0;

    _a = result & 0xff;
    _flagsXY = _a;
  }

  void _doSub(int operand) {
    var result = _a - operand;

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = (((_a & 0x0f) - (operand & 0x0f)) & 0x10) != 0 ? 1 : 0;
    _flags.P = ((_a & 0x80) != (operand & 0x80)) && ((_a & 0x80) != (result & 0x80)) ? 1 : 0;
    _flags.N = 1;
    _flags.C = (result & 0x100) != 0 ? 1 : 0;

    _a = result & 0xff;
    _flagsXY = _a;
  }

  void _doSubCarry(int operand) {
    var result = _a - operand - _flags.C;

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = (((_a & 0x0f) - (operand & 0x0f) - _flags.C) & 0x10) != 0 ? 1 : 0;
    _flags.P = ((_a & 0x80) != (operand & 0x80)) && ((_a & 0x80) != (result & 0x80)) ? 1 : 0;
    _flags.N = 1;
    _flags.C = (result & 0x100) != 0 ? 1 : 0;

    _a = result & 0xff;
    _flagsXY = _a;
  }

  void _doCompare(int operand) {
    // A compare instruction is just a subtraction that doesn't save the value,
    //  so we implement it as... a subtraction that doesn't save the value.
    var temp = _a;
    _doSub(operand);
    _a = temp;
    // Since this instruction has no "result" value, the undocumented flags
    //  are set based on the operand instead.
    _flagsXY = operand;
  }

  void _doAnd(int operand) {
    // The logic instructions are all pretty straightforward.
    _a &= operand & 0xff;
    _flags.S = (_a & 0x80) != 0 ? 1 : 0;
    _flags.Z = _a == 0 ? 1 : 0;
    _flags.H = 1;
    _flags.P = _parity(_a);
    _flags.N = 0;
    _flags.C = 0;
    _flagsXY = _a;
  }

  void _doOr(int operand) {
    _a = (operand | _a) & 0xff;
    _flags.S = (_a & 0x80) != 0 ? 1 : 0;
    _flags.Z = _a == 0 ? 1 : 0;
    _flags.H = 0;
    _flags.P = _parity(_a);
    _flags.N = 0;
    _flags.C = 0;
    _flagsXY = _a;
  }

  void _doXor(int operand) {
    _a = (operand ^ _a) & 0xff;
    _flags.S = (_a & 0x80) != 0 ? 1 : 0;
    _flags.Z = _a == 0 ? 1 : 0;
    _flags.H = 0;
    _flags.P = _parity(_a);
    _flags.N = 0;
    _flags.C = 0;
    _flagsXY = _a;
  }

  int _doInc(int operand) {
    var result = operand + 1;

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = ((operand & 0x0f) == 0x0f) ? 1 : 0;
    // It's a good deal easier to detect overflow for an increment/decrement.
    _flags.P = (operand == 0x7f) ? 1 : 0;
    _flags.N = 0;

    result &= 0xff;
    _flagsXY = result;

    return result;
  }

  int _doDec(int operand) {
    var result = operand - 1;

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = (result & 0xff) == 0 ? 1 : 0;
    _flags.H = ((operand & 0x0f) == 0x00) ? 1 : 0;
    _flags.P = (operand == 0x80) ? 1 : 0;
    _flags.N = 1;

    result &= 0xff;
    _flagsXY = result;

    return result;
  }

  void _doHlAdd(int operand) {
    // The HL arithmetic instructions are the same as the A ones,
    //  just with twice as many bits happening.
    var hl = _l | (_h << 8), result = hl + operand;

    _flags.N = 0;
    _flags.C = (result & 0x10000) != 0 ? 1 : 0;
    _flags.H = (((hl & 0x0fff) + (operand & 0x0fff)) & 0x1000) != 0 ? 1 : 0;

    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;

    _flagsXY = _h;
  }

  void _doHlAddCarry(int operand) {
    operand += _flags.C;
    var hl = _l | (_h << 8), result = hl + operand;

    _flags.S = (result & 0x8000) != 0 ? 1 : 0;
    _flags.Z = (result & 0xffff) == 0 ? 1 : 0;
    _flags.H = (((hl & 0x0fff) + (operand & 0x0fff)) & 0x1000) != 0 ? 1 : 0;
    _flags.P =
        ((hl & 0x8000) == (operand & 0x8000)) && ((result & 0x8000) != (hl & 0x8000)) ? 1 : 0;
    _flags.N = 0;
    _flags.C = (result & 0x10000) != 0 ? 1 : 0;

    _l = result & 0xff;
    _h = (result >> 8) & 0xff;

    _flagsXY = _h;
  }

  void _doHlSubtractCarry(int operand) {
    operand += _flags.C;
    var hl = _l | (_h << 8), result = hl - operand;

    _flags.S = (result & 0x8000) != 0 ? 1 : 0;
    _flags.Z = (result & 0xffff) == 0 ? 1 : 0;
    _flags.H = (((hl & 0x0fff) - (operand & 0x0fff)) & 0x1000) != 0 ? 1 : 0;
    _flags.P =
        (((hl & 0x8000) != (operand & 0x8000)) && ((result & 0x8000) != (hl & 0x8000))) ? 1 : 0;
    _flags.N = 1;
    _flags.C = (result & 0x10000) != 0 ? 1 : 0;

    _l = result & 0xff;
    _h = (result >> 8) & 0xff;

    _flagsXY = _h;
  }

  int _doIn(int port) {
    var result = _core.ioRead(port);

    _flags.S = (result & 0x80) != 0 ? 1 : 0;
    _flags.Z = result != 0 ? 0 : 1;
    _flags.H = 0;
    _flags.P = _parity(result);
    _flags.N = 0;
    _flagsXY = result;

    return result;
  }

  void _doNegate() {
    // This instruction is defined to not alter the register if it == 0x80.
    if (_a != 0x80) {
      // This is a signed operation, so convert A to a signed value.
      _a = _getSignedOffsetByte(_a);
      _a = (-_a) & 0xff;
    }
    _flags.S = (_a & 0x80) != 0 ? 1 : 0;
    _flags.Z = _a == 0 ? 1 : 0;
    _flags.H = (((-_a) & 0x0f) > 0) ? 1 : 0;
    _flags.P = (_a == 0x80) ? 1 : 0;
    _flags.N = 1;
    _flags.C = _a != 0 ? 1 : 0;
    _flagsXY = _a;
  }

  void _doLoadI() {
    // Copy the value that we're supposed to copy.
    var readValue = _core.memRead(_l | (_h << 8));
    _core.memWrite(_e | (_d << 8), readValue);

    // Increment DE and HL, and decrement BC.
    var result = (_e | (_d << 8)) + 1;
    _e = result & 0xff;
    _d = (result & 0xff00) >> 8;
    result = (_l | (_h << 8)) + 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;
    result = (_c | (_b << 8)) - 1;
    _c = result & 0xff;
    _b = (result & 0xff00) >> 8;

    _flags.H = 0;
    _flags.P = (_c | _b) != 0 ? 1 : 0;
    _flags.N = 0;
    _flags.Y = ((_a + readValue) & 0x02) >> 1;
    _flags.X = ((_a + readValue) & 0x08) >> 3;
  }

  void _doCompareI() {
    var tempCarry = _flags.C;
    var readValue = _core.memRead(_l | (_h << 8));
    _doCompare(readValue);
    _flags.C = tempCarry;
    _flags.Y = ((_a - readValue - _flags.H) & 0x02) >> 1;
    _flags.X = ((_a - readValue - _flags.H) & 0x08) >> 3;

    var result = (_l | (_h << 8)) + 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;
    result = (_c | (_b << 8)) - 1;
    _c = result & 0xff;
    _b = (result & 0xff00) >> 8;

    _flags.P = result != 0 ? 1 : 0;
  }

  void _doInI() {
    _b = _doDec(_b);

    _core.memWrite(_l | (_h << 8), _core.ioRead((_b << 8) | _c));

    var result = (_l | (_h << 8)) + 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;

    _flags.N = 1;
  }

  void _doOutI() {
    _core.ioWrite((_b << 8) | _c, _core.memRead(_l | (_h << 8)));

    var result = (_l | (_h << 8)) + 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;

    _b = _doDec(_b);
    _flags.N = 1;
  }

  void _doLoadD() {
    _flags.N = 0;
    _flags.H = 0;

    var readValue = _core.memRead(_l | (_h << 8));
    _core.memWrite(_e | (_d << 8), readValue);

    var result = (_e | (_d << 8)) - 1;
    _e = result & 0xff;
    _d = (result & 0xff00) >> 8;
    result = (_l | (_h << 8)) - 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;
    result = (_c | (_b << 8)) - 1;
    _c = result & 0xff;
    _b = (result & 0xff00) >> 8;

    _flags.P = (_c | _b) != 0 ? 1 : 0;
    _flags.Y = ((_a + readValue) & 0x02) >> 1;
    _flags.X = ((_a + readValue) & 0x08) >> 3;
  }

  void _doCompareD() {
    var tempCarry = _flags.C;
    var readValue = _core.memRead(_l | (_h << 8));
    _doCompare(readValue);
    _flags.C = tempCarry;
    _flags.Y = ((_a - readValue - _flags.H) & 0x02) >> 1;
    _flags.X = ((_a - readValue - _flags.H) & 0x08) >> 3;

    var result = (_l | (_h << 8)) - 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;
    result = (_c | (_b << 8)) - 1;
    _c = result & 0xff;
    _b = (result & 0xff00) >> 8;

    _flags.P = result != 0 ? 1 : 0;
  }

  void _doInD() {
    _b = _doDec(_b);

    _core.memWrite(_l | (_h << 8), _core.ioRead((_b << 8) | _c));

    var result = (_l | (_h << 8)) - 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;

    _flags.N = 1;
  }

  void _doOutD() {
    _core.ioWrite((_b << 8) | _c, _core.memRead(_l | (_h << 8)));

    var result = (_l | (_h << 8)) - 1;
    _l = result & 0xff;
    _h = (result & 0xff00) >> 8;

    _b = _doDec(_b);
    _flags.N = 1;
  }

  int _doRlc(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = (operand & 0x80) >> 7;
    operand = ((operand << 1) | _flags.C) & 0xff;

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doRrc(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = operand & 1;
    operand = ((operand >> 1) & 0x7f) | (_flags.C << 7);

    _flags.Z = (operand & 0xff) == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand & 0xff;
  }

  int _doRl(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    var temp = _flags.C;
    _flags.C = (operand & 0x80) >> 7;
    operand = ((operand << 1) | temp) & 0xff;

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doRr(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    var temp = _flags.C;
    _flags.C = operand & 1;
    operand = ((operand >> 1) & 0x7f) | (temp << 7);

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doSla(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = (operand & 0x80) >> 7;
    operand = (operand << 1) & 0xff;

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doSra(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = operand & 1;
    operand = ((operand >> 1) & 0x7f) | (operand & 0x80);

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doSll(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = (operand & 0x80) >> 7;
    operand = ((operand << 1) & 0xff) | 1;

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = (operand & 0x80) != 0 ? 1 : 0;
    _flagsXY = operand;

    return operand;
  }

  int _doSrl(int operand) {
    _flags.N = 0;
    _flags.H = 0;

    _flags.C = operand & 1;
    operand = (operand >> 1) & 0x7f;

    _flags.Z = operand == 0 ? 1 : 0;
    _flags.P = _parity(operand);
    _flags.S = 0;
    _flagsXY = operand;

    return operand;
  }

  void _doIxAdd(int operand) {
    _flags.N = 0;

    var result = _ix + operand;

    _flags.C = (result & 0x10000) != 0 ? 1 : 0;
    _flags.H = (((_ix & 0xfff) + (operand & 0xfff)) & 0x1000) != 0 ? 1 : 0;
    _flagsXY = ((result & 0xff00) >> 8);

    _ix = result;
  }

  /// This table contains the implementations for the instructions that weren't
  /// implemented directly in the decoder function (everything but the 8-bit
  /// register loads and the accumulator ALU instructions, in other words).
  ///
  /// Similar tables for the ED and DD/FD prefixes follow this one.
  void _setupInstructions() {
    void nop() {}
    _instructions = List.filled(256, nop);
    // 0x00 : NOP
    _instructions[0x00] = nop;
    // 0x01 : LD BC, nn
    _instructions[0x01] = () {
      _pc = (_pc + 1) & 0xffff;
      _c = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      _b = _core.memRead(_pc);
    };
    // 0x02 : LD (BC), A
    _instructions[0x02] = () => _core.memWrite(_c | (_b << 8), _a);
    // 0x03 : INC BC
    _instructions[0x03] = () {
      var result = (_c | (_b << 8));
      result += 1;
      _c = result & 0xff;
      _b = (result & 0xff00) >> 8;
    };
    // 0x04 : INC B
    _instructions[0x04] = () => _b = _doInc(_b);
    // 0x05 : DEC B
    _instructions[0x05] = () => _b = _doDec(_b);
    // 0x06 : LD B, n
    _instructions[0x06] = () {
      _pc = (_pc + 1) & 0xffff;
      _b = _core.memRead(_pc);
    };
    // 0x07 : RLCA
    _instructions[0x07] = () {
      // This instruction is implemented as a special case of the
      // more general Z80-specific RLC instruction.
      // Specifically, RLCA is a version of RLC A that affects fewer flags.
      // The same applies to RRCA, RLA, and RRA.
      var tempS = _flags.S, tempZ = _flags.Z, tempP = _flags.P;
      _a = _doRlc(_a);
      _flags.S = tempS;
      _flags.Z = tempZ;
      _flags.P = tempP;
    };
    // 0x08 : EX AF, AF'
    _instructions[0x08] = () {
      var temp = _a;
      _a = _aPrime;
      _aPrime = temp;
      temp = _flagsReg;
      _flagsReg = _flagsPrimeReg;
      _flagsPrimeReg = temp;
    };
    // 0x09 : ADD HL, BC
    _instructions[0x09] = () => _doHlAdd(_c | (_b << 8));
    // 0x0a : LD A, (BC)
    _instructions[0x0a] = () => _a = _core.memRead(_c | (_b << 8));
    // 0x0b : DEC BC
    _instructions[0x0b] = () {
      var result = (_c | (_b << 8));
      result -= 1;
      _c = result & 0xff;
      _b = (result & 0xff00) >> 8;
    };
    // 0x0c : INC C
    _instructions[0x0c] = () => _c = _doInc(_c);
    // 0x0d : DEC C
    _instructions[0x0d] = () => _c = _doDec(_c);
    // 0x0e : LD C, n
    _instructions[0x0e] = () {
      _pc = (_pc + 1) & 0xffff;
      _c = _core.memRead(_pc);
    };
    // 0x0f : RRCA
    _instructions[0x0f] = () {
      var tempS = _flags.S, tempZ = _flags.Z, tempP = _flags.P;
      _a = _doRrc(_a);
      _flags.S = tempS;
      _flags.Z = tempZ;
      _flags.P = tempP;
    };
    // 0x10 : DJNZ nn
    _instructions[0x10] = () {
      _b = (_b - 1) & 0xff;
      _doCondRelJump(_b != 0);
    };
    // 0x11 : LD DE, nn
    _instructions[0x11] = () {
      _pc = (_pc + 1) & 0xffff;
      _e = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      _d = _core.memRead(_pc);
    };
    // 0x12 : LD (DE), A
    _instructions[0x12] = () => _core.memWrite(_e | (_d << 8), _a);
    // 0x13 : INC DE
    _instructions[0x13] = () {
      var result = (_e | (_d << 8));
      result += 1;
      _e = result & 0xff;
      _d = (result & 0xff00) >> 8;
    };
    // 0x14 : INC D
    _instructions[0x14] = () => _d = _doInc(_d);
    // 0x15 : DEC D
    _instructions[0x15] = () => _d = _doDec(_d);
    // 0x16 : LD D, n
    _instructions[0x16] = () {
      _pc = (_pc + 1) & 0xffff;
      _d = _core.memRead(_pc);
    };
    // 0x17 : RLA
    _instructions[0x17] = () {
      var tempS = _flags.S, tempZ = _flags.Z, tempP = _flags.P;
      _a = _doRl(_a);
      _flags.S = tempS;
      _flags.Z = tempZ;
      _flags.P = tempP;
    };
    // 0x18 : JR n
    _instructions[0x18] = () {
      var offset = _getSignedOffsetByte(_core.memRead((_pc + 1) & 0xffff));
      _pc = (_pc + offset + 1) & 0xffff;
    };
    // 0x19 : ADD HL, DE
    _instructions[0x19] = () => _doHlAdd(_e | (_d << 8));
    // 0x1a : LD A, (DE)
    _instructions[0x1a] = () => _a = _core.memRead(_e | (_d << 8));
    // 0x1b : DEC DE
    _instructions[0x1b] = () {
      var result = (_e | (_d << 8));
      result -= 1;
      _e = result & 0xff;
      _d = (result & 0xff00) >> 8;
    };
    // 0x1c : INC E
    _instructions[0x1c] = () => _e = _doInc(_e);
    // 0x1d : DEC E
    _instructions[0x1d] = () => _e = _doDec(_e);
    // 0x1e : LD E, n
    _instructions[0x1e] = () {
      _pc = (_pc + 1) & 0xffff;
      _e = _core.memRead(_pc);
    };
    // 0x1f : RRA
    _instructions[0x1f] = () {
      var tempS = _flags.S, tempZ = _flags.Z, tempP = _flags.P;
      _a = _doRr(_a);
      _flags.S = tempS;
      _flags.Z = tempZ;
      _flags.P = tempP;
    };
    // 0x20 : JR NZ, n
    _instructions[0x20] = () => _doCondRelJump(_flags.Z == 0);
    // 0x21 : LD HL, nn
    _instructions[0x21] = () {
      _pc = (_pc + 1) & 0xffff;
      _l = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      _h = _core.memRead(_pc);
    };
    // 0x22 : LD (nn), HL
    _instructions[0x22] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _core.memWrite(address, _l);
      _core.memWrite((address + 1) & 0xffff, _h);
    };
    // 0x23 : INC HL
    _instructions[0x23] = () {
      var result = (_l | (_h << 8));
      result += 1;
      _l = result & 0xff;
      _h = (result & 0xff00) >> 8;
    };
    // 0x24 : INC H
    _instructions[0x24] = () => _h = _doInc(_h);
    // 0x25 : DEC H
    _instructions[0x25] = () => _h = _doDec(_h);
    // 0x26 : LD H, n
    _instructions[0x26] = () {
      _pc = (_pc + 1) & 0xffff;
      _h = _core.memRead(_pc);
    };
    // 0x27 : DAA
    _instructions[0x27] = () {
      var temp = _a;
      if (_flags.N == 0) {
        if (_flags.H != 0 || ((_a & 0x0f) > 9)) {
          temp += 0x06;
        }
        if (_flags.C != 0 || (_a > 0x99)) {
          temp += 0x60;
        }
      } else {
        if (_flags.H != 0 || ((_a & 0x0f) > 9)) {
          temp -= 0x06;
        }
        if (_flags.C != 0 || (_a > 0x99)) {
          temp -= 0x60;
        }
      }
      _flags.S = (temp & 0x80) != 0 ? 1 : 0;
      _flags.Z = (temp & 0xff) == 0 ? 1 : 0;
      _flags.H = ((_a & 0x10) ^ (temp & 0x10)) != 0 ? 1 : 0;
      _flags.P = _parity(temp & 0xff);
      // DAA never clears the carry flag if it was already set,
      // but it is able to set the carry flag if it was clear.
      // Don't ask me, I don't know, note also that we check
      // for a BCD carry, instead of the usual.
      _flags.C = (_flags.C != 0 || (_a > 0x99)) ? 1 : 0;
      _a = temp & 0xff;
      _flagsXY = _a;
    };
    // 0x28 : JR Z, n
    _instructions[0x28] = () => _doCondRelJump(_flags.Z != 0);
    // 0x29 : ADD HL, HL
    _instructions[0x29] = () => _doHlAdd(_l | (_h << 8));
    // 0x2a : LD HL, (nn)
    _instructions[0x2a] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _l = _core.memRead(address);
      _h = _core.memRead((address + 1) & 0xffff);
    };
    // 0x2b : DEC HL
    _instructions[0x2b] = () {
      var result = (_l | (_h << 8));
      result -= 1;
      _l = result & 0xff;
      _h = (result & 0xff00) >> 8;
    };
    // 0x2c : INC L
    _instructions[0x2c] = () => _l = _doInc(_l);
    // 0x2d : DEC L
    _instructions[0x2d] = () => _l = _doDec(_l);
    // 0x2e : LD L, n
    _instructions[0x2e] = () {
      _pc = (_pc + 1) & 0xffff;
      _l = _core.memRead(_pc);
    };
    // 0x2f : CPL
    _instructions[0x2f] = () {
      _a = (~_a) & 0xff;
      _flags.N = 1;
      _flags.H = 1;
      _flagsXY = _a;
    };
    // 0x30 : JR NC, n
    _instructions[0x30] = () => _doCondRelJump(_flags.C == 0);
    // 0x31 : LD SP, nn
    _instructions[0x31] = () {
      _sp = _core.memRead((_pc + 1) & 0xffff) | (_core.memRead((_pc + 2) & 0xffff) << 8);
      _pc = (_pc + 2) & 0xffff;
    };
    // 0x32 : LD (nn), A
    _instructions[0x32] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _core.memWrite(address, _a);
    };
    // 0x33 : INC SP
    _instructions[0x33] = () => _sp = (_sp + 1) & 0xffff;
    // 0x34 : INC (HL)
    _instructions[0x34] = () {
      var address = _l | (_h << 8);
      _core.memWrite(address, _doInc(_core.memRead(address)));
    };
    // 0x35 : DEC (HL)
    _instructions[0x35] = () {
      var address = _l | (_h << 8);
      _core.memWrite(address, _doDec(_core.memRead(address)));
    };
    // 0x36 : LD (HL), n
    _instructions[0x36] = () {
      _pc = (_pc + 1) & 0xffff;
      _core.memWrite(_l | (_h << 8), _core.memRead(_pc));
    };
    // 0x37 : SCF
    _instructions[0x37] = () {
      _flags.N = 0;
      _flags.H = 0;
      _flags.C = 1;
      _flagsXY = _a;
    };
    // 0x38 : JR C, n
    _instructions[0x38] = () => _doCondRelJump(_flags.C != 0);
    // 0x39 : ADD HL, SP
    _instructions[0x39] = () => _doHlAdd(_sp);
    // 0x3a : LD A, (nn)
    _instructions[0x3a] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _a = _core.memRead(address);
    };
    // 0x3b : DEC SP
    _instructions[0x3b] = () => _sp = (_sp - 1) & 0xffff;
    // 0x3c : INC A
    _instructions[0x3c] = () => _a = _doInc(_a);
    // 0x3d : DEC A
    _instructions[0x3d] = () => _a = _doDec(_a);
    // 0x3e : LD A, n
    _instructions[0x3e] = () {
      _a = _core.memRead((_pc + 1) & 0xffff);
      _pc = (_pc + 1) & 0xffff;
    };
    // 0x3f : CCF
    _instructions[0x3f] = () {
      _flags.N = 0;
      _flags.H = _flags.C;
      _flags.C = _flags.C != 0 ? 0 : 1;
      _flagsXY = _a;
    };
    // 0xc0 : RET NZ
    _instructions[0xc0] = () => _doCondReturn(_flags.Z == 0);
    // 0xc1 : POP BC
    _instructions[0xc1] = () {
      var result = _popWord();
      _c = result & 0xff;
      _b = (result & 0xff00) >> 8;
    };
    // 0xc2 : JP NZ, nn
    _instructions[0xc2] = () => _doCondAbsJump(_flags.Z == 0);
    // 0xc3 : JP nn
    _instructions[0xc3] = () {
      _pc = _core.memRead((_pc + 1) & 0xffff) | (_core.memRead((_pc + 2) & 0xffff) << 8);
      _pc = (_pc - 1) & 0xffff;
    };
    // 0xc4 : CALL NZ, nn
    _instructions[0xc4] = () => _doCondCall(_flags.Z == 0);
    // 0xc5 : PUSH BC
    _instructions[0xc5] = () => _pushWord(_c | (_b << 8));
    // 0xc6 : ADD A, n
    _instructions[0xc6] = () {
      _pc = (_pc + 1) & 0xffff;
      _doAdd(_core.memRead(_pc));
    };
    // 0xc7 : RST 00h
    _instructions[0xc7] = () => _doReset(0x00);
    // 0xc8 : RET Z
    _instructions[0xc8] = () => _doCondReturn(_flags.Z != 0);
    // 0xc9 : RET
    _instructions[0xc9] = () => _pc = (_popWord() - 1) & 0xffff;
    // 0xca : JP Z, nn
    _instructions[0xca] = () => _doCondAbsJump(_flags.Z != 0);
    // 0xcb : CB Prefix
    _instructions[0xcb] = () {
      // R is incremented at the start of the second instruction cycle,
      //  before the instruction actually runs.
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      // We don't have a table for this prefix,
      //  the instructions are all so uniform that we can directly decode them.
      _pc = (_pc + 1) & 0xffff;
      var opcode = _core.memRead(_pc),
          bitNumber = (opcode & 0x38) >> 3,
          regCode = opcode & 0x07,
          bitMask = (1 << bitNumber);
      if (opcode < 0x40) {
        // Shift/rotate instructions
        var opArray = [_doRlc, _doRrc, _doRl, _doRr, _doSla, _doSra, _doSll, _doSrl];
        switch (regCode) {
          case 0:
            _b = opArray[bitNumber](_b);
            break;
          case 1:
            _c = opArray[bitNumber](_c);
            break;
          case 2:
            _d = opArray[bitNumber](_d);
            break;
          case 3:
            _e = opArray[bitNumber](_e);
            break;
          case 4:
            _h = opArray[bitNumber](_h);
            break;
          case 5:
            _l = opArray[bitNumber](_l);
            break;
          case 6:
            _core.memWrite(_l | (_h << 8), opArray[bitNumber](_core.memRead(_l | (_h << 8))));
            break;
          case 7:
            _a = opArray[bitNumber](_a);
            break;
        }
      } else if (opcode < 0x80) {
        // BIT instructions
        switch (regCode) {
          case 0:
            _flags.Z = (_b & bitMask) == 0 ? 1 : 0;
            break;
          case 1:
            _flags.Z = (_c & bitMask) == 0 ? 1 : 0;
            break;
          case 2:
            _flags.Z = (_d & bitMask) == 0 ? 1 : 0;
            break;
          case 3:
            _flags.Z = (_e & bitMask) == 0 ? 1 : 0;
            break;
          case 4:
            _flags.Z = (_h & bitMask) == 0 ? 1 : 0;
            break;
          case 5:
            _flags.Z = (_l & bitMask) == 0 ? 1 : 0;
            break;
          case 6:
            _flags.Z = ((_core.memRead(_l | (_h << 8))) & bitMask) == 0 ? 1 : 0;
            break;
          case 7:
            _flags.Z = (_a & bitMask) == 0 ? 1 : 0;
            break;
        }
        _flags.N = 0;
        _flags.H = 1;
        _flags.P = _flags.Z;
        _flags.S = ((bitNumber == 7) && _flags.Z == 0) ? 1 : 0;
        // For the BIT n, (HL) instruction, the X and Y flags are obtained
        //  from what is apparently an internal temporary register used for
        //  some of the 16-bit arithmetic instructions.
        // I haven't implemented that register here,
        //  so for now we'll set X and Y the same way for every BIT opcode,
        //  which means that they will usually be wrong for BIT n, (HL).
        _flags.Y = ((bitNumber == 5) && _flags.Z == 0) ? 1 : 0;
        _flags.X = ((bitNumber == 3) && _flags.Z == 0) ? 1 : 0;
      } else if (opcode < 0xc0) {
        // RES instructions
        switch (regCode) {
          case 0:
            _b &= (0xff & ~bitMask);
            break;
          case 1:
            _c &= (0xff & ~bitMask);
            break;
          case 2:
            _d &= (0xff & ~bitMask);
            break;
          case 3:
            _e &= (0xff & ~bitMask);
            break;
          case 4:
            _h &= (0xff & ~bitMask);
            break;
          case 5:
            _l &= (0xff & ~bitMask);
            break;
          case 6:
            _core.memWrite(_l | (_h << 8), _core.memRead(_l | (_h << 8)) & ~bitMask);
            break;
          case 7:
            _a &= (0xff & ~bitMask);
            break;
        }
      } else {
        // SET instructions
        switch (regCode) {
          case 0:
            _b |= bitMask;
            break;
          case 1:
            _c |= bitMask;
            break;
          case 2:
            _d |= bitMask;
            break;
          case 3:
            _e |= bitMask;
            break;
          case 4:
            _h |= bitMask;
            break;
          case 5:
            _l |= bitMask;
            break;
          case 6:
            _core.memWrite(_l | (_h << 8), _core.memRead(_l | (_h << 8)) | bitMask);
            break;
          case 7:
            _a |= bitMask;
            break;
        }
      }
      _cycleCounter += cycleCountsCB[opcode];
    };
    // 0xcc : CALL Z, nn
    _instructions[0xcc] = () => _doCondCall(_flags.Z != 0);
    // 0xcd : CALL nn
    _instructions[0xcd] = () {
      _pushWord((_pc + 3) & 0xffff);
      _pc = _core.memRead((_pc + 1) & 0xffff) | (_core.memRead((_pc + 2) & 0xffff) << 8);
      _pc = (_pc - 1) & 0xffff;
    };
    // 0xce : ADC A, n
    _instructions[0xce] = () {
      _pc = (_pc + 1) & 0xffff;
      _doAddCarry(_core.memRead(_pc));
    };
    // 0xcf : RST 08h
    _instructions[0xcf] = () => _doReset(0x08);
    // 0xd0 : RET NC
    _instructions[0xd0] = () => _doCondReturn(_flags.C == 0);
    // 0xd1 : POP DE
    _instructions[0xd1] = () {
      var result = _popWord();
      _e = result & 0xff;
      _d = (result & 0xff00) >> 8;
    };
    // 0xd2 : JP NC, nn
    _instructions[0xd2] = () => _doCondAbsJump(_flags.C == 0);
    // 0xd3 : OUT (n), A
    _instructions[0xd3] = () {
      _pc = (_pc + 1) & 0xffff;
      _core.ioWrite((_a << 8) | _core.memRead(_pc), _a);
    };
    // 0xd4 : CALL NC, nn
    _instructions[0xd4] = () => _doCondCall(_flags.C == 0);
    // 0xd5 : PUSH DE
    _instructions[0xd5] = () => _pushWord(_e | (_d << 8));
    // 0xd6 : SUB n
    _instructions[0xd6] = () {
      _pc = (_pc + 1) & 0xffff;
      _doSub(_core.memRead(_pc));
    };
    // 0xd7 : RST 10h
    _instructions[0xd7] = () => _doReset(0x10);
    // 0xd8 : RET C
    _instructions[0xd8] = () => _doCondReturn(_flags.C != 0);
    // 0xd9 : EXX
    _instructions[0xd9] = () {
      var temp = _b;
      _b = _bPrime;
      _bPrime = temp;
      temp = _c;
      _c = _cPrime;
      _cPrime = temp;
      temp = _d;
      _d = _dPrime;
      _dPrime = temp;
      temp = _e;
      _e = _ePrime;
      _ePrime = temp;
      temp = _h;
      _h = _hPrime;
      _hPrime = temp;
      temp = _l;
      _l = _lPrime;
      _lPrime = temp;
    };
    // 0xda : JP C, nn
    _instructions[0xda] = () => _doCondAbsJump(_flags.C != 0);
    // 0xdb : IN A, (n)
    _instructions[0xdb] = () {
      _pc = (_pc + 1) & 0xffff;
      _a = _core.ioRead((_a << 8) | _core.memRead(_pc));
    };
    // 0xdc : CALL C, nn
    _instructions[0xdc] = () => _doCondCall(_flags.C != 0);
    // 0xdd : DD Prefix (IX instructions)
    _instructions[0xdd] = () {
      // R is incremented at the start of the second instruction cycle,
      //  before the instruction actually runs.
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      _pc = (_pc + 1) & 0xffff;
      var opcode = _core.memRead(_pc);
      var func = _instructionsDD[opcode];
      if (func != null) {
        func();
        _cycleCounter += cycleCountsDD[opcode];
      } else {
        // Apparently if a DD opcode doesn't exist,
        // it gets treated as an unprefixed opcode.
        //
        // What we'll do to handle that is just back up the
        // program counter, so that this byte gets decoded
        // as a normal instruction.
        _pc = (_pc - 1) & 0xffff;
        // And we'll add in the cycle count for a NOP.
        _cycleCounter += cycleCounts[0];
      }
    };
    // 0xde : SBC n
    _instructions[0xde] = () {
      _pc = (_pc + 1) & 0xffff;
      _doSubCarry(_core.memRead(_pc));
    };
    // 0xdf : RST 18h
    _instructions[0xdf] = () => _doReset(0x18);
    // 0xe0 : RET PO
    _instructions[0xe0] = () => _doCondReturn(_flags.P == 0);
    // 0xe1 : POP HL
    _instructions[0xe1] = () {
      var result = _popWord();
      _l = result & 0xff;
      _h = (result & 0xff00) >> 8;
    };
    // 0xe2 : JP PO, (nn)
    _instructions[0xe2] = () => _doCondAbsJump(_flags.P == 0);
    // 0xe3 : EX (SP), HL
    _instructions[0xe3] = () {
      var temp = _core.memRead(_sp);
      _core.memWrite(_sp, _l);
      _l = temp;
      temp = _core.memRead((_sp + 1) & 0xffff);
      _core.memWrite((_sp + 1) & 0xffff, _h);
      _h = temp;
    };
    // 0xe4 : CALL PO, nn
    _instructions[0xe4] = () => _doCondCall(_flags.P == 0);
    // 0xe5 : PUSH HL
    _instructions[0xe5] = () => _pushWord(_l | (_h << 8));
    // 0xe6 : AND n
    _instructions[0xe6] = () {
      _pc = (_pc + 1) & 0xffff;
      _doAnd(_core.memRead(_pc));
    };
    // 0xe7 : RST 20h
    _instructions[0xe7] = () => _doReset(0x20);
    // 0xe8 : RET PE
    _instructions[0xe8] = () => _doCondReturn(_flags.P != 0);
    // 0xe9 : JP (HL)
    _instructions[0xe9] = () {
      _pc = _l | (_h << 8);
      _pc = (_pc - 1) & 0xffff;
    };
    // 0xea : JP PE, nn
    _instructions[0xea] = () => _doCondAbsJump(_flags.P != 0);
    // 0xeb : EX DE, HL
    _instructions[0xeb] = () {
      var temp = _d;
      _d = _h;
      _h = temp;
      temp = _e;
      _e = _l;
      _l = temp;
    };
    // 0xec : CALL PE, nn
    _instructions[0xec] = () => _doCondCall(_flags.P != 0);
    // 0xed : ED Prefix
    _instructions[0xed] = () {
      // R is incremented at the start of the second instruction cycle,
      //  before the instruction actually runs.
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      _pc = (_pc + 1) & 0xffff;
      var opcode = _core.memRead(_pc);
      var func = _instructionsED[opcode];
      if (func != null) {
        func();
        _cycleCounter += cycleCountsED[opcode];
      } else {
        // If the opcode didn't exist, the whole thing is a two-byte NOP.
        _cycleCounter += cycleCounts[0];
      }
    };
    // 0xee : XOR n
    _instructions[0xee] = () {
      _pc = (_pc + 1) & 0xffff;
      _doXor(_core.memRead(_pc));
    };
    // 0xef : RST 28h
    _instructions[0xef] = () => _doReset(0x28);
    // 0xf0 : RET P
    _instructions[0xf0] = () => _doCondReturn(_flags.S == 0);
    // 0xf1 : POP AF
    _instructions[0xf1] = () {
      var result = _popWord();
      _flagsReg = (result & 0xff);
      _a = (result & 0xff00) >> 8;
    };
    // 0xf2 : JP P, nn
    _instructions[0xf2] = () => _doCondAbsJump(_flags.S == 0);
    // 0xf3 : DI
    // DI doesn't actually take effect until after the next instruction.
    _instructions[0xf3] = () => _doDelayedDi = true;
    // 0xf4 : CALL P, nn
    _instructions[0xf4] = () => _doCondCall(_flags.S == 0);
    // 0xf5 : PUSH AF
    _instructions[0xf5] = () => _pushWord(_flagsReg | (_a << 8));
    // 0xf6 : OR n
    _instructions[0xf6] = () {
      _pc = (_pc + 1) & 0xffff;
      _doOr(_core.memRead(_pc));
    };
    // 0xf7 : RST 30h
    _instructions[0xf7] = () => _doReset(0x30);
    // 0xf8 : RET M
    _instructions[0xf8] = () => _doCondReturn(_flags.S != 0);
    // 0xf9 : LD SP, HL
    _instructions[0xf9] = () => _sp = _l | (_h << 8);
    // 0xfa : JP M, nn
    _instructions[0xfa] = () => _doCondAbsJump(_flags.S != 0);
    // 0xfb : EI
    // EI doesn't actually take effect until after the next instruction.
    _instructions[0xfb] = () => _doDelayedEi = true;
    // 0xfc : CALL M, nn
    _instructions[0xfc] = () => _doCondCall(_flags.S != 0);
    // 0xfd : FD Prefix (IY instructions)
    _instructions[0xfd] = () {
      // R is incremented at the start of the second instruction cycle,
      //  before the instruction actually runs.
      // The high bit of R is not affected by this increment,
      //  it can only be changed using the LD R, A instruction.
      _r = (_r & 0x80) | (((_r & 0x7f) + 1) & 0x7f);
      _pc = (_pc + 1) & 0xffff;
      var opcode = _core.memRead(_pc);
      var func = _instructionsDD[opcode];
      if (func != null) {
        // Rather than copy and paste all the IX instructions into IY instructions,
        //  what we'll do is sneakily copy IY into IX, run the IX instruction,
        //  and then copy the result into IY and restore the old IX.
        var temp = _ix;
        _ix = _iy;
        func();
        _iy = _ix;
        _ix = temp;
        _cycleCounter += cycleCountsDD[opcode];
      } else {
        // Apparently if an FD opcode doesn't exist,
        //  it gets treated as an unprefixed opcode.
        // What we'll do to handle that is just back up the
        //  program counter, so that this byte gets decoded
        //  as a normal instruction.
        _pc = (_pc - 1) & 0xffff;
        // And we'll add in the cycle count for a NOP.
        _cycleCounter += cycleCounts[0];
      }
    };
    // 0xfe : CP n
    _instructions[0xfe] = () {
      _pc = (_pc + 1) & 0xffff;
      _doCompare(_core.memRead(_pc));
    };
    // 0xff : RST 38h
    _instructions[0xff] = () => _doReset(0x38);
  }

  /// This table of ED opcodes is pretty sparse;
  /// there are not very many valid ED-prefixed opcodes in the Z80,
  /// and many of the ones that are valid are not documented.
  void _setupInstructionsED() {
    _instructionsED = List.filled(256, null);
    // 0x40 : IN B, (C)
    _instructionsED[0x40] = () => _b = _doIn((_b << 8) | _c);
    // 0x41 : OUT (C), B
    _instructionsED[0x41] = () => _core.ioWrite((_b << 8) | _c, _b);
    // 0x42 : SBC HL, BC
    _instructionsED[0x42] = () => _doHlSubtractCarry(_c | (_b << 8));
    // 0x43 : LD (nn), BC
    _instructionsED[0x43] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _core.memWrite(address, _c);
      _core.memWrite((address + 1) & 0xffff, _b);
    };
    // 0x44 : NEG
    _instructionsED[0x44] = () => _doNegate();
    // 0x45 : RETN
    _instructionsED[0x45] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x46 : IM 0
    _instructionsED[0x46] = () => _interruptMode = 0;
    // 0x47 : LD I, A
    _instructionsED[0x47] = () => _i = _a;
    // 0x48 : IN C, (C)
    _instructionsED[0x48] = () => _c = _doIn((_b << 8) | _c);
    // 0x49 : OUT (C), C
    _instructionsED[0x49] = () => _core.ioWrite((_b << 8) | _c, _c);
    // 0x4a : ADC HL, BC
    _instructionsED[0x4a] = () => _doHlAddCarry(_c | (_b << 8));
    // 0x4b : LD BC, (nn)
    _instructionsED[0x4b] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _c = _core.memRead(address);
      _b = _core.memRead((address + 1) & 0xffff);
    };
    // 0x4c : NEG (Undocumented)
    _instructionsED[0x4c] = () => _doNegate();
    // 0x4d : RETI
    _instructionsED[0x4d] = () {
      _pc = (_popWord() - 1) & 0xffff;
    };
    // 0x4e : IM 0 (Undocumented)
    _instructionsED[0x4e] = () => _interruptMode = 0;
    // 0x4f : LD R, A
    _instructionsED[0x4f] = () => _r = _a;
    // 0x50 : IN D, (C)
    _instructionsED[0x50] = () => _d = _doIn((_b << 8) | _c);
    // 0x51 : OUT (C), D
    _instructionsED[0x51] = () => _core.ioWrite((_b << 8) | _c, _d);
    // 0x52 : SBC HL, DE
    _instructionsED[0x52] = () => _doHlSubtractCarry(_e | (_d << 8));
    // 0x53 : LD (nn), DE
    _instructionsED[0x53] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _core.memWrite(address, _e);
      _core.memWrite((address + 1) & 0xffff, _d);
    };
    // 0x54 : NEG (Undocumented)
    _instructionsED[0x54] = () => _doNegate();
    // 0x55 : RETN
    _instructionsED[0x55] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x56 : IM 1
    _instructionsED[0x56] = () => _interruptMode = 1;
    // 0x57 : LD A, I
    _instructionsED[0x57] = () {
      _a = _i;
      _flags.S = _a & 0x80 != 0 ? 1 : 0;
      _flags.Z = _a != 0 ? 0 : 1;
      _flags.H = 0;
      _flags.P = _iff2;
      _flags.N = 0;
      _flagsXY = _a;
    };
    // 0x58 : IN E, (C)
    _instructionsED[0x58] = () => _e = _doIn((_b << 8) | _c);
    // 0x59 : OUT (C), E
    _instructionsED[0x59] = () => _core.ioWrite((_b << 8) | _c, _e);
    // 0x5a : ADC HL, DE
    _instructionsED[0x5a] = () => _doHlAddCarry(_e | (_d << 8));
    // 0x5b : LD DE, (nn)
    _instructionsED[0x5b] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _e = _core.memRead(address);
      _d = _core.memRead((address + 1) & 0xffff);
    };
    // 0x5c : NEG (Undocumented)
    _instructionsED[0x5c] = () {
      _doNegate();
    };
    // 0x5d : RETN
    _instructionsED[0x5d] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x5e : IM 2
    _instructionsED[0x5e] = () => _interruptMode = 2;
    // 0x5f : LD A, R
    _instructionsED[0x5f] = () {
      _a = _r;
      _flags.S = _a & 0x80 != 0 ? 1 : 0;
      _flags.Z = _a != 0 ? 0 : 1;
      _flags.H = 0;
      _flags.P = _iff2;
      _flags.N = 0;
      _flagsXY = _a;
    };
    // 0x60 : IN H, (C)
    _instructionsED[0x60] = () => _h = _doIn((_b << 8) | _c);
    // 0x61 : OUT (C), H
    _instructionsED[0x61] = () => _core.ioWrite((_b << 8) | _c, _h);
    // 0x62 : SBC HL, HL
    _instructionsED[0x62] = () => _doHlSubtractCarry(_l | (_h << 8));
    // 0x63 : LD (nn), HL (Undocumented)
    _instructionsED[0x63] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _core.memWrite(address, _l);
      _core.memWrite((address + 1) & 0xffff, _h);
    };
    // 0x64 : NEG (Undocumented)
    _instructionsED[0x64] = () => _doNegate();
    // 0x65 : RETN
    _instructionsED[0x65] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x66 : IM 0
    _instructionsED[0x66] = () => _interruptMode = 0;
    // 0x67 : RRD
    _instructionsED[0x67] = () {
      var hlValue = _core.memRead(_l | (_h << 8));
      var temp1 = hlValue & 0x0f, temp2 = _a & 0x0f;
      hlValue = ((hlValue & 0xf0) >> 4) | (temp2 << 4);
      _a = (_a & 0xf0) | temp1;
      _core.memWrite(_l | (_h << 8), hlValue);
      _flags.S = (_a & 0x80) != 0 ? 1 : 0;
      _flags.Z = _a != 0 ? 0 : 1;
      _flags.H = 0;
      _flags.P = _parity(_a);
      _flags.N = 0;
      _flagsXY = _a;
    };
    // 0x68 : IN L, (C)
    _instructionsED[0x68] = () => _l = _doIn((_b << 8) | _c);
    // 0x69 : OUT (C), L
    _instructionsED[0x69] = () => _core.ioWrite((_b << 8) | _c, _l);
    // 0x6a : ADC HL, HL
    _instructionsED[0x6a] = () => _doHlAddCarry(_l | (_h << 8));
    // 0x6b : LD HL, (nn) (Undocumented)
    _instructionsED[0x6b] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _l = _core.memRead(address);
      _h = _core.memRead((address + 1) & 0xffff);
    };
    // 0x6c : NEG (Undocumented)
    _instructionsED[0x6c] = () => _doNegate();
    // 0x6d : RETN
    _instructionsED[0x6d] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x6e : IM 0 (Undocumented)
    _instructionsED[0x6e] = () => _interruptMode = 0;
    // 0x6f : RLD
    _instructionsED[0x6f] = () {
      var hlValue = _core.memRead(_l | (_h << 8));
      var temp1 = hlValue & 0xf0, temp2 = _a & 0x0f;
      hlValue = ((hlValue & 0x0f) << 4) | temp2;
      _a = (_a & 0xf0) | (temp1 >> 4);
      _core.memWrite(_l | (_h << 8), hlValue);
      _flags.S = (_a & 0x80) != 0 ? 1 : 0;
      _flags.Z = _a != 0 ? 0 : 1;
      _flags.H = 0;
      _flags.P = _parity(_a);
      _flags.N = 0;
      _flagsXY = _a;
    };
    // 0x70 : IN (C) (Undocumented)
    _instructionsED[0x70] = () => _doIn((_b << 8) | _c);
    // 0x71 : OUT (C), 0 (Undocumented)
    _instructionsED[0x71] = () => _core.ioWrite((_b << 8) | _c, 0);
    // 0x72 : SBC HL, SP
    _instructionsED[0x72] = () => _doHlSubtractCarry(_sp);
    // 0x73 : LD (nn), SP
    _instructionsED[0x73] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;

      _core.memWrite(address, _sp & 0xff);
      _core.memWrite((address + 1) & 0xffff, (_sp >> 8) & 0xff);
    };
    // 0x74 : NEG (Undocumented)
    _instructionsED[0x74] = () => _doNegate();
    // 0x75 : RETN
    _instructionsED[0x75] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x76 : IM 1
    _instructionsED[0x76] = () => _interruptMode = 1;
    // 0x78 : IN A, (C)
    _instructionsED[0x78] = () => _a = _doIn((_b << 8) | _c);
    // 0x79 : OUT (C), A
    _instructionsED[0x79] = () => _core.ioWrite((_b << 8) | _c, _a);
    // 0x7a : ADC HL, SP
    _instructionsED[0x7a] = () => _doHlAddCarry(_sp);
    // 0x7b : LD SP, (nn)
    _instructionsED[0x7b] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= _core.memRead(_pc) << 8;
      _sp = _core.memRead(address);
      _sp |= _core.memRead((address + 1) & 0xffff) << 8;
    };
    // 0x7c : NEG (Undocumented)
    _instructionsED[0x7c] = () => _doNegate();
    // 0x7d : RETN
    _instructionsED[0x7d] = () {
      _pc = (_popWord() - 1) & 0xffff;
      _iff1 = _iff2;
    };
    // 0x7e : IM 2
    _instructionsED[0x7e] = () => _interruptMode = 2;
    // 0xa0 : LDI
    _instructionsED[0xa0] = () => _doLoadI();
    // 0xa1 : CPI
    _instructionsED[0xa1] = () => _doCompareI();
    // 0xa2 : INI
    _instructionsED[0xa2] = () => _doInI();
    // 0xa3 : OUTI
    _instructionsED[0xa3] = () => _doOutI();
    // 0xa8 : LDD
    _instructionsED[0xa8] = () => _doLoadD();
    // 0xa9 : CPD
    _instructionsED[0xa9] = () => _doCompareD();
    // 0xaa : IND
    _instructionsED[0xaa] = () => _doInD();
    // 0xab : OUTD
    _instructionsED[0xab] = () => _doOutD();
    // 0xb0 : LDIR
    _instructionsED[0xb0] = () {
      _doLoadI();
      if ((_b | _c) != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xb1 : CPIR
    _instructionsED[0xb1] = () {
      _doCompareI();
      if (_flags.Z == 0 && (_b | _c) != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xb2 : INIR
    _instructionsED[0xb2] = () {
      _doInI();
      if (_b != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xb3 : OTIR
    _instructionsED[0xb3] = () {
      _doOutI();
      if (_b != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xb8 : LDDR
    _instructionsED[0xb8] = () {
      _doLoadD();
      if ((_b | _c) != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xb9 : CPDR
    _instructionsED[0xb9] = () {
      _doCompareD();
      if (_flags.Z == 0 && (_b | _c) != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xba : INDR
    _instructionsED[0xba] = () {
      _doInD();
      if (_b != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
    // 0xbb : OTDR
    _instructionsED[0xbb] = () {
      _doOutD();
      if (_b != 0) {
        _cycleCounter += 5;
        _pc = (_pc - 2) & 0xffff;
      }
    };
  }

  /// Like ED, this table is quite sparse,
  /// and many of the opcodes here are also undocumented.
  ///
  /// The undocumented instructions here are those that deal with only one byte
  /// of the two-byte IX register; the bytes are designed IXH and IXL here.
  void _setupInstructionsDD() {
    _instructionsDD = List.filled(256, null);
    // 0x09 : ADD IX, BC
    _instructionsDD[0x09] = () => _doIxAdd(_c | (_b << 8));
    // 0x19 : ADD IX, DE
    _instructionsDD[0x19] = () => _doIxAdd(_e | (_d << 8));
    // 0x21 : LD IX, nn
    _instructionsDD[0x21] = () {
      _pc = (_pc + 1) & 0xffff;
      _ix = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      _ix |= (_core.memRead(_pc) << 8);
    };
    // 0x22 : LD (nn), IX
    _instructionsDD[0x22] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= (_core.memRead(_pc) << 8);
      _core.memWrite(address, _ix & 0xff);
      _core.memWrite((address + 1) & 0xffff, (_ix >> 8) & 0xff);
    };
    // 0x23 : INC IX
    _instructionsDD[0x23] = () => _ix = (_ix + 1) & 0xffff;
    // 0x24 : INC IXH (Undocumented)
    _instructionsDD[0x24] = () => _ix = (_doInc(_ix >> 8) << 8) | (_ix & 0xff);
    // 0x25 : DEC IXH (Undocumented)
    _instructionsDD[0x25] = () => _ix = (_doDec(_ix >> 8) << 8) | (_ix & 0xff);
    // 0x26 : LD IXH, n (Undocumented)
    _instructionsDD[0x26] = () {
      _pc = (_pc + 1) & 0xffff;
      _ix = (_core.memRead(_pc) << 8) | (_ix & 0xff);
    };
    // 0x29 : ADD IX, IX
    _instructionsDD[0x29] = () => _doIxAdd(_ix);
    // 0x2a : LD IX, (nn)
    _instructionsDD[0x2a] = () {
      _pc = (_pc + 1) & 0xffff;
      var address = _core.memRead(_pc);
      _pc = (_pc + 1) & 0xffff;
      address |= (_core.memRead(_pc) << 8);
      _ix = _core.memRead(address);
      _ix |= (_core.memRead((address + 1) & 0xffff) << 8);
    };
    // 0x2b : DEC IX
    _instructionsDD[0x2b] = () => _ix = (_ix - 1) & 0xffff;
    // 0x2c : INC IXL (Undocumented)
    _instructionsDD[0x2c] = () => _ix = _doInc(_ix & 0xff) | (_ix & 0xff00);
    // 0x2d : DEC IXL (Undocumented)
    _instructionsDD[0x2d] = () => _ix = _doDec(_ix & 0xff) | (_ix & 0xff00);
    // 0x2e : LD IXL, n (Undocumented)
    _instructionsDD[0x2e] = () {
      _pc = (_pc + 1) & 0xffff;
      _ix = (_core.memRead(_pc) & 0xff) | (_ix & 0xff00);
    };
    // 0x34 : INC (IX+n)
    _instructionsDD[0x34] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc)),
          value = _core.memRead((offset + _ix) & 0xffff);
      _core.memWrite((offset + _ix) & 0xffff, _doInc(value));
    };
    // 0x35 : DEC (IX+n)
    _instructionsDD[0x35] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc)),
          value = _core.memRead((offset + _ix) & 0xffff);
      _core.memWrite((offset + _ix) & 0xffff, _doDec(value));
    };
    // 0x36 : LD (IX+n), n
    _instructionsDD[0x36] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _pc = (_pc + 1) & 0xffff;
      _core.memWrite((_ix + offset) & 0xffff, _core.memRead(_pc));
    };
    // 0x39 : ADD IX, SP
    _instructionsDD[0x39] = () => _doIxAdd(_sp);
    // 0x44 : LD B, IXH (Undocumented)
    _instructionsDD[0x44] = () => _b = (_ix >> 8) & 0xff;
    // 0x45 : LD B, IXL (Undocumented)
    _instructionsDD[0x45] = () => _b = _ix & 0xff;
    // 0x46 : LD B, (IX+n)
    _instructionsDD[0x46] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _b = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x4c : LD C, IXH (Undocumented)
    _instructionsDD[0x4c] = () => _c = (_ix >> 8) & 0xff;
    // 0x4d : LD C, IXL (Undocumented)
    _instructionsDD[0x4d] = () => _c = _ix & 0xff;
    // 0x4e : LD C, (IX+n)
    _instructionsDD[0x4e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _c = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x54 : LD D, IXH (Undocumented)
    _instructionsDD[0x54] = () => _d = (_ix >> 8) & 0xff;
    // 0x55 : LD D, IXL (Undocumented)
    _instructionsDD[0x55] = () => _d = _ix & 0xff;
    // 0x56 : LD D, (IX+n)
    _instructionsDD[0x56] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _d = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x5c : LD E, IXH (Undocumented)
    _instructionsDD[0x5c] = () => _e = (_ix >> 8) & 0xff;
    // 0x5d : LD E, IXL (Undocumented)
    _instructionsDD[0x5d] = () => _e = _ix & 0xff;
    // 0x5e : LD E, (IX+n)
    _instructionsDD[0x5e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _e = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x60 : LD IXH, B (Undocumented)
    _instructionsDD[0x60] = () => _ix = (_ix & 0xff) | (_b << 8);
    // 0x61 : LD IXH, C (Undocumented)
    _instructionsDD[0x61] = () => _ix = (_ix & 0xff) | (_c << 8);
    // 0x62 : LD IXH, D (Undocumented)
    _instructionsDD[0x62] = () => _ix = (_ix & 0xff) | (_d << 8);
    // 0x63 : LD IXH, E (Undocumented)
    _instructionsDD[0x63] = () => _ix = (_ix & 0xff) | (_e << 8);
    // 0x64 : LD IXH, IXH (Undocumented)
    _instructionsDD[0x64] = () {}; // No-op.
    // 0x65 : LD IXH, IXL (Undocumented)
    _instructionsDD[0x65] = () => _ix = (_ix & 0xff) | ((_ix & 0xff) << 8);
    // 0x66 : LD H, (IX+n)
    _instructionsDD[0x66] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _h = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x67 : LD IXH, A (Undocumented)
    _instructionsDD[0x67] = () => _ix = (_ix & 0xff) | (_a << 8);
    // 0x68 : LD IXL, B (Undocumented)
    _instructionsDD[0x68] = () => _ix = (_ix & 0xff00) | _b;
    // 0x69 : LD IXL, C (Undocumented)
    _instructionsDD[0x69] = () => _ix = (_ix & 0xff00) | _c;
    // 0x6a : LD IXL, D (Undocumented)
    _instructionsDD[0x6a] = () => _ix = (_ix & 0xff00) | _d;
    // 0x6b : LD IXL, E (Undocumented)
    _instructionsDD[0x6b] = () => _ix = (_ix & 0xff00) | _e;
    // 0x6c : LD IXL, IXH (Undocumented)
    _instructionsDD[0x6c] = () => _ix = (_ix & 0xff00) | (_ix >> 8);
    // 0x6d : LD IXL, IXL (Undocumented)
    _instructionsDD[0x6d] = () {}; // No-op.
    // 0x6e : LD L, (IX+n)
    _instructionsDD[0x6e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _l = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x6f : LD IXL, A (Undocumented)
    _instructionsDD[0x6f] = () => _ix = (_ix & 0xff00) | _a;
    // 0x70 : LD (IX+n), B
    _instructionsDD[0x70] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _b);
    };
    // 0x71 : LD (IX+n), C
    _instructionsDD[0x71] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _c);
    };
    // 0x72 : LD (IX+n), D
    _instructionsDD[0x72] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _d);
    };
    // 0x73 : LD (IX+n), E
    _instructionsDD[0x73] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _e);
    };
    // 0x74 : LD (IX+n), H
    _instructionsDD[0x74] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _h);
    };
    // 0x75 : LD (IX+n), L
    _instructionsDD[0x75] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _l);
    };
    // 0x77 : LD (IX+n), A
    _instructionsDD[0x77] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _core.memWrite((_ix + offset) & 0xffff, _a);
    };
    // 0x7c : LD A, IXH (Undocumented)
    _instructionsDD[0x7c] = () => _a = (_ix >> 8) & 0xff;
    // 0x7d : LD A, IXL (Undocumented)
    _instructionsDD[0x7d] = () => _a = _ix & 0xff;
    // 0x7e : LD A, (IX+n)
    _instructionsDD[0x7e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _a = _core.memRead((_ix + offset) & 0xffff);
    };
    // 0x84 : ADD A, IXH (Undocumented)
    _instructionsDD[0x84] = () => _doAdd((_ix >> 8) & 0xff);
    // 0x85 : ADD A, IXL (Undocumented)
    _instructionsDD[0x85] = () => _doAdd(_ix & 0xff);
    // 0x86 : ADD A, (IX+n)
    _instructionsDD[0x86] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doAdd(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0x8c : ADC A, IXH (Undocumented)
    _instructionsDD[0x8c] = () => _doAddCarry((_ix >> 8) & 0xff);
    // 0x8d : ADC A, IXL (Undocumented)
    _instructionsDD[0x8d] = () => _doAddCarry(_ix & 0xff);
    // 0x8e : ADC A, (IX+n)
    _instructionsDD[0x8e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doAddCarry(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0x94 : SUB IXH (Undocumented)
    _instructionsDD[0x94] = () => _doSub((_ix >> 8) & 0xff);
    // 0x95 : SUB IXL (Undocumented)
    _instructionsDD[0x95] = () => _doSub(_ix & 0xff);
    // 0x96 : SUB A, (IX+n)
    _instructionsDD[0x96] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doSub(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0x9c : SBC IXH (Undocumented)
    _instructionsDD[0x9c] = () => _doSubCarry((_ix >> 8) & 0xff);
    // 0x9d : SBC IXL (Undocumented)
    _instructionsDD[0x9d] = () => _doSubCarry(_ix & 0xff);
    // 0x9e : SBC A, (IX+n)
    _instructionsDD[0x9e] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doSubCarry(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0xa4 : AND IXH (Undocumented)
    _instructionsDD[0xa4] = () => _doAnd((_ix >> 8) & 0xff);
    // 0xa5 : AND IXL (Undocumented)
    _instructionsDD[0xa5] = () => _doAnd(_ix & 0xff);
    // 0xa6 : AND A, (IX+n)
    _instructionsDD[0xa6] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doAnd(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0xac : XOR IXH (Undocumented)
    _instructionsDD[0xac] = () => _doXor((_ix >> 8) & 0xff);
    // 0xad : XOR IXL (Undocumented)
    _instructionsDD[0xad] = () => _doXor(_ix & 0xff);
    // 0xae : XOR A, (IX+n)
    _instructionsDD[0xae] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doXor(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0xb4 : OR IXH (Undocumented)
    _instructionsDD[0xb4] = () => _doOr((_ix >> 8) & 0xff);
    // 0xb5 : OR IXL (Undocumented)
    _instructionsDD[0xb5] = () => _doOr(_ix & 0xff);
    // 0xb6 : OR A, (IX+n)
    _instructionsDD[0xb6] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doOr(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0xbc : CP IXH (Undocumented)
    _instructionsDD[0xbc] = () => _doCompare((_ix >> 8) & 0xff);
    // 0xbd : CP IXL (Undocumented)
    _instructionsDD[0xbd] = () => _doCompare(_ix & 0xff);
    // 0xbe : CP A, (IX+n)
    _instructionsDD[0xbe] = () {
      _pc = (_pc + 1) & 0xffff;
      var offset = _getSignedOffsetByte(_core.memRead(_pc));
      _doCompare(_core.memRead((_ix + offset) & 0xffff));
    };
    // 0xcb : CB Prefix (IX bit instructions)
    _instructionsDD[0xcb] = () {
      _pc = (_pc + 1) & 0xffff;
      final offset = _getSignedOffsetByte(_core.memRead(_pc));
      _pc = (_pc + 1) & 0xffff;
      final opcode = _core.memRead(_pc);
      int? value;
      // As with the "normal" CB prefix, we implement the DDCB prefix
      // by decoding the opcode directly, rather than using a table.
      if (opcode < 0x40) {
        // Shift and rotate instructions.
        final ddcbFunctions = [_doRlc, _doRrc, _doRl, _doRr, _doSla, _doSra, _doSll, _doSrl];
        // Most of the opcodes in this range are not valid,
        // so we map this opcode onto one of the ones that is.
        final func = ddcbFunctions[(opcode & 0x38) >> 3],
            value = func(_core.memRead((_ix + offset) & 0xffff));
        _core.memWrite((_ix + offset) & 0xffff, value);
      } else {
        final bitNumber = (opcode & 0x38) >> 3;
        if (opcode < 0x80) {
          // BIT
          _flags.N = 0;
          _flags.H = 1;
          _flags.Z = (_core.memRead((_ix + offset) & 0xffff) & (1 << bitNumber)) == 0 ? 1 : 0;
          _flags.P = _flags.Z;
          _flags.S = ((bitNumber == 7) && _flags.Z == 0) ? 1 : 0;
        } else if (opcode < 0xc0) {
          // RES
          value = _core.memRead((_ix + offset) & 0xffff) & ~(1 << bitNumber) & 0xff;
          _core.memWrite((_ix + offset) & 0xffff, value);
        } else {
          // SET
          value = _core.memRead((_ix + offset) & 0xffff) | (1 << bitNumber);
          _core.memWrite((_ix + offset) & 0xffff, value);
        }
      }

      // This implements the undocumented shift, RES, and SET opcodes,
      // which write their result to memory and also to an 8080 register.
      if (value != null) {
        switch (opcode & 0x07) {
          case 0:
            _b = value;
            break;
          case 1:
            _c = value;
            break;
          case 2:
            _d = value;
            break;
          case 3:
            _e = value;
            break;
          case 4:
            _h = value;
            break;
          case 5:
            _l = value;
            break;
          // case 6 is the documented opcode, which doesn't set a register.
          case 7:
            _a = value;
            break;
        }
      }
      _cycleCounter += cycleCountsCB[opcode] + 8;
    };
    // 0xe1 : POP IX
    _instructionsDD[0xe1] = () => _ix = _popWord();
    // 0xe3 : EX (SP), IX
    _instructionsDD[0xe3] = () {
      var temp = _ix;
      _ix = _core.memRead(_sp);
      _ix |= _core.memRead((_sp + 1) & 0xffff) << 8;
      _core.memWrite(_sp, temp & 0xff);
      _core.memWrite((_sp + 1) & 0xffff, (temp >> 8) & 0xff);
    };
    // 0xe5 : PUSH IX
    _instructionsDD[0xe5] = () => _pushWord(_ix);
    // 0xe9 : JP (IX)
    _instructionsDD[0xe9] = () => _pc = (_ix - 1) & 0xffff;
    // 0xf9 : LD SP, IX
    _instructionsDD[0xf9] = () => _sp = _ix;
  }

  /// These tables contain the number of T cycles used for each instruction.
  ///
  /// In a few special cases, such as conditional control flow instructions,
  /// additional cycles might be added to these values.
  ///
  /// The total number of cycles is the return value of runInstruction().
  static const cycleCounts = <int>[
    04, 10, 07, 06, 04, 04, 07, 04, 04, 11, 07, 06, 04, 04, 07, 04, //
    08, 10, 07, 06, 04, 04, 07, 04, 12, 11, 07, 06, 04, 04, 07, 04, //
    07, 10, 16, 06, 04, 04, 07, 04, 07, 11, 16, 06, 04, 04, 07, 04, //
    07, 10, 13, 06, 11, 11, 10, 04, 07, 11, 13, 06, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    07, 07, 07, 07, 07, 07, 04, 07, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    04, 04, 04, 04, 04, 04, 07, 04, 04, 04, 04, 04, 04, 04, 07, 04, //
    05, 10, 10, 10, 10, 11, 07, 11, 05, 10, 10, 00, 10, 17, 07, 11, //
    05, 10, 10, 11, 10, 11, 07, 11, 05, 04, 10, 11, 10, 00, 07, 11, //
    05, 10, 10, 19, 10, 11, 07, 11, 05, 04, 10, 04, 10, 00, 07, 11, //
    05, 10, 10, 04, 10, 11, 07, 11, 05, 06, 10, 04, 10, 00, 07, 11, //
  ];

  static const cycleCountsED = <int>[
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    12, 12, 15, 20, 08, 14, 08, 09, 12, 12, 15, 20, 08, 14, 08, 09, //
    12, 12, 15, 20, 08, 14, 08, 09, 12, 12, 15, 20, 08, 14, 08, 09, //
    12, 12, 15, 20, 08, 14, 08, 18, 12, 12, 15, 20, 08, 14, 08, 18, //
    12, 12, 15, 20, 08, 14, 08, 00, 12, 12, 15, 20, 08, 14, 08, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    16, 16, 16, 16, 00, 00, 00, 00, 16, 16, 16, 16, 00, 00, 00, 00, //
    16, 16, 16, 16, 00, 00, 00, 00, 16, 16, 16, 16, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
  ];

  static const cycleCountsCB = <int>[
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 12, 08, 08, 08, 08, 08, 08, 08, 12, 08, //
    08, 08, 08, 08, 08, 08, 12, 08, 08, 08, 08, 08, 08, 08, 12, 08, //
    08, 08, 08, 08, 08, 08, 12, 08, 08, 08, 08, 08, 08, 08, 12, 08, //
    08, 08, 08, 08, 08, 08, 12, 08, 08, 08, 08, 08, 08, 08, 12, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
    08, 08, 08, 08, 08, 08, 15, 08, 08, 08, 08, 08, 08, 08, 15, 08, //
  ];

  static const cycleCountsDD = <int>[
    00, 00, 00, 00, 00, 00, 00, 00, 00, 15, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 15, 00, 00, 00, 00, 00, 00, //
    00, 14, 20, 10, 08, 08, 11, 00, 00, 15, 20, 10, 08, 08, 11, 00, //
    00, 00, 00, 00, 23, 23, 19, 00, 00, 15, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    08, 08, 08, 08, 08, 08, 19, 08, 08, 08, 08, 08, 08, 08, 19, 08, //
    19, 19, 19, 19, 19, 19, 00, 19, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 08, 08, 19, 00, 00, 00, 00, 00, 08, 08, 19, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, 00, //
    00, 14, 00, 23, 00, 15, 00, 00, 00, 08, 00, 00, 00, 00, 00, 00, //
    00, 00, 00, 00, 00, 00, 00, 00, 00, 10, 00, 00, 00, 00, 00, 00, //
  ];
}
