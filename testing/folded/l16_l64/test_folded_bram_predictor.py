"""Bit-exact end-to-end test for the neuron-major folded BRAM core."""

import json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

NUM_INPUTS = 4096
NUM_HIDDEN = 512
TIME_STEPS = 25
LANES = 16
WEIGHT_STREAM_WIDTH = 64
SPIKE_WORDS = TIME_STEPS * NUM_INPUTS // LANES
WEIGHTS_PER_BEAT = WEIGHT_STREAM_WIDTH // 16
WEIGHT_BEATS = NUM_INPUTS // WEIGHTS_PER_BEAT

HERE = Path(__file__).resolve().parent
DATA_DIR = HERE.parent.parent / "common" / "data"
MODEL_DIR = DATA_DIR / "model_params"
TV_DIR = DATA_DIR / "testvectors"


def _load_weights() -> np.ndarray:
    with open(MODEL_DIR / "layer1_weights.hex") as f:
        raw = [int(word, 16) for word in f.read().split()]
    assert len(raw) == NUM_HIDDEN * NUM_INPUTS
    return np.asarray(raw, dtype=np.uint16).reshape(NUM_HIDDEN, NUM_INPUTS)


def _pack_spike_word(bits: np.ndarray) -> int:
    return int.from_bytes(
        np.packbits(bits.astype(np.uint8), bitorder="little").tobytes(), "little"
    )


class RowSource:
    def __init__(self, weights: np.ndarray):
        self.weights = weights
        self.requests = []
        self.accepted_beats = 0
        self.stop = False

    async def run(self, dut):
        dut.row_request_ready.value = 1
        dut.weight_valid.value = 0
        dut.weight_data.value = 0
        dut.weight_last.value = 0

        while not self.stop:
            await RisingEdge(dut.clk)
            if not (dut.row_request_valid.value and dut.row_request_ready.value):
                continue

            neuron = int(dut.row_request_neuron.value)
            self.requests.append(neuron)

            while not dut.weight_ready.value:
                await RisingEdge(dut.clk)

            for beat in range(WEIGHT_BEATS):
                while not dut.weight_ready.value:
                    await RisingEdge(dut.clk)
                lo = beat * WEIGHTS_PER_BEAT
                packed = int.from_bytes(
                    self.weights[neuron, lo:lo + WEIGHTS_PER_BEAT]
                    .astype("<u2").tobytes(),
                    "little",
                )
                dut.weight_valid.value = 1
                dut.weight_data.value = packed
                dut.weight_last.value = int(beat == WEIGHT_BEATS - 1)
                await RisingEdge(dut.clk)
                self.accepted_beats += 1

            dut.weight_valid.value = 0
            dut.weight_last.value = 0


@cocotb.test()
async def manifest_image_zero(dut):
    """Run one trained-network image and compare both output spike counts."""
    npz = np.load(TV_DIR / "testvectors.npz")
    spikes = npz["spk_in"][0].reshape(TIME_STEPS, NUM_INPUTS)
    with open(TV_DIR / "manifest.json") as f:
        expected_no_collision, expected_collision = json.load(f)["records"][0][
            "spike_counts"
        ]

    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    dut.start_image.value = 0
    dut.spike_valid.value = 0
    dut.spike_data.value = 0
    dut.row_request_ready.value = 0
    dut.weight_valid.value = 0
    dut.weight_data.value = 0
    dut.weight_last.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    source = RowSource(_load_weights())
    source_task = cocotb.start_soon(source.run(dut))

    while not dut.image_ready.value:
        await RisingEdge(dut.clk)
    dut.start_image.value = 1
    await RisingEdge(dut.clk)
    dut.start_image.value = 0

    while not dut.spike_ready.value:
        await RisingEdge(dut.clk)
    dut.spike_valid.value = 1
    for t in range(TIME_STEPS):
        for fold in range(NUM_INPUTS // LANES):
            lo = fold * LANES
            dut.spike_data.value = _pack_spike_word(spikes[t, lo:lo + LANES])
            await RisingEdge(dut.clk)
    dut.spike_valid.value = 0

    # Cycle model plus generous handshake/control allowance.
    deadline = 4_200_000
    elapsed = -1
    for cycle in range(deadline):
        await RisingEdge(dut.clk)
        if dut.inference_valid.value:
            elapsed = cycle + SPIKE_WORDS
            break

    source.stop = True
    await RisingEdge(dut.clk)
    source_task.kill()

    assert elapsed >= 0, f"inference_valid did not assert within {deadline} cycles"
    assert int(dut.protocol_error.value) == 0
    assert source.requests == list(range(NUM_HIDDEN)), (
        f"row request order/count wrong: {len(source.requests)} requests, "
        f"first={source.requests[:8]}, last={source.requests[-8:]}"
    )
    assert source.accepted_beats == NUM_HIDDEN * WEIGHT_BEATS

    got = (
        int(dut.no_collision_counter.value),
        int(dut.collision_counter.value),
    )
    expected = (expected_no_collision, expected_collision)
    assert got == expected, f"output spike counts got={got}, expected={expected}"

    dut._log.info(
        "PASS image=0 cycles=%d rows=%d beats=%d counts=%s",
        elapsed,
        len(source.requests),
        source.accepted_beats,
        got,
    )
