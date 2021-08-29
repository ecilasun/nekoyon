# nekoyon

NekoYon is the fourth generation of the Neko SoC series

This version implements the following:
- DDR3 controler with a single cache (256 lines, 256bits per line, direct mapping)
- 256Mbytes of DDR3 (D-RAM) @0x00000000
- 32Kbytes of boot ROM/RAM (S-RAM) @0x10000000
- Memory mapped device IO starting @0x80000000
- ELF binaries get loaded into DDR3 space to avoid overlap
  - This way, user programs will be able to refer to ROM functions via ECALL to ARAM space
- UART TX/RX at 115200 bauds (use riscvtool to upload ELF binaries)
  - UART state is reflected to memory mapped addresses (incoming byte present, output queue full flags)
- Implements the minimal RV32I set of RISC-V architecture (currently clocked at 150MHz)
  - Shortest instruction takes 3 clocks, longest takes 4(+N clocks on cache miss) clocks

## TODO
- Bus arbiter
- Second core
- Floating point unit
- CSRs (interrupts/timers etc)
- Graphics output
- Audio output
- SDCard support

## Disclaimer

**WARNING**: The device defined by this source code is built for experimental / educational uses only and is not
intended for field use, especially where it may cause harm to any living being.
