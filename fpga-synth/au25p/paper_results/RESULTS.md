# Preliminary-slide result provenance

## Pipelined 4096-input tree plus one LIF

| Target | Setup WNS | Hold WHS | LUT | FF | Peak GOPS | Dynamic | Total | Evidence |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 67 MHz | +12.015 ns | +0.009 ns | 38,667 | 69,606 | 548.88 | 0.875 W | 1.332 W | `run/reports/67mhz/` |
| 280 MHz | +0.971 ns | +0.009 ns | 38,713 | 69,606 | 2,294.04 | 3.395 W | 3.874 W | `run/reports/280mhz/` |

Peak GOPS uses the slide convention: 4096 binary weight selections/additions
per accepted vector, counted as two operations, multiplied by the clock rate.
It is the peak rate of one fully fed hidden-neuron datapath, not full-network
inference throughput.

## Standalone LIF runs

| Exact run | Timing at 100 MHz | LUT | FF | Dynamic | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unregistered package-I/O top (`lif_io_100mhz`) | -4.450 ns WNS | 155 | 32 | 0.009 W | 0.460 W |
| Registered package-I/O top (`lif_board_100mhz`) | +1.758 ns WNS | 137 | 64 | 0.006 W | 0.456 W |

The slide's 155-LUT/32-FF and 6-mW/456-mW values therefore do not identify one
exact implementation.  Both source/report sets are retained rather than
silently mixing their metrics.

