"""Bit-exact cocotb entry point for the retained E4/L16 design."""

from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
RTL = REPO / "rtl" / "folded"
MODEL_DIR = REPO / "fpga-synth" / "au25p" / "folded_designs" / "common" / "data" / "model_params"
SERIAL_TEST_DIR = REPO / "testing" / "folded" / "l16_l64"


def test_e4_l16():
    build_dir = HERE / "sim_build_e4_l16"
    build_dir.mkdir(parents=True, exist_ok=True)

    runner = get_runner("verilator")
    runner.build(
        sources=[
            RTL / "e4_l16" / "folded_bram_predictor_parallel.sv",
            RTL / "common" / "cascaded_adder_synth.sv",
            RTL / "common" / "lif_model.sv",
        ],
        hdl_toplevel="folded_bram_predictor_parallel",
        build_dir=build_dir,
        build_args=[
            "-Wno-WIDTHTRUNC",
            "-Wno-WIDTHEXPAND",
            "--unroll-count", "4096",
            "-GNUM_ENGINES=4",
            f'-GLAYER2_WEIGHTS_PATH="{MODEL_DIR / "layer2_weights.hex"}"',
            f'-GLAYER1_BIASES_PATH="{MODEL_DIR / "layer1_biases.hex"}"',
            f'-GLAYER2_BIASES_PATH="{MODEL_DIR / "layer2_biases.hex"}"',
        ],
    )
    runner.test(
        hdl_toplevel="folded_bram_predictor_parallel",
        test_module="test_folded_bram_predictor",
        build_dir=build_dir,
        test_dir=SERIAL_TEST_DIR,
    )
