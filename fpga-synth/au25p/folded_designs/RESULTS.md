# Retained AU25P results

All points target `xcau25p-ffvb676-2-e`.  Power is post-route, SAIF-annotated,
core-only total on-chip power.

| Design | Engines x lanes | Weight bus | Frequency | Cycles/inference | Inferences/s | Effective GOPS | LUT | FF | BRAM tiles | Power | GOPS/W | Energy/inference |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| E4/L16 | 4 x 16 | 64-bit | 160 MHz | 836,514 | 191.27 | 20.07 | 5,017 | 5,364 | 21.5 | 0.621 W | 32.31 | 3.247 mJ |
| L16 | 1 x 16 | 64-bit | 175 MHz | 3,298,588 | 53.06 | 5.57 | 2,285 | 2,530 | 13.5 | 0.509 W | 10.94 | 9.594 mJ |
| L64 | 1 x 64 | 64-bit | 125 MHz | 836,188 | 149.49 | 15.68 | 5,130 | 3,348 | 34.5 | 0.581 W | 26.99 | 3.887 mJ |
| L128 | 1 x 128 | 128-bit | 250 MHz | 415,731 | 601.35 | 63.09 | 11,482 | 6,435 | 64.5 | 1.165 W | 54.15 | 1.937 mJ |

Bus width is the external layer-1 weight stream accepted per clock, not the
internal adder width.  The 64-bit designs accept four 16-bit weights per cycle.
L128 accepts eight, loading an 8-KiB row in 512 accepted cycles and reusing it
for 800 hidden-layer compute cycles.

Effective GOPS uses 52,454,400 binary synaptic interactions per inference and
counts weight selection plus accumulation as two operations.

