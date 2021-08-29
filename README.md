# nekoyon

NekoYon is the fourth generation of the Neko SoC series

This version implements the following:
- DDR3 controler with a single cache (512 lines (I$ / D$ each get a half), 256bits per line, direct mapping)
- 256Mbytes of DDR3 (D-RAM) @0x00000000
- 32Kbytes of boot ROM/RAM (S-RAM) @0x10000000
- Memory mapped device IO starting @0x80000000
- ELF binaries get loaded into DDR3 space to avoid overlap
  - This way, user programs will be able to refer to ROM functions via ECALL to ARAM space
- UART TX/RX at 115200 bauds (use riscvtool to upload ELF binaries)
  - UART state is reflected to memory mapped addresses (incoming byte present, output queue full flags)
- Implements the minimal RV32I set of RISC-V architecture (currently clocked at 150MHz)
  - Shortest instruction takes 3 clocks, longest takes 4(+N clocks on cache miss) clocks
- Most CSRs available for interrupt control / timers / counters
- 

## TODO
- Bus arbiter
- Second core
- Floating point unit
- Graphics output
- Audio output
- SDCard support

## License
This is intended as a free IP. Please see the accompanying LICENSE.txt file for license terms.
