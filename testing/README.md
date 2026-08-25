# Tests

Functional simulation for the RTL in `sim/` and `rtl/`. Vivado SAIF / power
testbenches stay next to the flows under `fpga-synth/`.

## One-time setup

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Verilator >= 5.036 is required for cocotb 2.0; check with `verilator --version`.

## Layout

```
testing/
  Makefile              dispatcher: make test DUT=<dir>
  requirements.txt
  common/               python helpers (golden models, clock/reset)
  cascaded_adder/       unit tests for sim/common/cascaded_adder.sv
  lif_model/            unit tests for sim/common/lif_model.sv
  sequential/           1-tree collision_predictor
  folded/
    e4_l16/
    l16_l64/            LANES=16 or LANES=64
    l128/
```

## Running tests

From this directory:

```sh
make test  DUT=cascaded_adder
make test  DUT=lif_model
make test  DUT=sequential
make test  DUT=folded/e4_l16
LANES=16 make test DUT=folded/l16_l64
LANES=64 make test DUT=folded/l16_l64
make test  DUT=folded/l128
```

`make test` is `pytest test_runner.py -v` inside the DUT directory.
Per-build artifacts land in `<DUT>/sim_build*/` and are gitignored.

The legacy Verilator SystemVerilog LIF bench is `lif_model/Makefile`
(`lif_model_legacy.sv` + `lif_model_tb.sv`).
