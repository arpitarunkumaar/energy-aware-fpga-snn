"""Bit-exact cocotb entry point for the retained L16/L64 RTL."""

import os
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
RTL = REPO / "rtl" / "folded"
MODEL_DIR = REPO / "fpga-synth" / "au25p" / "folded_designs" / "common" / "data" / "model_params"


def test_folded_bram_predictor():
    lanes = int(os.environ.get("LANES", "16"))
    build_dir = HERE / f"sim_build_l{lanes}"
    build_dir.mkdir(parents=True, exist_ok=True)

    runner = get_runner("verilator")
    runner.build(
        sources=[
            RTL / "l16_l64" / "folded_bram_predictor.sv",
            RTL / "common" / "cascaded_adder_synth.sv",
            RTL / "common" / "lif_model.sv",
        ],
        hdl_toplevel="folded_bram_predictor",
        build_dir=build_dir,
        build_args=[
            "-Wno-WIDTHTRUNC",
            "-Wno-WIDTHEXPAND",
            "--unroll-count", "4096",
            f"-GLANES={lanes}",
            f'-GLAYER2_WEIGHTS_PATH="{MODEL_DIR / "layer2_weights.hex"}"',
            f'-GLAYER1_BIASES_PATH="{MODEL_DIR / "layer1_biases.hex"}"',
            f'-GLAYER2_BIASES_PATH="{MODEL_DIR / "layer2_biases.hex"}"',
        ],
    )
    runner.test(
        hdl_toplevel="folded_bram_predictor",
        test_module="test_folded_bram_predictor",
        build_dir=build_dir,
        test_dir=HERE,
    )
