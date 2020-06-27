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

  Z80CPU _cpu;
  Uint8ClampedList _ram;

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
