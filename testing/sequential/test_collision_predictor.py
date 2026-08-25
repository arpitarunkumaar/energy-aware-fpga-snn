"""cocotb tests for collision_predictor.

Two cases (see team-22 test spec for this DUT):
  1. timing      — Feed the model with 3 back-to-back images and check
                   out_valid fires at exactly the expected cycles.
  2. correctness — replay images from sw/testvectors/testvectors.npz and
                   check collision_counter / no_collision_counter against a
                   bit-exact integer golden of sim/common/lif_model.sv
                   (unsigned 28-bit MAC + LIF, uth=8938/6775, k=15).

The snntorch float model in manifest.json is a different LIF (learned beta,
no 5-step refractory, Q1.15 threshold) so its spike_counts will not match
this DUT; they are logged only as a reference.

Latency constants below reflect a read of collision_predictor.sv. If the RTL
changes (esp. LIF or MAC pipeline depth), tune DRAIN_LATENCY.

Weight hex file paths are passed as -G parameter overrides by test_runner.py;
the RTL loads them via $readmemh in an initial block, so weights are baked in
at sim start.
"""

import json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# ---- geometry / LIF params (must match collision_predictor.sv) ----
NUM_INPUTS              = 4096
NUM_HIDDEN_LAYER        = 512
TIME_STEPS              = 25
FIRST_LAYER_K           = 15
SECOND_LAYER_K          = 15
FIRST_LAYER_THRESHOLD   = 8938
SECOND_LAYER_THRESHOLD  = 6775
REFRACTORY_COUNTER_MAX  = 5
_MAC_MASK               = (1 << 28) - 1
_LEAK_MASK              = (1 << 32) - 1

# ---- latency model ----
# Input phase: NUM_HIDDEN_LAYER cycles per time step, all TIME_STEPS back-to-back.
# Drain after the last input cycle of the last time step (measured 18 cycles):
#   cascaded_adder pipeline:             clog2(NUM_INPUTS) + 1 = 13
#   in_valid_lif / input_current flop:   1
#   first-layer LIF register:            1
#   lif_output_valid / layer-2 MAC flop: 1
#   second-layer LIF register:           1
#   out_valid relay register:            1
CASCADED_ADDER_LATENCY = (NUM_INPUTS - 1).bit_length() + 1  # 13
WEIGHT_LOADING_LATENCY = 1
DRAIN_LATENCY          = CASCADED_ADDER_LATENCY + 5          # 18
INPUT_PHASE_CYCLES     = NUM_HIDDEN_LAYER * TIME_STEPS       # 12800
CYCLES_PER_IMAGE       = WEIGHT_LOADING_LATENCY + INPUT_PHASE_CYCLES + DRAIN_LATENCY  # 12819

# ---- correctness subset ----
# None = replay every image in manifest.json; set an int to iterate faster.
CORRECTNESS_LIMIT: int | None = 3

# ---- paths ----
_HERE     = Path(__file__).resolve().parent
_REPO_DIR = _HERE.parent.parent  # testing/sequential -> testing -> repo
SW_TV_DIR = _REPO_DIR / "sw" / "testvectors"
SW_MP_DIR = _REPO_DIR / "sw" / "model_params"


# ---- helpers ----

def _start_clock(dut, period_ns: int = 10) -> None:
    cocotb.start_soon(Clock(dut.clk, period_ns, units="ns").start())


def _set_spikes(dut, packed: int) -> None:
    """Drive dut.spikes whether it's a packed vector or an unpacked array."""
    try:
        dut.spikes.value = packed
    except (TypeError, ValueError):
        for i in range(NUM_INPUTS):
            dut.spikes[i].value = (packed >> i) & 1


async def _reset(dut, cycles: int = 2) -> None:
    dut.rst.value           = 1
    dut.new_image.value     = 0
    dut.new_time_step.value = 0
    _set_spikes(dut, 0)
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def _pack_row(row: np.ndarray) -> int:
    """Pack a length-NUM_INPUTS uint8 row into a Python int (LSB = index 0)."""
    v = 0
    for i, bit in enumerate(row):
        if bit:
            v |= 1 << i
    return v


async def _feed_image(dut, spike_trains: np.ndarray, upcoming_image: bool) -> None:
    """Push one image's [TIME_STEPS, NUM_INPUTS] spike vectors.

    Per time step: assert new_image (t=0) or new_time_step (t>0) for one cycle
    together with the spike vector; hold the spike vector for NUM_HIDDEN_LAYER-1
    more cycles while the cascaded_adder walks the weight rows.
    """
    assert spike_trains.shape == (TIME_STEPS, NUM_INPUTS), (
        f"spike_trains shape {spike_trains.shape} != ({TIME_STEPS}, {NUM_INPUTS})"
    )
    for t in range(TIME_STEPS):
        _set_spikes(dut, _pack_row(spike_trains[t]))
        dut.new_image.value = 0
        dut.new_time_step.value = 0
        for j in range(NUM_HIDDEN_LAYER - 1):
            await RisingEdge(dut.clk)
            if t == 0 and j == 3:
                # Debug logging
                row  = 0
                l1   = [int(dut.layer1_weights[row][k].value.signed_integer) for k in range(8)]
                l2c0 = [int(dut.layer2_weights[0][k].value.signed_integer) for k in range(8)]
                l2c1 = [int(dut.layer2_weights[1][k].value.signed_integer) for k in range(8)]
                dut._log.info(f"layer1_weights[{row}][0:8]      = {l1}")
                dut._log.info(f"layer2_weights[0 (no_col)][0:8] = {l2c0}")
                dut._log.info(f"layer2_weights[1 (col)][0:8]    = {l2c1}")
        if t < TIME_STEPS - 1:
            dut.new_time_step.value = 1
        elif t == TIME_STEPS - 1 and upcoming_image:
            dut.new_image.value = 1
            dut.new_time_step.value = 1
        await RisingEdge(dut.clk)


class OutValidMonitor:
    """Records (cycle, collision_counter, no_collision_counter) for each out_valid rising edge.

    `cycle` is counted from the first RisingEdge after monitor.start() — this is
    the same edge that _feed_image samples new_image on, so out_valid pulses at
    cycle == image_index * INPUT_PHASE_CYCLES + CYCLES_PER_IMAGE.
    """

    def __init__(self):
        self.pulses: list[dict] = []
        self.cycle: int = 0
        self._stop = False

    def start(self, dut):
        cocotb.start_soon(self._run(dut))

    def stop(self):
        self._stop = True

    async def _run(self, dut):
        while not self._stop:
            await RisingEdge(dut.clk)
            self.cycle += 1
            if int(dut.out_valid.value) == 1:
                self.pulses.append({
                    "cycle":        self.cycle,
                    "collision":    int(dut.collision_counter.value),
                    "no_collision": int(dut.no_collision_counter.value),
                })


async def _wait_for_pulse(monitor: OutValidMonitor, dut, target_count: int, deadline: int) -> None:
    """Advance the clock until monitor has target_count pulses or deadline elapses."""
    for _ in range(deadline):
        if len(monitor.pulses) >= target_count:
            return
        await RisingEdge(dut.clk)

async def _new_image_coming(dut):
    # Assert new_image 1 cycle before feeding spikes
    dut.new_image.value = 1
    dut.new_time_step.value = 1
    await RisingEdge(dut.clk)

# ---- test 1: timing ----

@cocotb.test()
async def timing(dut):
    """Feed 3 back-to-back images; out_valid must pulse at each expected cycle."""
    NUM_IMAGES = 3
    _start_clock(dut)
    await _reset(dut)

    monitor = OutValidMonitor()
    monitor.start(dut)

    rng = np.random.default_rng(0x717717)

    async def feed_all():
        await _new_image_coming(dut)
        for i in range(NUM_IMAGES):
            # Generate a random image (matrix) of size 25x4096 to feed as an input
            spike_trains = rng.integers(0, 2, size=(TIME_STEPS, NUM_INPUTS), dtype=np.uint8)
            upcoming_image = True if i < NUM_IMAGES-1 else False
            await _feed_image(dut, spike_trains, upcoming_image)

    feed = cocotb.start_soon(feed_all())

    deadline = NUM_IMAGES * INPUT_PHASE_CYCLES + DRAIN_LATENCY + 32
    await _wait_for_pulse(monitor, dut, NUM_IMAGES, deadline)

    await feed
    monitor.stop()

    got_cycles = [p["cycle"] for p in monitor.pulses]
    expected_cycles = [
        (i * INPUT_PHASE_CYCLES) + CYCLES_PER_IMAGE
        for i in range(NUM_IMAGES)
    ]
    assert got_cycles == expected_cycles, (
        f"out_valid cycles mismatch:\n"
        f"  expected {expected_cycles}\n"
        f"  got      {got_cycles}\n"
        f"  (INPUT_PHASE_CYCLES={INPUT_PHASE_CYCLES}, DRAIN_LATENCY={DRAIN_LATENCY})"
    )


# ---- test 2: correctness ----

def _load_hex_i16(path: Path) -> np.ndarray:
    vals = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
    return np.array(vals, dtype=np.int32)


def _load_hw_params() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    w1 = _load_hex_i16(SW_MP_DIR / "layer1_weights.hex").reshape(NUM_HIDDEN_LAYER, NUM_INPUTS)
    b1 = _load_hex_i16(SW_MP_DIR / "layer1_biases.hex")
    w2 = _load_hex_i16(SW_MP_DIR / "layer2_weights.hex").reshape(2, NUM_HIDDEN_LAYER)
    b2 = _load_hex_i16(SW_MP_DIR / "layer2_biases.hex")
    return w1, b1, w2, b2


def _lif_step(u: int, ctr: int, current: int, new_image: bool, uth: int, k: int) -> tuple[int, int, int]:
    """One sequential-neuron enable of sim/common/lif_model.sv (unsigned 28-bit)."""
    current &= _MAC_MASK
    if new_image:
        return 0, current, 0
    if ctr == REFRACTORY_COUNTER_MAX - 1:
        return 0, 0, 0
    if (u & _MAC_MASK) >= uth:
        return 1, 0, 1
    if ctr != 0:
        return 0, u, (ctr + 1) & 0xF
    leak = ((u - 0) & _LEAK_MASK) >> k
    return 0, (u - leak + current) & _MAC_MASK, 0


def _hw_spike_counts(
    spike_trains: np.ndarray,
    w1: np.ndarray,
    b1: np.ndarray,
    w2: np.ndarray,
    b2: np.ndarray,
) -> tuple[int, int]:
    """Return (no_collision, collision) spike counts for one image."""
    u1 = np.zeros(NUM_HIDDEN_LAYER, dtype=np.int64)
    c1 = np.zeros(NUM_HIDDEN_LAYER, dtype=np.int32)
    u2 = np.zeros(2, dtype=np.int64)
    c2 = np.zeros(2, dtype=np.int32)
    counts = [0, 0]
    for t in range(TIME_STEPS):
        sp = spike_trains[t].astype(np.int32)
        mac1 = ((w1.astype(np.int64) * sp[np.newaxis, :]).sum(axis=1) + b1.astype(np.int64)) & _MAC_MASK
        hsp = np.zeros(NUM_HIDDEN_LAYER, dtype=np.int32)
        for n in range(NUM_HIDDEN_LAYER):
            spk, u1[n], c1[n] = _lif_step(
                int(u1[n]), int(c1[n]), int(mac1[n]), t == 0,
                FIRST_LAYER_THRESHOLD, FIRST_LAYER_K,
            )
            hsp[n] = spk
        mac2 = ((w2.astype(np.int64) * hsp[np.newaxis, :]).sum(axis=1) + b2.astype(np.int64)) & _MAC_MASK
        for n in range(2):
            spk, u2[n], c2[n] = _lif_step(
                int(u2[n]), int(c2[n]), int(mac2[n]), t == 0,
                SECOND_LAYER_THRESHOLD, SECOND_LAYER_K,
            )
            counts[n] += spk
    return counts[0], counts[1]


def _load_manifest() -> tuple[np.ndarray, list[dict]]:
    npz = np.load(SW_TV_DIR / "testvectors.npz")
    with open(SW_TV_DIR / "manifest.json") as f:
        manifest = json.load(f)
    return npz["spk_in"], manifest["records"]


@cocotb.test()
async def correctness(dut):
    """Replay testvector images; RTL counters must match the integer LIF golden."""
    spk_in_all, records = _load_manifest()
    if CORRECTNESS_LIMIT is not None:
        spk_in_all = spk_in_all[:CORRECTNESS_LIMIT]
        records    = records[:CORRECTNESS_LIMIT]
    N = len(records)
    w1, b1, w2, b2 = _load_hw_params()

    _start_clock(dut)
    await _reset(dut)

    monitor = OutValidMonitor()
    monitor.start(dut)

    mismatches: list[dict] = []

    for i, record in enumerate(records):
        await _new_image_coming(dut)
        spike_trains = spk_in_all[i].reshape(TIME_STEPS, NUM_INPUTS)
        await _feed_image(dut, spike_trains, upcoming_image=False)

        # Drain window: full pipeline latency + a small safety margin.
        deadline = DRAIN_LATENCY + 8
        await _wait_for_pulse(monitor, dut, i + 1, deadline)

        assert len(monitor.pulses) == i + 1, (
            f"image {i} ({record['image_path']}): out_valid did not fire within "
            f"{deadline} cycles of the last input"
        )
        pulse = monitor.pulses[-1]
        expected_no_collision, expected_collision = _hw_spike_counts(
            spike_trains, w1, b1, w2, b2,
        )
        sw_no_collision, sw_collision = record["spike_counts"]
        dut._log.info(
            f"image {i}: RTL col={pulse['collision']} nocol={pulse['no_collision']} "
            f"HW-golden col={expected_collision} nocol={expected_no_collision} "
            f"snntorch col={sw_collision} nocol={sw_no_collision}"
        )
        if (pulse["collision"] != expected_collision
                or pulse["no_collision"] != expected_no_collision):
            mismatches.append({
                "index":                 i,
                "image_path":            record["image_path"],
                "expected_collision":    expected_collision,
                "got_collision":         pulse["collision"],
                "expected_no_collision": expected_no_collision,
                "got_no_collision":      pulse["no_collision"],
            })

    monitor.stop()

    if mismatches:
        first = mismatches[0]
        raise AssertionError(
            f"{len(mismatches)}/{N} counter mismatches vs integer LIF golden; first: "
            f"img {first['index']} ({first['image_path']}): "
            f"collision expected {first['expected_collision']} got {first['got_collision']}, "
            f"no_collision expected {first['expected_no_collision']} got {first['got_no_collision']}"
        )
