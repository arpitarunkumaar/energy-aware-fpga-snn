"""pytest entry point for collision_predictor cocotb tests.

Two cases: timing and correctness. Each spawns its own Verilator process via
cocotb_tools.runner with COCOTB_TEST_FILTER. The DUT's hex weight/bias files are
passed in as -G string parameter overrides so $readmemh resolves regardless
of the simulator's CWD.

Usage:
    pytest sequential/test_runner.py -v
    pytest sequential/test_runner.py -v -k timing
    pytest sequential/test_runner.py -v -k correctness
"""

import os
import sys
from pathlib import Path

import pytest
from cocotb_tools.runner import get_runner

HERE       = Path(__file__).resolve().parent
TESTING    = HERE.parent
REPO       = TESTING.parent
SIM_COMMON = REPO / "sim" / "common"
SIM_SEQ    = REPO / "sim" / "sequential"

MODEL_PARAMS_DIR   = REPO / "sw" / "model_params"
LAYER1_WEIGHTS_HEX = MODEL_PARAMS_DIR / "layer1_weights.hex"
LAYER2_WEIGHTS_HEX = MODEL_PARAMS_DIR / "layer2_weights.hex"
LAYER1_BIASES_HEX  = MODEL_PARAMS_DIR / "layer1_biases.hex"
LAYER2_BIASES_HEX  = MODEL_PARAMS_DIR / "layer2_biases.hex"

if str(TESTING) not in sys.path:
    sys.path.insert(0, str(TESTING))

WAVES = bool(int(os.environ.get("WAVES", "0")))

CASES = ["timing", "correctness"]


@pytest.mark.parametrize("case", CASES)
def test_collision_predictor(case):
    build_dir = HERE / f"sim_build_{case}"
    build_dir.mkdir(parents=True, exist_ok=True)

    runner = get_runner("verilator")
    runner.build(
        sources=[
            SIM_SEQ / "collision_predictor.sv",
            SIM_COMMON / "cascaded_adder.sv",
            SIM_COMMON / "lif_model.sv",
        ],
        hdl_toplevel="collision_predictor",
        build_dir=build_dir,
        waves=WAVES,
        build_args=[
            "-Wno-WIDTHTRUNC",
            "-Wno-WIDTHEXPAND",
            "--trace-structs",
            "--unroll-count", "4096",
            "--trace-max-array", "4096",
            f'-GLAYER1_WEIGHTS_PATH="{LAYER1_WEIGHTS_HEX}"',
            f'-GLAYER2_WEIGHTS_PATH="{LAYER2_WEIGHTS_HEX}"',
            f'-GLAYER1_BIASES_PATH="{LAYER1_BIASES_HEX}"',
            f'-GLAYER2_BIASES_PATH="{LAYER2_BIASES_HEX}"',
        ],
    )
    runner.test(
        hdl_toplevel="collision_predictor",
        test_module="test_collision_predictor",
        build_dir=build_dir,
        test_dir=HERE,
        waves=WAVES,
        test_args=(["--trace-file", str(build_dir / f"dump_{case}.vcd")] if WAVES else []),
        test_filter=rf"test_collision_predictor\.{case}$",
    )
