# Who Writes to the Flash

> Only the chipset has wires to the chip. Everything on the board that wants to write firmware has to ask it, and the descriptor decides who may ask for what.

Bytes reach the flash chip two ways, and most of what puzzles a bench follows from the difference between them.

- **Through the chipset**, while the board runs. The [[term:pch|chipset]] holds the only SPI controller on the board, so firmware on the CPU, a flashing utility, the [[term:me|Management Engine]] and the network controller all reach the chip by asking it.
- **On the chip's own pins**, with a [[term:programmer|programmer]] — a clip, a socket, or wired in circuit. The chipset is not involved, and on a board being repaired it is usually not even powered.

The first is policed. The second is not.

## The board writes to its own flash all the time

Not only when someone updates the firmware:

- You change a setting in Setup and press F10, and the firmware writes the [[term:vss|NVRAM]] store back into the [[term:bios-region|BIOS region]].
- The Management Engine writes its own [[term:mfs|MFS]] — configuration, counters, state.
- A vendor's update tool, or Intel's FPT, rewrites a whole region from the running system.

So a chip read today and the file flashed into it yesterday will not match, even if nobody touched the board on purpose: NVRAM and MFS moved on their own. That is the first thing to suspect when a comparison shows differences nobody can account for.

## What the descriptor decides

The [[term:flash-descriptor|descriptor]] names four [[term:flash-master|masters]] — BIOS, ME, GbE and EC — and gives each a read mask and a write mask over the [[term:region|regions]]. A flashing utility running on the CPU *is* the BIOS master. Where the descriptor does not grant that master write access to a region, the chipset refuses the write, and repeating it changes nothing.

! Reading is gated the same way, and this one bites hardest. A region the BIOS master may not read cannot be dumped from the running system at all. Some tools refuse the whole read; others fill the gap with `FF` and print a warning. So `FF` in a dump taken in-system can mean "not allowed to read" rather than "erased" — and a comparison then shows a whole region as one enormous difference that is not really there. A dump taken with a programmer has no such holes.

## The locks the descriptor knows nothing about

The descriptor is one gate of several, and the others live in chipset registers rather than in the image:

- **BIOS Lock Enable** — an attempt to enable writing to the BIOS region traps into system management mode, where the firmware's own handler decides what happens.
- **SMM BIOS Write Protect** — the BIOS region is writable only while the processor is in system management mode.
- **Protected Range Registers** — up to five address ranges the firmware locks at boot, which hold even against system management mode.
- **Flash Configuration Lockdown** — freezes those ranges until the next platform reset.

None of this is in the dump, so no panel can show it and no edit can change it. It is the explanation for a write refused while the descriptor plainly allows it.

## The service override

Intel's chipsets carry a **Flash Descriptor Security Override**: a strap meant for manufacturing that grants full read and write access to every region. Some desktop boards expose it as a jumper; on laptops it is usually a pin on the audio codec that has to be held during power-up. This is what service procedures use to unlock a descriptor without opening the board up to a programmer. Intel does not document it publicly — what the repair community knows about it was measured, not read off a datasheet. See [[topic:provenance|Where this knowledge comes from]].

See also: [[topic:bench-safety|Bench rules]], [[term:flash-descriptor|Flash descriptor]].
