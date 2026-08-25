# SNN collision predictor on FPGA

An FPGA implementation of the spiking neural network from arXiv:2411.01628v1
("Energy-Aware FPGA Implementation of Spiking Neural Network with LIF Neurons"),
targeting the Xilinx Artix UltraScale+ `xcau25p-ffvb676-2-e`.

This term long project is a core independent component of ECE 493 - a special topics course on AI/ML Hardware offered in the Spring 2026 term, run by Dr. Andrew Boutros.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Synthesizable RTL that maps onto the part — `folded/` and `paper/` design families |
| `sim/` | Simulation-only RTL too large to place — `sequential/` and `parallel/` networks |
| `sw/` | Trained SNN model, weight/bias `.hex` files, and golden test-vector generation |
| `testing/` | cocotb/Verilator functional test suites for everything in `rtl/` and `sim/` |
| `fpga-synth/` | Vivado synthesis, implementation and power flows |

## Build instructions

More detailed instructions for running various work are included in the following docs:

| For | See |
|---|---|
| Functional tests (all designs) | [`testing/README.md`](testing/README.md) |
| AU25P folded-design synthesis and power | [`fpga-synth/au25p/folded_designs/README.md`](fpga-synth/au25p/folded_designs/README.md) |
| AU25P paper-result reproduction | [`fpga-synth/au25p/paper_results/README.md`](fpga-synth/au25p/paper_results/README.md) |

## Credits

Ali Oonwala, Braden Schulz, Grady Booth, and Sreya Roy Chowdhury.
