# Zilog Z80 microprocessor emulator

This is an emulator for the Z80 processor, ported to Dart from JS and is a simple, 
straightforward instruction interpreter. There is no fancy dynamic recompilation 
or cycle-accurate emulation. It is developed to serve as a component of a larger 
system which incorporates a Z80 as its CPU.

The code assumes that the reader is familiar with the Z80 architecture.
If you're not, here are some references:

  * Z80 instruction set tables
    http://clrhome.org/table/

  * The official manual
    http://www.zilog.com/docs/z80/um0080.pdf

  * The Undocumented Z80, Documented
    http://www.myquest.nl/z80undocumented/z80-documented-v0.91.pdf

## Usage

A simple usage from `example/main.dart`:

```dart
import 'dart:typed_data';

import 'package:z80/z80.dart';

void main() {
  var system = System();
  system.memWrite(0, 1);
  // 0000| $A8 XOR b
  // 0001| $0E LD c, [address]
  // 0002| $07 [address]
  // 0003| $0A LD a, (bc)
  // 0004| $3C inc a
  // 0005| $02 LD (bc), a
  // 0006| $76 HALT
  // 0007| $AA
  system.load(0, [0xA8, 0x0E, 0x07, 0x0A, 0x3C, 0x02, 0x76, 0xAA]);
  print('before ram[7] = ${system.memRead(7).toRadixString(16)}');
  system.run(24);
  print('after  ram[7] = ${system.memRead(7).toRadixString(16)}');
}

class System implements Z80Core {
  System() {
    _cpu = Z80CPU(this);
    _ram = Uint8ClampedList(32 * 1024); // 32K
  }

  late final Z80CPU _cpu;
  late final Uint8ClampedList _ram;

  void load(int address, List<int> data) {
    _ram.setRange(address, address + data.length, data);
  }

  int run(int cycles) {
    while (cycles > 0) {
      cycles -= _cpu.runInstruction();
    }
    return cycles;
  }

  @override
  int memRead(int address) => _ram[address];

  @override
  void memWrite(int address, int value) => _ram[address] = value;

  @override
  int ioRead(int port) => 0;

  @override
  void ioWrite(int port, int value) {}
}
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

## License
This code is copyright Molly Howell, Simon Lightfoot and contributors and is made
available under the MIT license. The text of the MIT license can be found in the
LICENSE file in this repository.

Ported from: https://github.com/DrGoldfire/Z80.js

[tracker]: https://github.com/slightfoot/dart_z80/issues
