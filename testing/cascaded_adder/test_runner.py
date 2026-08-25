"""pytest entry point that runs each cascaded_adder case as its own test.

For every (case, num_inputs) combo we spawn a fresh Verilator process and use
COCOTB_TEST_FILTER to pick exactly one @cocotb.test() out of
test_cascaded_adder.py. Per-build artifacts land in sim_build_n<NUM_INPUTS>/;
Verilator's incremental make skips the rebuild after the first case per N.

Usage:
    pytest cascaded_adder/test_runner.py -v
    pytest cascaded_adder/test_runner.py -v -k latency       # one case, both N
    pytest cascaded_adder/test_runner.py -v -k 4096          # all cases, N=4096
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
    "random_vectors",
    "all_zero_spikes",
    "all_one_spikes",
    "one_hot_spike",
    "max_positive_sum",
    "max_negative_sum",
    "mixed_sign_cancellation",
    "latency",
    "saturated_throughput",
    "bubbles",
    "reset_at_startup",
    "mid_flight_reset",
    "resume_after_reset",
    "garbage_when_idle",
]


@pytest.mark.parametrize("num_inputs", [2, 512, 4096])
@pytest.mark.parametrize("case", CASES)
def test_cascaded_adder(case, num_inputs):
    build_dir = HERE / f"sim_build_n{num_inputs}"
    runner = get_runner("verilator")
    runner.build(
        sources=[SIM_COMMON / "cascaded_adder.sv"],
        hdl_toplevel="cascaded_adder",
        parameters={"NUM_INPUTS": num_inputs},
        build_dir=build_dir,
        waves=WAVES,
        build_args=[
            "--trace-structs",
            "--unroll-count", "4096",
            "--trace-max-array", "4096",
        ],
    )
    runner.test(
        hdl_toplevel="cascaded_adder",
        test_module="test_cascaded_adder",
        build_dir=build_dir,
        test_dir=HERE,
        waves=WAVES,
        test_args=(["--trace-file", str(build_dir / f"dump_{case}.vcd")] if WAVES else []),
        test_filter=rf"test_cascaded_adder\.{case}$",
    )
