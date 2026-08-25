# Sim-only RTL

Designs that are simulated but not mapped onto the xcau25p-ffvb676-2-e part (unlike those in `../rtl/`.) They share the adder and LIF module under `common/`. These were the first designs conceptualised to be explored by the team, though they are sim-only due to exceeding the target part's resources.

```
sim/
  common/         cascaded_adder.sv, lif_model.sv
  sequential/     one 4096-input tree, 512 neuron-cycles per timestep
  parallel/       512 parallel trees, one timestep per cycle
                  (does not fit the FPGA; functional golden / upper bound)
```

Functional tests are in `testing/`. The parallel net has no cocotb suite yet;
build it the same way as sequential, pointing Verilator at
`sim/parallel/collision_predictor.sv` plus `sim/common/`.
