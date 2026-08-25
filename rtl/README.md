# RTL (FPGA-mapped)

Synthesizable designs which deploy on the xcau25p-ffvb676-2-e Vivado flows in `../fpga-synth/`.
This part is available in Vivado's free tier and provides adequate resources for these designs,
hence its extensive use here. See `../fpga-synth/au25p/folded_designs/README.md` for instructions on how to run each flow.

RTL for sim-only networks (too large to place on the part) live in `../sim/` instead. Said designs were the first designed and simulated by the team, though we later pivoted to smaller designs as each were too large for synthesis.

Designs are sorted into `folded/` and `paper/` variants as follows:
```
rtl/
  folded/
    common/     shared LIF + adder used by E4/L16, L16, and L64
    e4_l16/     4 engines × 16 lanes
    l16_l64/    folded BRAM core; LANES=16 or 64
    l128/       128-lane folded core (own LIF and adder, incompatible with common/)
  paper/
    one 4096-input tree + LIF (synthesized OOC), plus standalone LIF I/O wrappers
```

`paper/` comprises the first small design composed by the team, which acted as our best assessment of the architecture described in the original paper (one 4096-input cascaded adder, one LIF module). `folded/` are alternative reduced-resource designs which attempt to meet the paper's utilisation following the realisation that `paper/`'s utilisation still far exceeded numbers given in the paper. Out-of-context (OOC) synthesis was used for the `paper/` design in order to quickly obtain utilisation numbers without the need to accommodate for weight streaming.

L128 keeps its own `lif_model.sv` and cascaded adder module because their interfaces do not align with
those in `folded/common`, which is expected by the rest of L128's RTL.
