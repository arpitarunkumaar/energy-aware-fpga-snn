"""Bit-exact and protocol tests for the streamed L128 predictor."""

import json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

NUM_INPUTS = 4096
NUM_HIDDEN = 512
TIME_STEPS = 25
LANES = 128
HIDDEN_FOLDS = NUM_INPUTS // LANES
OUTPUT_FOLDS = NUM_HIDDEN // LANES
INPUT_WORDS = TIME_STEPS * HIDDEN_FOLDS
WEIGHTS_PER_BEAT = 8
WEIGHT_BEATS_PER_ROW = NUM_INPUTS // WEIGHTS_PER_BEAT
EXPECTED_COMPUTE_CYCLES = (
    HIDDEN_FOLDS * TIME_STEPS * NUM_HIDDEN
    + OUTPUT_FOLDS * TIME_STEPS * 2
)
EXPECTED_WEIGHT_CYCLES = NUM_HIDDEN * WEIGHT_BEATS_PER_ROW

HERE = Path(__file__).resolve().parent
DATA_DIR = HERE.parent.parent / "common" / "data"
MODEL_DIR = DATA_DIR / "model_params"
TV_DIR = DATA_DIR / "testvectors"


def load_hex_u16(path: Path, count: int) -> np.ndarray:
    with path.open() as source:
        data = np.asarray([int(x, 16) for x in source.read().split()], dtype=np.uint16)
    assert data.size == count
    return data


LAYER1_WEIGHTS = None


def layer1_weights() -> np.ndarray:
    global LAYER1_WEIGHTS
    if LAYER1_WEIGHTS is None:
        LAYER1_WEIGHTS = load_hex_u16(
            MODEL_DIR / "layer1_weights.hex", NUM_HIDDEN * NUM_INPUTS
        ).reshape(NUM_HIDDEN, NUM_INPUTS)
    return LAYER1_WEIGHTS


def pack_spikes(bits: np.ndarray) -> int:
    return int.from_bytes(
        np.packbits(bits.astype(np.uint8), bitorder="little").tobytes(), "little"
    )


def pack_weight_beat(words: np.ndarray) -> int:
    return int.from_bytes(words.astype("<u2", copy=False).tobytes(), "little")


async def reset_dut(dut) -> None:
    dut.rst.value = 1
    dut.start_image.value = 0
    dut.spike_valid.value = 0
    dut.spike_data.value = 0
    dut.row_request_ready.value = 0
    dut.weight_valid.value = 0
    dut.weight_data.value = 0
    dut.weight_last.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


class WeightRowSource:
    def __init__(self, weights: np.ndarray, delayed: bool = False):
        self.weights = weights
        self.delayed = delayed
        self.requests = []
        self.beats = 0

    async def run(self, dut) -> None:
        dut.row_request_ready.value = 1
        dut.weight_valid.value = 0
        dut.weight_data.value = 0
        dut.weight_last.value = 0

        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if not (int(dut.row_request_valid.value)
                    and int(dut.row_request_ready.value)):
                continue

            neuron = int(dut.row_request_neuron.value)
            self.requests.append(neuron)

            # More than the 288-cycle load/compute slack, deliberately forcing
            # a visible row stall on a sparse subset of rows.
            if self.delayed and neuron >= 2 and neuron % 64 == 2:
                for _ in range(400):
                    await RisingEdge(dut.clk)

            for beat in range(WEIGHT_BEATS_PER_ROW):
                await FallingEdge(dut.clk)
                while not int(dut.weight_ready.value):
                    dut.weight_valid.value = 0
                    await RisingEdge(dut.clk)
                    await FallingEdge(dut.clk)
                lo = beat * WEIGHTS_PER_BEAT
                dut.weight_data.value = pack_weight_beat(
                    self.weights[neuron, lo:lo + WEIGHTS_PER_BEAT]
                )
                dut.weight_last.value = int(beat == WEIGHT_BEATS_PER_ROW - 1)
                dut.weight_valid.value = 1
                await RisingEdge(dut.clk)
                self.beats += 1

            await FallingEdge(dut.clk)
            dut.weight_valid.value = 0
            dut.weight_last.value = 0


class SpikeTrace:
    def __init__(self):
        self.hidden = np.zeros((TIME_STEPS, NUM_HIDDEN), dtype=np.uint8)
        self.output = np.zeros((TIME_STEPS, 2), dtype=np.uint8)
        self.hidden_events = 0
        self.output_events = 0

    async def run(self, dut) -> None:
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.hidden_spike_valid.value):
                n = int(dut.hidden_spike_neuron.value)
                t = int(dut.hidden_spike_timestep.value)
                self.hidden[t, n] = int(dut.hidden_spike.value)
                self.hidden_events += 1
            if int(dut.output_spike_valid.value):
                n = int(dut.output_spike_neuron.value)
                t = int(dut.output_spike_timestep.value)
                self.output[t, n] = int(dut.output_spike.value)
                self.output_events += 1


async def send_input_spikes(dut, spikes: np.ndarray) -> None:
    assert spikes.shape == (TIME_STEPS, NUM_INPUTS)
    while not int(dut.spike_ready.value):
        await RisingEdge(dut.clk)

    for t in range(TIME_STEPS):
        for fold in range(HIDDEN_FOLDS):
            await FallingEdge(dut.clk)
            lo = fold * LANES
            dut.spike_data.value = pack_spikes(spikes[t, lo:lo + LANES])
            dut.spike_valid.value = 1
            await RisingEdge(dut.clk)
            assert int(dut.spike_ready.value)

    await FallingEdge(dut.clk)
    dut.spike_valid.value = 0


async def run_image(dut, image_index: int, delayed_weights: bool = False):
    npz = np.load(TV_DIR / "testvectors.npz")
    spikes = npz["spk_in"][image_index].reshape(TIME_STEPS, NUM_INPUTS)
    expected_hidden = npz[f"spk1_img{image_index:03d}"]
    expected_output = npz["spk_out"][image_index]

    source = WeightRowSource(layer1_weights(), delayed=delayed_weights)
    trace = SpikeTrace()
    source_task = cocotb.start_soon(source.run(dut))
    trace_task = cocotb.start_soon(trace.run(dut))

    while not int(dut.image_ready.value):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.start_image.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.start_image.value = 0

    await send_input_spikes(dut, spikes)

    timeout = 500_000 if not delayed_weights else 520_000
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.inference_valid.value):
            break
    else:
        raise AssertionError("inference_valid timeout")

    result = {
        "collision": int(dut.collision_counter.value),
        "no_collision": int(dut.no_collision_counter.value),
        "inference_cycles": int(dut.inference_cycles.value),
        "compute_cycles": int(dut.compute_cycles.value),
        "weight_cycles": int(dut.weight_load_cycles.value),
        "input_cycles": int(dut.input_load_cycles.value),
        "row_stalls": int(dut.row_stall_cycles.value),
    }

    source_task.cancel()
    trace_task.cancel()
    # Leave the ReadOnly phase before a following image creates new drivers.
    await FallingEdge(dut.clk)

    assert source.requests == list(range(NUM_HIDDEN))
    assert source.beats == EXPECTED_WEIGHT_CYCLES
    assert trace.hidden_events == TIME_STEPS * NUM_HIDDEN
    assert trace.output_events == TIME_STEPS * 2
    np.testing.assert_array_equal(trace.hidden, expected_hidden)
    np.testing.assert_array_equal(trace.output, expected_output)

    expected_no_collision, expected_collision = expected_output.sum(axis=0)
    assert result["no_collision"] == int(expected_no_collision)
    assert result["collision"] == int(expected_collision)
    assert result["compute_cycles"] == EXPECTED_COMPUTE_CYCLES
    assert result["weight_cycles"] == EXPECTED_WEIGHT_CYCLES
    assert result["input_cycles"] == INPUT_WORDS
    assert not int(dut.protocol_error.value)
    assert EXPECTED_COMPUTE_CYCLES < result["inference_cycles"] < 450_000
    # The concurrent loader must beat the serialized load+compute schedule.
    assert result["inference_cycles"] < (
        INPUT_WORDS + EXPECTED_COMPUTE_CYCLES + EXPECTED_WEIGHT_CYCLES
    )

    dut._log.info("image=%d result=%s", image_index, result)
    return result


@cocotb.test()
async def bit_exact_full_network(dut):
    """Check every hidden/output spike and every architecture counter."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    first = await run_image(dut, 0, delayed_weights=False)
    second = await run_image(dut, 1, delayed_weights=False)
    assert first["row_stalls"] == 0
    assert second["row_stalls"] == 0
    assert first["inference_cycles"] == second["inference_cycles"]


@cocotb.test()
async def bit_exact_with_stream_backpressure(dut):
    """Retain bit-exact results when the external row stream stalls."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    result = await run_image(dut, 2, delayed_weights=True)
    assert result["row_stalls"] > 0


@cocotb.test()
async def bad_weight_last_sets_protocol_error(dut):
    """An early weight_last is sticky until the next image starts."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    await FallingEdge(dut.clk)
    dut.start_image.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.start_image.value = 0
    dut.row_request_ready.value = 1

    while not int(dut.row_request_valid.value):
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    while not int(dut.weight_ready.value):
        await RisingEdge(dut.clk)

    await FallingEdge(dut.clk)
    dut.weight_valid.value = 1
    dut.weight_data.value = 0
    dut.weight_last.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.protocol_error.value) == 1
