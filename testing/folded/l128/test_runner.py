"""Bit-exact cocotb entry point for the retained L128 RTL."""

from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
RTL = REPO / "rtl" / "folded" / "l128"
MODEL_DIR = REPO / "fpga-synth" / "au25p" / "folded_designs" / "common" / "data" / "model_params"

CASES = [
    "bit_exact_full_network",
    "bit_exact_with_stream_backpressure",
    "bad_weight_last_sets_protocol_error",
]


@pytest.mark.parametrize("case", CASES)
def test_collision_predictor(case):
    build_dir = HERE / f"sim_build_{case}"
    runner = get_runner("verilator")
    runner.build(
        sources=[
            RTL / "collision_predictor.sv",
            RTL / "l128_adder_bank.sv",
            RTL / "cascaded_adder.sv",
            RTL / "lif_model.sv",
        ],
        hdl_toplevel="collision_predictor",
        build_dir=build_dir,
        build_args=[
            "-Wno-WIDTHTRUNC",
            "-Wno-WIDTHEXPAND",
            "-Wno-UNUSEDSIGNAL",
            "--unroll-count", "4096",
            f'-GLAYER2_WEIGHTS_PATH="{MODEL_DIR / "layer2_weights.hex"}"',
            f'-GLAYER1_BIASES_PATH="{MODEL_DIR / "layer1_biases.hex"}"',
            f'-GLAYER2_BIASES_PATH="{MODEL_DIR / "layer2_biases.hex"}"',
        ],
    )
    runner.test(
        hdl_toplevel="collision_predictor",
        test_module="test_collision_predictor",
        test_dir=HERE,
        build_dir=build_dir,
        test_filter=rf"test_collision_predictor\.{case}$",
    )
