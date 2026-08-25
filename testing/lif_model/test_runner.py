"""pytest entry point that runs each lif case as its own test.

For every (case, cfg) combo we spawn a fresh Verilator process and use
COCOTB_TEST_FILTER to pick exactly one @cocotb.test() out of
test_lif_model.py. Per-build artifacts land in sim_build_<cfg>/; Verilator's
incremental make skips the rebuild after the first case per cfg.

Usage:
    pytest lif_model/test_runner.py -v
    pytest lif_model/test_runner.py -v -k refractory     # one case, every cfg
    pytest lif_model/test_runner.py -v -k sv_tb          # all cases, one cfg
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

# cocotb_tools.runner forwards its own sys.path as the subprocess PYTHONPATH
# (overriding extra_env), so inject TESTING here to make `from common import
# ...` resolvable inside the simulator's embedded Python.
if str(TESTING) not in sys.path:
    sys.path.insert(0, str(TESTING))

WAVES = bool(int(os.environ.get("WAVES", "0")))


CASES = [
    "reset_clears_state",
    "disabled_neuron_freezes",
    "subthreshold_never_spikes",
    "fires_at_threshold",
    "refractory_blocks_input",
    "random_stimulus",
]

PARAM_SETS = {
    # RTL defaults
    "defaults":       {"k": 5, "uth": 100, "urest": 0, "refractory_counter_max": 5},
    # parameters the legacy SV testbench (testing/lif_model/lif_model_tb.sv) used;
    # urest > 0 exercises the unsigned-underflow leak path from u=0
    "sv_tb":          {"k": 2, "uth": 20, "urest": 5, "refractory_counter_max": 5},
    # smallest sane refractory window (counter clears the cycle after a spike)
    "min_refractory": {"k": 1, "uth": 8, "urest": 0, "refractory_counter_max": 2},
}


@pytest.mark.parametrize("cfg", list(PARAM_SETS))
@pytest.mark.parametrize("case", CASES)
def test_lif(case, cfg):
    build_dir = HERE / f"sim_build_{cfg}"
    runner = get_runner("verilator")
    runner.build(
        sources=[SIM_COMMON / "lif_model.sv"],
        hdl_toplevel="lif",
        parameters=PARAM_SETS[cfg],
        build_dir=build_dir,
        waves=WAVES,
        build_args=[
            "--trace-structs",
            # lif_model.sv mixes 28-bit signals with 32-bit integer parameters;
            # the golden model replicates that widening/truncation bit-exactly,
            # so waive the (otherwise fatal) width lints rather than patch RTL.
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
        ],
    )
    runner.test(
        hdl_toplevel="lif",
        test_module="test_lif_model",
        build_dir=build_dir,
        test_dir=HERE,
        waves=WAVES,
        test_args=(["--trace-file", str(build_dir / f"dump_{case}.vcd")] if WAVES else []),
        test_filter=rf"test_lif_model\.{case}$",
    )
