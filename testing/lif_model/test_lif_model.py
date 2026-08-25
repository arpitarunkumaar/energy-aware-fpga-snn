"""cocotb tests for lif (leaky integrate-and-fire neuron).

See ./test_plan.md for the full test matrix this file implements. It covers
everything the legacy SV testbench (testing/lif_model/lif_model_tb.sv) checked — reset,
enable-freeze, subthreshold — plus the threshold/refractory cases that were
left as TODO there, all validated against the bit-exact LifModel golden
reference. Each case is its own @cocotb.test() and runs in its own Verilator
process, launched by test_runner.py via cocotb_tools.runner with
COCOTB_TEST_FILTER.
"""

import random

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from common.clock import start_clock
from common.reference import LifModel


# --- helpers ---

def _param(dut, name: str, default: int) -> int:
    # Verilator parameter VPI is occasionally flaky; fall back to defaults.
    try:
        return int(getattr(dut, name).value)
    except (AttributeError, ValueError):
        dut._log.warning("could not read parameter %s; defaulting to %d", name, default)
        return default


def _state(dut) -> tuple[int, int]:
    return int(dut.internal_value.value), int(dut.refractory_counter.value)


async def _reset(dut, cycles: int = 2) -> None:
    """Hold rst high (with enable high — rst is gated by enable) for `cycles` edges."""
    dut.input_current.value = 0
    dut.enable.value = 1
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0


async def _setup(dut) -> LifModel:
    """Spawn clock, reset DUT, and return a golden model matching this build's parameters."""
    start_clock(dut)
    model = LifModel(
        k=_param(dut, "k", 5),
        uth=_param(dut, "uth", 100),
        urest=_param(dut, "urest", 0),
        refractory_counter_max=_param(dut, "refractory_counter_max", 5),
    )
    await _reset(dut)
    return model


async def _lockstep(dut, model, cycle: int, current: int,
                    enable: int = 1, rst: int = 0) -> int:
    """Drive one cycle into DUT and model; assert spike + internal state match.

    Sampling happens in the ReadOnly phase so the post-edge values have
    settled (reading straight after RisingEdge returns stale values under
    Verilator), then NextTimeStep exits ReadOnly so the caller may drive
    the next cycle's inputs.
    """
    dut.input_current.value = current
    dut.enable.value = enable
    dut.rst.value = rst
    await RisingEdge(dut.clk)
    await ReadOnly()
    exp = model.step(current, enable=enable, rst=rst)
    got = int(dut.spike.value)
    assert got == exp, f"cycle {cycle}: spike={got}, model expected {exp}"
    u, ctr = _state(dut)
    assert u == model.u, f"cycle {cycle}: internal_value={u}, model expected {model.u}"
    assert ctr == model.ctr, f"cycle {cycle}: refractory_counter={ctr}, model expected {model.ctr}"
    await NextTimeStep()
    return got


# --- cases ---

@cocotb.test()
async def reset_clears_state(dut):
    """rst=1 (with enable=1) clears spike/internal_value/refractory_counter and holds them at 0."""
    model = await _setup(dut)
    await ReadOnly()
    assert int(dut.spike.value) == 0, "reset: spike not 0"
    assert _state(dut) == (0, 0), f"reset: state not cleared, got {_state(dut)}"
    await NextTimeStep()

    # Large current while reset is held must not accumulate.
    for cycle in range(3):
        got = await _lockstep(dut, model, cycle, current=1000, rst=1)
        assert got == 0, f"reset held: spike went high at cycle {cycle}"
        assert _state(dut) == (0, 0), f"reset held: state moved at cycle {cycle}"


@cocotb.test()
async def disabled_neuron_freezes(dut):
    """enable=0 forces spike low and freezes internal_value, even under large input current."""
    model = await _setup(dut)

    # Charge partway so we can tell "frozen" from "reset".
    for cycle in range(3):
        await _lockstep(dut, model, cycle, current=1)
    frozen, _ = _state(dut)

    for cycle in range(6):
        got = await _lockstep(dut, model, cycle, current=5000, enable=0)
        assert got == 0, f"enable=0: spike went high at cycle {cycle}"
        u, _ = _state(dut)
        assert u == frozen, f"enable=0: internal_value moved {frozen} -> {u}"

    # Re-enabling resumes integration from the frozen value.
    for cycle in range(3):
        await _lockstep(dut, model, cycle, current=1)


@cocotb.test()
async def subthreshold_never_spikes(dut):
    """Constant small current settles below uth via leakage: no spike, membrane stays under threshold."""
    model = await _setup(dut)
    for cycle in range(30):
        got = await _lockstep(dut, model, cycle, current=1)
        assert got == 0, f"unexpected spike at cycle {cycle}"
        u, _ = _state(dut)
        assert u < model.uth, f"cycle {cycle}: internal_value {u} reached uth {model.uth}"


@cocotb.test()
async def fires_at_threshold(dut):
    """Constant current=uth drives the membrane past uth: spike pulses exactly one cycle, membrane clears."""
    model = await _setup(dut)

    spike_cycle = None
    for cycle in range(20):
        if await _lockstep(dut, model, cycle, current=model.uth):
            spike_cycle = cycle
            break
    assert spike_cycle is not None, "no spike within 20 cycles of constant uth current"

    u, ctr = _state(dut)
    assert u == 0, f"membrane not cleared on spike: internal_value={u}"
    assert ctr == 1, f"refractory_counter not started on spike: got {ctr}"

    # spike is a 1-cycle pulse.
    got = await _lockstep(dut, model, spike_cycle + 1, current=0)
    assert got == 0, "spike stayed high longer than one cycle"


@cocotb.test()
async def refractory_blocks_input(dut):
    """After a spike, input is ignored for the refractory window; spikes land exactly rmax+1 apart under saturating current."""
    model = await _setup(dut)
    big = 4 * model.uth

    spikes = []
    for cycle in range(6 * (model.rmax + 2)):
        if await _lockstep(dut, model, cycle, current=big):
            spikes.append(cycle)

    assert len(spikes) >= 2, f"expected repeated firing, saw spikes at {spikes}"
    gaps = [b - a for a, b in zip(spikes, spikes[1:])]
    # spike -> counter increments -> clear cycle -> one integrate -> next spike
    assert all(g == model.rmax + 1 for g in gaps), (
        f"refractory spacing wrong: expected all gaps == {model.rmax + 1}, got {gaps}"
    )


@cocotb.test()
async def random_stimulus(dut):
    """400 cycles of random current/enable/rst compared cycle-by-cycle against the bit-exact golden model."""
    model = await _setup(dut)
    rng = random.Random(0x11F)

    for cycle in range(400):
        r = rng.random()
        if r < 0.25:
            cur = 0
        elif r < 0.50:
            cur = rng.randint(0, max(1, model.uth // 4))    # subthreshold-ish
        elif r < 0.80:
            cur = rng.randint(0, 2 * model.uth)             # around threshold
        else:
            cur = rng.randint(0, (1 << 28) - 1)             # full-range, exercises wrap
        enable = 0 if rng.random() < 0.10 else 1
        rst = 1 if rng.random() < 0.02 else 0
        await _lockstep(dut, model, cycle, cur, enable=enable, rst=rst)
