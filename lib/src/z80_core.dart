abstract class Z80Core {
  /// Should return the byte at the given memory address.
  int memRead(int address);

  /// Should write the given 8bit byte value to the given memory address.
  void memWrite(int address, int value);

  /// Should read a return a byte read from the given I/O port.
  int ioRead(int port);

  /// Should write the given byte to the given I/O port.
  void ioWrite(int port, int value);
}
