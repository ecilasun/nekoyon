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
- SPI module for SDCard support
- Integer math unit (M extension)
- Floating point unit (F extension)
- DVI output
- Graphics processor
  - Dual V-RAM (scan-out buffers)
  - vsync wait capability via frame IDs
  - Graphics memory (G-RAM, large enough for at least one back buffer or some bitmaps)
  - P-RAM based command buffers
  - DMA instruction to move data from G-RAM to V-RAM

## TODO
- Audio output
  - Self-timing stereo output FIFO
- Hardware I/O
  - Keys (with an IRQ generated)
  - LEDs (can do a read/write access if CPU state is persistent with LED output, so that code can save/restore the LED state)
  - GPIO (need a 'in-out' mode select here)
- DDR3/cache
  - Investigate ways to optimize access and get better throughput
- Bus arbiter
  - To support a second core
  - Need to make the FPU units shared, duplicate rest for now
  - Cache will be an issue, need to duplicate it for each CPU (perhaps move it outside the 'bus' code?)

## License
This is intended as a free IP. Please see the accompanying LICENSE.txt file for license terms.
The project includes code from other opensource projects which contain their respective license information
in the code file. The DDR3 memory interface and FIFOs use Vivado IPs, however do not necessarily depend on
them and should be portable to use replacement IPs.

Uses https://github.com/taneroksuz/riscv-fpu for the IEEE compliant FPU.
