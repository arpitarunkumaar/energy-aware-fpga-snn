# AU25P folded-network designs

Vivado flows, trained data, SAIF activity, and retained P&R reports for
E4/L16, L16, L64, and L128. Synthesized RTL lives under `rtl/folded/`.

## Code map

| Design | Top-level RTL | Shared RTL / data | Passing routed point |
| --- | --- | --- | --- |
| E4/L16 | `rtl/folded/e4_l16/folded_bram_predictor_parallel.sv` | `rtl/folded/common/`, `common/data/` | 160 MHz |
| L16 | `rtl/folded/l16_l64/folded_bram_predictor.sv` `LANES=16` | `rtl/folded/common/`, `common/data/` | 175 MHz |
| L64 | `rtl/folded/l16_l64/folded_bram_predictor.sv` `LANES=64` | `rtl/folded/common/`, `common/data/` | 125 MHz |
| L128 | `rtl/folded/l128/collision_predictor.sv` | `rtl/folded/l128/`, `common/data/` | 250 MHz |

E4/L16, L16, and L64 use the static-threshold LIF in `rtl/folded/common`.
L128 keeps a dynamic-threshold LIF beside its own top-level so the two
interfaces do not collide.

## Reproduction commands

Run from this directory with Vivado 2022.1:

```bash
vivado -mode batch -nojournal -nolog -source e4_l16/impl_point.tcl \
  -tclargs 4 6.250 engines4_lanes16_160mhz_pipelined_fallback

vivado -mode batch -nojournal -nolog -source l16_l64/impl_point.tcl \
  -tclargs 16 2 5.714 lanes16_rb2_175mhz_signoff

vivado -mode batch -nojournal -nolog -source l16_l64/impl_point.tcl \
  -tclargs 64 2 8.000 lanes64_rb2_125mhz

vivado -mode batch -nojournal -nolog -source l128/impl_point.tcl \
  -tclargs 4.000 250mhz
```

Bit-exact tests (from repo root, after `testing/` venv setup):

```bash
make -C testing test DUT=folded/e4_l16
LANES=16 make -C testing test DUT=folded/l16_l64
LANES=64 make -C testing test DUT=folded/l16_l64
./l128/run_regression.sh
```

## Vivado evidence retained

Each routed point keeps its flow summary, post-synthesis utilization and
timing, post-route utilization and timing, route status, DRC, SAIF annotation,
activity-based power, and the exact compressed SAIF used by the power run.
Where Vivado emitted a switching-activity report it is retained as well.

Checkpoints, generated functional netlists, Vivado projects/caches, waveform
databases and console scratch logs are excluded. Decompress a `.saif.gz` into
the power runner's expected `run` location before rerunning only the power
report.
