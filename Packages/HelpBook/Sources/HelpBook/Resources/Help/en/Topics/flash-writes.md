# Who Writes to the Flash

> Only the chipset has wires to the chip. Everything on the board that wants to read or write the flash goes through it, and the descriptor holds who is allowed what.

Firmware is written to the chip one way by design: through the chipset. The [[term:pch|chipset]] holds the only SPI controller on the board, so firmware on the CPU, a flashing utility, the [[term:me|Management Engine]] and the network controller all reach the chip by asking it — and it checks their permissions against the descriptor before it obeys.

A [[term:programmer|programmer]] is not part of that design. It drives the pins of the chip directly, and there is no party to ask: no permissions and no checks apply. It is not a second ordinary route but an operation outside the design of the platform, and it is how a dump is obtained from a board that does not start, and how bytes are written back when the chipset will no longer write them.

! The absence of a check at write time does not mean the absence of a check. The permissions fence off exactly what the platform verifies when it starts. A programmer removes the fence and not the verification: an edit inside a protected range is written without complaint and is then rejected at start-up. Which mechanism verifies which region is set out in the sections below.

## The board writes to its own flash all the time

Not only when someone updates the firmware:

- You change a setting in Setup and press F10, and the firmware writes the [[term:vss|NVRAM]] store back into the [[term:bios-region|BIOS region]].
- The Management Engine writes its own [[term:mfs|MFS]] — configuration, counters, state.
- A vendor's update tool, or Intel's FPT (Flash Programming Tool), rewrites a whole region from the running system.

A chip read today and the file written to it yesterday therefore do not match even where the board was not altered deliberately: the NVRAM store and the MFS changed of their own accord. This accounts for a class of differences a comparison reports that correspond to no deliberate change.

## What the descriptor decides

The [[term:flash-descriptor|descriptor]] names four [[term:flash-master|masters]] — BIOS, ME, GbE and EC — and gives each a read mask and a write mask over the [[term:region|regions]]. A flashing utility running on the CPU *is* the BIOS master. Where the descriptor does not grant that master write access to a region, the chipset refuses the write, and repeating it changes nothing.

! Reading is governed in the same way, and this has a direct effect on the dump itself. A region the BIOS master is not permitted to read cannot be obtained from the running system at all. Some utilities refuse the whole read; others fill what they could not read with `FF` and print a warning. A value of `FF` in a dump taken in-system can therefore mean "could not be read" rather than "erased", and a comparison then reports a whole region as a difference that does not exist in the flash memory. A dump taken with a programmer contains no such gaps. This is flashrom's documented behaviour: it refuses the read by default and fills with `FF` only when instructed to ignore the errors ([[web:https://flashrom.org/classic_cli_manpage.html|flashrom's manual page]]).

## Writing is not running

The masks decide one thing only: whether a write through the chipset is allowed. Whether what was written will then work is a different question, and it is answered at boot, by checks that have nothing to do with the descriptor:

- [[term:boot-guard|Boot Guard]] verifies the boot block before the CPU executes it. The chipset does not check that signature: the [[term:acm|ACM]], started by CPU microcode, does, and the hash of the root key sits in the chipset's [[term:otp|fuses]].
- The ME region is verified by the engine itself, as it comes up.

This is the distinction that accounts for a change which is written successfully and still has no effect. A programmer defeats the masks and can write any byte into any region; it has no effect on the checks performed at start-up, so an edit inside the [[term:ibb|IBB]] or in the ME region is written and then rejected.

What those checks do not cover — the NVRAM store, the [[term:dmi|DMI]] area, [[term:ec|EC]] firmware, and frequently the DXE drivers as well ([[term:ibb|IBB / OBB]] states which) — is written by a programmer and takes effect.

## The locks the descriptor knows nothing about

The descriptor is one gate of several, and the others live in chipset registers rather than in the image:

- **BIOS Lock Enable** — an attempt to enable writing to the BIOS region traps into system management mode, where the firmware's own handler decides what happens.
- **SMM BIOS Write Protect** — the BIOS region is writable only while the processor is in system management mode.
- **Protected Range Registers** — up to five address ranges the firmware locks at boot, which hold even against system management mode.
- **Flash Configuration Lockdown** — freezes those ranges until the next platform reset.

None of this is held in the dump, so no panel can display it and no edit can alter it. It accounts for a write refused while the descriptor plainly permits it. The registers are documented in the chipset datasheets; a short account of how the four operate together is published [[web:https://eclypsium.com/blog/firmware-security-realizations-part-3-spi-write-protections/|by Eclypsium]].

## The service override

Intel's chipsets carry a **Flash Descriptor Security Override**: a servicing mode that opens full read and write access to every region until the next reboot. It is not switched on by a program but by a wire on the board:

- On 6-series chipsets and later, the audio codec's `HDA_SDO` pin is shorted to its 3.3 V supply across the rising edge of `PWROK` — held while the system starts, released once the firmware begins to load.
- Before 2011 (5-series and older) it was `GPIO33` pulled to ground at the same moment instead.
- Some vendors bring the same thing out as a jumper or a switch.

This is the mechanism a service procedure uses to read or rewrite a locked region with a utility, without removing the chip from the board. No public datasheet describes it: it is recorded in Intel's platform guides for manufacturers, and in repair practice it is known from the community's own instructions, the fullest of which is [[web:https://winraid.level1techs.com/t/guide-unlock-intel-flash-descriptor-read-write-access-permissions-for-spi-servicing/32449|the Win-RAID guide to unlocking descriptor access]], the source of the detail above. See [[topic:provenance|Where This Knowledge Comes From]].

See also: [[topic:bench-safety|Constraints on Editing an Image]], [[term:flash-descriptor|Flash descriptor]].
