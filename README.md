# Dart implementation of the Zilog Z80 Microprocessor.

This is an emulator for the Z80 processor, written in Dart. It is developed to
serve as a component of an emulator for a larger system which incorporates a
Z80 as its CPU.

Ported from: https://github.com/DrGoldfire/Z80.js

## Usage

A simple usage from `example/main.dart`:

```dart
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
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

## License
This code is copyright Molly Howell, Simon Lightfoot and contributors and is made
available under the MIT license. The text of the MIT license can be found in the
LICENSE.md file in this repository.



[tracker]: https://github.com/slightfoot/dart_z80/issues
