"""cocotb tests for cascaded_adder.

See ./test_plan.md for the full test matrix this file implements. Each case
is its own @cocotb.test() and runs in its own Verilator process, launched
by test_runner.py via cocotb_tools.runner with COCOTB_TEST_FILTER.
"""

import random
from typing import Sequence

import cocotb
from cocotb.triggers import RisingEdge

from common.clock import reset, start_clock
from common.reference import adder_sum


# --- helpers ---

def _pack_bits(bits: Sequence[int]) -> int:
    return sum((b & 1) << i for i, b in enumerate(bits))


def _pack_signed(values: Sequence[int], width: int) -> int:
    mask = (1 << width) - 1
    return sum((v & mask) << (i * width) for i, v in enumerate(values))


def _param(dut, name: str, default: int) -> int:
    # Verilator parameter VPI is occasionally flaky; fall back to defaults.
    try:
        return int(getattr(dut, name).value)
    except (AttributeError, ValueError):
        dut._log.warning("could not read parameter %s; defaulting to %d", name, default)
        return default


def _signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def _random_stimulus(
    rng: random.Random, num_inputs: int, in_width: int
) -> tuple[list[int], list[int]]:
    """Generate one (spikes, weights) vector with the given RNG."""
    w_min, w_max = _signed_range(in_width)
    spikes  = [rng.randint(0, 1)         for _ in range(num_inputs)]
    weights = [rng.randint(w_min, w_max) for _ in range(num_inputs)]
    return spikes, weights


async def _setup(dut) -> tuple[int, int]:
    """Spawn clock, reset DUT, and return (NUM_INPUTS, IN_WIDTH) for this build."""
    start_clock(dut)
    await reset(dut)
    return _param(dut, "NUM_INPUTS", 4096), _param(dut, "IN_WIDTH", 16)


async def _run(
    dut,
    vectors: Sequence[tuple[Sequence[int], Sequence[int]]],
    in_width: int,
) -> list[int]:
    """Drive each (spikes, weights) back-to-back; return captured outputs in order."""
    n = len(vectors)
    captured: list[int] = []

    async def collect():
        while len(captured) < n:
            await RisingEdge(dut.clk)
            if int(dut.valid_out.value) == 1:
                captured.append(dut.out.value.signed_integer)

    collector = cocotb.start_soon(collect())

    for spikes, weights in vectors:
        dut.spike.value    = _pack_bits(spikes)
        dut.weight.value   = _pack_signed(weights, in_width)
        dut.valid_in.value = 1
        await RisingEdge(dut.clk)
    dut.valid_in.value = 0

    await collector
    return captured


# --- cases ---

@cocotb.test()
async def random_vectors(dut):
    """32 back-to-back random (spike, weight) iterations; every output matches Σ spike·weight."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_ITERS = 32
    rng = random.Random(0xC0C07B)
    w_min, w_max = _signed_range(IN_WIDTH)

    vectors = [
        (
            [rng.randint(0, 1)         for _ in range(NUM_INPUTS)],
            [rng.randint(w_min, w_max) for _ in range(NUM_INPUTS)],
        )
        for _ in range(NUM_ITERS)
    ]
    expected = [adder_sum(s, w) for s, w in vectors]
    got = await _run(dut, vectors, IN_WIDTH)

    mismatches = [(i, g, e) for i, (g, e) in enumerate(zip(got, expected)) if g != e]
    assert not mismatches, (
        f"{len(mismatches)}/{NUM_ITERS} mismatches; first: "
        f"iter {mismatches[0][0]} expected {mismatches[0][2]}, got {mismatches[0][1]}"
    )


@cocotb.test()
async def all_zero_spikes(dut):
    """All-zero spikes gate every weight to 0; output must be exactly 0 regardless of weights."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    rng = random.Random(0xA1102E20)
    w_min, w_max = _signed_range(IN_WIDTH)

    spikes  = [0] * NUM_INPUTS
    weights = [rng.randint(w_min, w_max) for _ in range(NUM_INPUTS)]
    [got] = await _run(dut, [(spikes, weights)], IN_WIDTH)

    assert got == 0, f"expected 0, got {got}"


@cocotb.test()
async def all_one_spikes(dut):
    """All-one spikes pass every weight through; output must equal Σ weights."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    rng = random.Random(0xA11002E5)
    w_min, w_max = _signed_range(IN_WIDTH)

    spikes  = [1] * NUM_INPUTS
    weights = [rng.randint(w_min, w_max) for _ in range(NUM_INPUTS)]
    expected = adder_sum(spikes, weights)
    [got] = await _run(dut, [(spikes, weights)], IN_WIDTH)

    assert got == expected, f"expected {expected}, got {got}"


@cocotb.test()
async def one_hot_spike(dut):
    """Single-active spike at varied indices; output must equal the selected weight (probes index plumbing)."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    rng = random.Random(0x0E0AC7)
    w_min, w_max = _signed_range(IN_WIDTH)

    indices = []
    if NUM_INPUTS == 2:
        indices = [0, 1]
    elif NUM_INPUTS > 2:
        indices = [0, NUM_INPUTS - 1, NUM_INPUTS // 2,
                rng.randint(1, NUM_INPUTS - 2),
                rng.randint(1, NUM_INPUTS - 2)]

    vectors  = []
    expected = []
    for idx in indices:
        weights = [rng.randint(w_min, w_max) for _ in range(NUM_INPUTS)]
        spikes  = [0] * NUM_INPUTS
        spikes[idx] = 1
        vectors.append((spikes, weights))
        expected.append(weights[idx])

    got = await _run(dut, vectors, IN_WIDTH)
    mismatches = [
        (idx, g, e) for idx, g, e in zip(indices, got, expected) if g != e
    ]
    assert not mismatches, f"one-hot mismatches: {mismatches}"


@cocotb.test()
async def max_positive_sum(dut):
    """All spikes high, all weights = 0x7FFF; checks worst-case positive growth fits OUT_WIDTH."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    w = (1 << (IN_WIDTH - 1)) - 1                # 0x7FFF for IN_WIDTH=16
    spikes  = [1] * NUM_INPUTS
    weights = [w] * NUM_INPUTS
    expected = NUM_INPUTS * w
    [got] = await _run(dut, [(spikes, weights)], IN_WIDTH)
    assert got == expected, f"expected {expected}, got {got}"


@cocotb.test()
async def max_negative_sum(dut):
    """All spikes high, all weights = 0x8000 (most-negative int16); checks worst-case negative growth + sign extension."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    w = -(1 << (IN_WIDTH - 1))                   # 0x8000 → -32768 for IN_WIDTH=16
    spikes  = [1] * NUM_INPUTS
    weights = [w] * NUM_INPUTS
    expected = NUM_INPUTS * w
    [got] = await _run(dut, [(spikes, weights)], IN_WIDTH)
    assert got == expected, f"expected {expected}, got {got}"


@cocotb.test()
async def mixed_sign_cancellation(dut):
    """Alternating +0x4000 / -0x4000 with all spikes high; signed cancellation drives the sum to 0 (even NUM_INPUTS)."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    pos = 1 << (IN_WIDTH - 2)                    # 0x4000 for IN_WIDTH=16
    spikes  = [1] * NUM_INPUTS
    weights = [(pos if i % 2 == 0 else -pos) for i in range(NUM_INPUTS)]
    expected = sum(weights)                      # 0 when NUM_INPUTS is even
    [got] = await _run(dut, [(spikes, weights)], IN_WIDTH)
    assert got == expected, f"expected {expected}, got {got}"


@cocotb.test()
async def latency(dut):
    """Single valid_in pulse: valid_out rises exactly LATENCY cycles later with the correct sum, then drops."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    LATENCY = NUM_STAGES + 1  # Add 1 cycle for the mux layer
    rng = random.Random(0x1A7E47)
    spikes, weights = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
    expected = adder_sum(spikes, weights)

    dut.spike.value    = _pack_bits(spikes)
    dut.weight.value   = _pack_signed(weights, IN_WIDTH)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)                    # cycle 0: valid_in sampled
    dut.valid_in.value = 0

    seen_at = None
    seen_value = None
    extras = 0
    for cycle in range(1, 2 * LATENCY + 1):
        await RisingEdge(dut.clk)
        if int(dut.valid_out.value) == 1:
            if seen_at is None:
                seen_at = cycle
                seen_value = dut.out.value.signed_integer
            else:
                extras += 1

    assert seen_at == LATENCY, (
        f"expected valid_out at cycle {LATENCY}, observed at {seen_at}"
    )
    assert seen_value == expected, (
        f"sum at latency-cycle wrong: expected {expected}, got {seen_value}"
    )
    assert extras == 0, f"valid_out re-asserted spuriously {extras} time(s)"


@cocotb.test()
async def saturated_throughput(dut):
    """N back-to-back iterations: valid_out high for exactly N consecutive cycles with sums emitted in input order."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    LATENCY = NUM_STAGES + 1  # Add 1 cycle for the mux layer
    N = 16
    rng = random.Random(0x5A7DA7)
    vectors  = [_random_stimulus(rng, NUM_INPUTS, IN_WIDTH) for _ in range(N)]
    expected = [adder_sum(s, w) for s, w in vectors]

    valid_history: list[int] = []
    captured: list[int] = []

    async def monitor():
        for _ in range(N + LATENCY + 1):
            await RisingEdge(dut.clk)
            v = int(dut.valid_out.value)
            valid_history.append(v)
            if v == 1:
                captured.append(dut.out.value.signed_integer)

    mon = cocotb.start_soon(monitor())

    for spikes, weights in vectors:
        dut.spike.value    = _pack_bits(spikes)
        dut.weight.value   = _pack_signed(weights, IN_WIDTH)
        dut.valid_in.value = 1
        await RisingEdge(dut.clk)
    dut.valid_in.value = 0

    await mon

    expected_pattern = [0] * LATENCY + [1] * N + [0] * (len(valid_history) - LATENCY - N)
    assert valid_history == expected_pattern, (
        f"valid_out pattern mismatch:\n  expected {expected_pattern}\n  got      {valid_history}"
    )
    assert captured == expected, (
        f"output order/value mismatch: expected {expected}, got {captured}"
    )


@cocotb.test()
async def bubbles(dut):
    """valid_in pattern with gaps (e.g. 1,1,0,1,0,0,1,1): valid_out reproduces the gap pattern at the spec'd latency."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    LATENCY = NUM_STAGES + 1  # Add 1 cycle for the mux layer
    pattern = [1, 1, 0, 1, 0, 0, 1, 1]
    rng = random.Random(0xBABBE5)

    stimuli  = [_random_stimulus(rng, NUM_INPUTS, IN_WIDTH) for _ in pattern]
    expected = [adder_sum(s, w) for v, (s, w) in zip(pattern, stimuli) if v == 1]

    valid_history: list[int] = []
    captured: list[int] = []

    async def monitor():
        for _ in range(len(pattern) + LATENCY + 1):
            await RisingEdge(dut.clk)
            v = int(dut.valid_out.value)
            valid_history.append(v)
            if v == 1:
                captured.append(dut.out.value.signed_integer)

    mon = cocotb.start_soon(monitor())

    for v, (spikes, weights) in zip(pattern, stimuli):
        dut.spike.value    = _pack_bits(spikes)
        dut.weight.value   = _pack_signed(weights, IN_WIDTH)
        dut.valid_in.value = v
        await RisingEdge(dut.clk)
    dut.valid_in.value = 0

    await mon

    expected_pattern = (
        [0] * LATENCY
        + pattern
        + [0] * (len(valid_history) - LATENCY - len(pattern))
    )
    assert valid_history == expected_pattern, (
        f"valid_out gap pattern mismatch:\n  expected {expected_pattern}\n  got      {valid_history}"
    )
    assert captured == expected, (
        f"gap-pattern sums mismatch: expected {expected}, got {captured}"
    )


@cocotb.test()
async def reset_at_startup(dut):
    """While rst_n=0, arbitrary spike/weight/valid_in must not produce any valid_out glitches."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    rng = random.Random(0x57A87)

    dut.rst_n.value = 0
    for _ in range(NUM_STAGES + 5):
        spikes, weights = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
        dut.spike.value    = _pack_bits(spikes)
        dut.weight.value   = _pack_signed(weights, IN_WIDTH)
        dut.valid_in.value = rng.randint(0, 1)
        await RisingEdge(dut.clk)
        assert int(dut.valid_out.value) == 0, "valid_out went high while rst_n=0"

    dut.valid_in.value = 0
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def mid_flight_reset(dut):
    """Asserting rst_n=0 with iterations in the pipeline: no stale valid_out during reset or after deassertion."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    rng = random.Random(0xBEEFFACE)

    # Drive a few in-flight iterations (fewer than NUM_STAGES so none have emerged yet)
    pre_iters = max(2, NUM_STAGES // 2)
    for _ in range(pre_iters):
        spikes, weights = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
        dut.spike.value    = _pack_bits(spikes)
        dut.weight.value   = _pack_signed(weights, IN_WIDTH)
        dut.valid_in.value = 1
        await RisingEdge(dut.clk)

    # Yank reset while those iters are still propagating
    dut.valid_in.value = 0
    dut.rst_n.value = 0
    for _ in range(NUM_STAGES + 3):
        await RisingEdge(dut.clk)
        assert int(dut.valid_out.value) == 0, "valid_out went high during mid-flight reset"

    # Release reset; pre-reset iters must not surface afterwards
    dut.rst_n.value = 1
    for _ in range(NUM_STAGES + 3):
        await RisingEdge(dut.clk)
        assert int(dut.valid_out.value) == 0, "stale valid_out after reset deassertion"


@cocotb.test()
async def resume_after_reset(dut):
    """Post-reset, a fresh valid_in pulse produces the correct sum at exactly LATENCY cycles."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    LATENCY = NUM_STAGES + 1  # Add 1 cycle for the mux layer
    rng = random.Random(0xFEEDBACC)

    # Re-reset to start from a known empty pipeline
    dut.valid_in.value = 0
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    spikes, weights = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
    expected = adder_sum(spikes, weights)

    dut.spike.value    = _pack_bits(spikes)
    dut.weight.value   = _pack_signed(weights, IN_WIDTH)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)                    # cycle 0: valid_in sampled
    dut.valid_in.value = 0

    for cycle in range(1, LATENCY):
        await RisingEdge(dut.clk)
        assert int(dut.valid_out.value) == 0, (
            f"premature valid_out at cycle {cycle} (expected first pulse at {LATENCY})"
        )

    await RisingEdge(dut.clk)                    # cycle = LATENCY
    assert int(dut.valid_out.value) == 1, (
        f"valid_out missing at expected post-reset latency LATENCY={LATENCY}"
    )
    got = dut.out.value.signed_integer
    assert got == expected, f"post-reset sum mismatch: expected {expected}, got {got}"


@cocotb.test()
async def garbage_when_idle(dut):
    """Random spike/weight while valid_in=0 must not corrupt the next valid iteration's output."""
    NUM_INPUTS, IN_WIDTH = await _setup(dut)
    NUM_STAGES = (NUM_INPUTS - 1).bit_length()
    rng = random.Random(0xDADA)

    spikes_a, weights_a = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
    spikes_b, weights_b = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
    expected = [adder_sum(spikes_a, weights_a), adder_sum(spikes_b, weights_b)]

    captured: list[int] = []
    async def collect():
        while len(captured) < 2:
            await RisingEdge(dut.clk)
            if int(dut.valid_out.value) == 1:
                captured.append(dut.out.value.signed_integer)

    col = cocotb.start_soon(collect())

    # Iter A (known)
    dut.spike.value    = _pack_bits(spikes_a)
    dut.weight.value   = _pack_signed(weights_a, IN_WIDTH)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)

    # Idle: drive random garbage on spike/weight while valid_in=0
    for _ in range(NUM_STAGES + 3):
        g_spikes, g_weights = _random_stimulus(rng, NUM_INPUTS, IN_WIDTH)
        dut.spike.value    = _pack_bits(g_spikes)
        dut.weight.value   = _pack_signed(g_weights, IN_WIDTH)
        dut.valid_in.value = 0
        await RisingEdge(dut.clk)

    # Iter B (known)
    dut.spike.value    = _pack_bits(spikes_b)
    dut.weight.value   = _pack_signed(weights_b, IN_WIDTH)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0

    await col

    assert captured == expected, (
        f"garbage during idle corrupted output: expected {expected}, got {captured}"
    )
