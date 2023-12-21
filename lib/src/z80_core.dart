import 'z80_cpu.dart';

/// Abstract interface required to be implemented to use [Z80CPU]
abstract class Z80Core {
  /// Should return the unsigned 8-bit byte at the given memory address.
  int memRead(int address);

  /// Should write the given unsigned 8-bit byte value to the given memory address.
  void memWrite(int address, int value);

  /// Should read a return unsigned 8-bit byte read from the given I/O port.
  int ioRead(int port);

  /// Should write the given unsigned 8-bit byte to the given I/O port.
  void ioWrite(int port, int value);
}
