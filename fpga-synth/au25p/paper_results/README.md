# AU25P paper-result reproducer

Vivado flow, stimuli, SAIF activity, and retained reports for the **Our design**
columns in the preliminary-results slide. Synthesized RTL lives under
`rtl/paper/`. The paper-reported SNN and BCNN values are external literature
data; no implementation is claimed for those rows.

## Result-to-code map

| Slide result | Exact top | RTL | Authoritative report directories |
| --- | --- | --- | --- |
| One 4096-input tree + one LIF at 67 MHz | `parallel512_weight_partition_ooc` | `rtl/paper/parallel512_weight_partition_ooc.sv`, `cascaded_adder.sv`, `lif_model.sv` | `run/reports/67mhz/` |
| One 4096-input tree + one LIF at 280 MHz | `parallel512_weight_partition_ooc` | same RTL and trained row-0 data | `run/reports/280mhz/` |
| Standalone LIF area shown as 155 LUT / 32 FF | `lif_unit_io_top` | `rtl/paper/lif_unit_io_top.sv`, `lif_model.sv` | `run/reports/lif_io_100mhz/` |
| Standalone LIF power shown as 6 mW dynamic / 456 mW total | `lif_unit_board_top` | `rtl/paper/lif_unit_board_top.sv`, `lif_model.sv` | `run/reports/lif_board_100mhz/` |

The standalone-LIF slide row combines two different runs. There is no single
run in the available artifacts that simultaneously produced 155 LUT, 32 FF,
6 mW dynamic and 456 mW total:

- `lif_io_100mhz` produced 155 CLB LUTs and 32 CLB registers, but 9 mW dynamic,
  460 mW total, and did not meet 100 MHz I/O timing (WNS -4.450 ns).
- `lif_board_100mhz` produced 6 mW dynamic, 456 mW total and met 100 MHz timing,
  but used 137 CLB LUTs and 64 CLB registers because its boundary I/O is
  registered.

These are kept separate so a later paper revision can select one coherent row.

## Reproduction

```bash
cd fpga-synth/au25p/paper_results
./run_all.sh
```

The routed-tree flow requires Vivado 2022.1 and targets
`xcau25p-ffvb676-2-e`. Compressed `.saif.gz` files are the exact recorded
activity inputs for the retained reports; decompress one into the corresponding
`run/activity/<label>/post_route_fully_fed.saif` location before rerunning only
the power-report step.

Each retained result directory contains the principal Vivado evidence:
post-synthesis utilization/timing where emitted, post-route utilization/timing,
SAIF annotation, activity-based power, route status and DRC. Checkpoints,
Vivado project caches, wave databases and temporary console output are omitted.
