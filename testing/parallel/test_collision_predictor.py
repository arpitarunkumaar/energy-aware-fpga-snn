"""cocotb tests for collision_predictor.

Four cases (see team-22 test spec for this DUT):
  1. timing      — Feed the model with 3 back-to-back images and check
                   out_valid fires at exactly the expected cycles.
  2. correctness — replay every image from sw/testvectors/testvectors.npz and
                   check collision_counter / no_collision_counter agree with
                   sw/testvectors/manifest.json's spike_counts.
  3. throughput  — stream TOTAL_LATENCY*2 real images back-to-back (no gap) to
                   keep the pipeline full, then check we get one out_valid per
                   image, spaced every TIME_STEPS cycles. No correctness check,
                   so it passes at any NUM_HIDDEN.
  4. correctness_latency_and_throughput — the same back-to-back stream, PLUS an exact
                   out_valid latency check and the manifest correctness check
                   (timing + throughput + correctness). The correctness half
                   needs the real 512-neuron weights.

Latency constants below reflect a read of collision_predictor.sv. If the RTL
changes (esp. LIF or MAC pipeline depth), re-derive the terms that feed
TOTAL_LATENCY.

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

# ---- geometry (must match collision_predictor.sv parameters) ----
NUM_INPUTS       = 4096
NUM_HIDDEN_LAYER = 512
TIME_STEPS       = 25

# ---- latency model ----
# Cycles from a time step driven on `spikes` to its out_valid pulse. Each term is
# one real flop on the out_valid (valid/control) chain, confirmed by dumping the
# valid signals: nts@1 -> in_valid@2 -> L1 valid_out@15 -> l1lif_valid@16 ->
# L2 valid_out@19 -> second_layer_enable@20 -> out_valid (+1); sum = 20.
#
# NOTE: the leading flop is the input-valid register (new_time_step/new_image
# latched into in_valid_cascaded_adder), NOT weight loading. Weights are
# $readmemh'd once at sim init, and the spike x weight gate is stage 0 of the
# adder, already counted inside CASCADED_ADDER_LAYER1_LATENCY (= clog2(N)+1, the
# valid_pipe depth).
INPUT_VALID_LATENCY = 1
CASCADED_ADDER_LAYER1_LATENCY = (NUM_INPUTS - 1).bit_length() + 1  # 13
ADD_BIAS_LATENCY = 1   # L1/L2 valid advances into the LIF, coincident with the bias add
LIF_LATENCY = 0        # LIF spike is combinational
OUTPUT_LATENCY = 1     # out_valid register
CASCADED_ADDER_LAYER2_LATENCY = (NUM_HIDDEN_LAYER - 1).bit_length() + 1  # 3 @ NUM_HIDDEN=4, 10 @ 512
TOTAL_LATENCY = (INPUT_VALID_LATENCY + CASCADED_ADDER_LAYER1_LATENCY + ADD_BIAS_LATENCY + LIF_LATENCY
                 + CASCADED_ADDER_LAYER2_LATENCY + ADD_BIAS_LATENCY + LIF_LATENCY + OUTPUT_LATENCY)  # 20 / 27

# ---- correctness subset ----
# None = replay every image in manifest.json; set an int to iterate faster.
CORRECTNESS_LIMIT: int | None = None

# Specific image indices to test instead of a 0:N range (None = use CORRECTNESS_LIMIT/all)
CORRECTNESS_INDICES: list[int] | None = list(range(300,451))

# ---- paths ----
_HERE     = Path(__file__).resolve().parent
_REPO_DIR = _HERE.parent.parent
SW_TV_DIR = _REPO_DIR / "sw" / "testvectors"


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
        dut.new_time_step.value = 1
        if t == TIME_STEPS - 1 and upcoming_image:
            dut.new_image.value = 1
        await RisingEdge(dut.clk)


class OutValidMonitor:
    """Records (cycle, collision_counter, no_collision_counter) at each out_valid rising edge.

    `cycle` counts RisingEdges from monitor.start(); edge 1 is the priming new_image
    edge driven by _new_image_coming. Recorded out_valid cycles therefore line up
    with _expected_out_valid_cycles(num_images).
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


def _expected_out_valid_cycles(num_images: int) -> list[int]:
    """Monitor cycles at which out_valid should pulse for `num_images` fed
    back-to-back (via _new_image_coming + _feed_image).

    out_valid for image i fires exactly TOTAL_LATENCY cycles after the TB drives
    that image's LAST time step (verified: image 0's last step is driven on monitor
    cycle 26 and out_valid pulses on cycle 46 = 26 + TOTAL_LATENCY). That last step
    lands on cycle TIME_STEPS*(i+1) + EXPECTED_CYCLE_OFFSET: the monitor's first
    counted edge is the priming new_image from _new_image_coming (spikes=0), which
    shifts image 0's TIME_STEPS real steps by one. The offset is a schedule shift,
    independent of (not double-counting) TOTAL_LATENCY.
    """
    EXPECTED_CYCLE_OFFSET = 1
    return [
        TOTAL_LATENCY + (i + 1) * TIME_STEPS + EXPECTED_CYCLE_OFFSET
        for i in range(num_images)
    ]


# ---- test 1: timing ----

# @cocotb.test()
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
            # Generate a random image (matrix) of size TIME_STEPS x NUM_INPUTS to feed as an input
            spike_trains = rng.integers(0, 2, size=(TIME_STEPS, NUM_INPUTS), dtype=np.uint8)
            upcoming_image = True if i < NUM_IMAGES-1 else False
            await _feed_image(dut, spike_trains, upcoming_image)

    feed = cocotb.start_soon(feed_all())

    deadline = TOTAL_LATENCY + NUM_IMAGES*TIME_STEPS + 32
    await _wait_for_pulse(monitor, dut, NUM_IMAGES, deadline)

    await feed
    monitor.stop()

    got_cycles = [p["cycle"] for p in monitor.pulses]
    expected_cycles = _expected_out_valid_cycles(NUM_IMAGES)
    assert got_cycles == expected_cycles, (
        f"out_valid cycles mismatch:\n"
        f"  expected {expected_cycles}\n"
        f"  got      {got_cycles}\n"
    )


# ---- test 2: correctness ----

def _load_manifest() -> tuple[np.ndarray, list[dict]]:
    npz = np.load(SW_TV_DIR / "testvectors.npz")
    with open(SW_TV_DIR / "manifest.json") as f:
        manifest = json.load(f)
    return npz["spk_in"], manifest["records"]


def _dump_mismatches(mismatches: list[dict], label: str) -> Path:
    """Write the full mismatch list to a JSON file next to this test for offline
    inspection, and return the path.

    The AssertionError only surfaces the first mismatch, but for debugging a
    counter bug the useful signal is the whole per-image pattern. Dumping the full
    list lets us see that pattern at a glance.
    """
    out = _HERE / f"mismatches_{label}.json"
    with open(out, "w") as f:
        json.dump(mismatches, f, indent=2)
    return out


@cocotb.test()
async def correctness(dut):
    """Replay every manifest.json image; RTL counters must match spike_counts."""
    spk_in_all, records = _load_manifest()
    if CORRECTNESS_INDICES is not None:
        idxs = list(CORRECTNESS_INDICES)
        spk_in_all = spk_in_all[idxs]
        records    = [records[i] for i in idxs]
    elif CORRECTNESS_LIMIT is not None:
        spk_in_all = spk_in_all[:CORRECTNESS_LIMIT]
        records    = records[:CORRECTNESS_LIMIT]
        idxs = list(range(len(records)))
    else:
        idxs = list(range(len(records)))
    # idxs[i] maps a subset position i back to its true manifest image index, so the
    # dump/assertions report the real image (e.g. 300..450), not a 0-based offset.
    N = len(records)

    _start_clock(dut)
    await _reset(dut)

    monitor = OutValidMonitor()
    monitor.start(dut)

    mismatches: list[dict] = []

    for i, record in enumerate(records):
        manifest_index = idxs[i]
        await _new_image_coming(dut)
        spike_trains = spk_in_all[i].reshape(TIME_STEPS, NUM_INPUTS)
        await _feed_image(dut, spike_trains, upcoming_image=False)

        # Drain window: full pipeline latency + a small safety margin.
        deadline = TOTAL_LATENCY + 8
        await _wait_for_pulse(monitor, dut, i + 1, deadline)

        assert len(monitor.pulses) == i + 1, (
            f"image {manifest_index} ({record['image_path']}): out_valid did not fire "
            f"within {deadline} cycles of the last input"
        )
        pulse = monitor.pulses[-1]
        # manifest spike_counts is [class_0=safe, class_1=collision]
        expected_no_collision, expected_collision = record["spike_counts"]
        if (pulse["collision"] != expected_collision
                or pulse["no_collision"] != expected_no_collision):
            mismatches.append({
                "index":                 manifest_index,
                "image_path":            record["image_path"],
                "expected_collision":    expected_collision,
                "got_collision":         pulse["collision"],
                "expected_no_collision": expected_no_collision,
                "got_no_collision":      pulse["no_collision"],
            })

    monitor.stop()

    if mismatches:
        dump_path = _dump_mismatches(mismatches, "correctness")
        first = mismatches[0]
        raise AssertionError(
            f"{len(mismatches)}/{N} counter mismatches vs manifest "
            f"(full list dumped to {dump_path}); first: "
            f"img {first['index']} ({first['image_path']}): "
            f"collision expected {first['expected_collision']} got {first['got_collision']}, "
            f"no_collision expected {first['expected_no_collision']} got {first['got_no_collision']}"
        )


# ---- tests 3 & 4: back-to-back streaming ----
# Both tests stream TOTAL_LATENCY*2 real manifest images with NO gap between them
# (like the timing test, each image asserts new_image on its last time step, so the
# next image's step 0 lands on the very next cycle). With that many images fed
# gap-lessly the pipeline is kept continuously full (several images in flight at
# once), so they exercise the steady-state streaming path that neither earlier test
# does — timing feeds random data (no correctness check) and correctness drains
# fully between single images. A per-image reset bug (LIF membrane or spike-tally
# carryover between adjacent images) shows up here as a wrong counter, a
# missing/extra out_valid, or a shifted out_valid cycle — all invisible when
# images are isolated.
#
# The two tests share the same stream (via _stream_back_to_back) and differ only in
# what they check:
#   test 3 (throughput)              — one out_valid per image, spaced every
#                                      TIME_STEPS cycles. No correctness check, so
#                                      it passes at any NUM_HIDDEN.
#   test 4 (correctness_latency_and_throughput)  — the same throughput check, PLUS an exact
#                                      out_valid latency check and the manifest
#                                      correctness check (timing + throughput +
#                                      correctness). The correctness half needs the
#                                      real 512-neuron weights (NUM_HIDDEN == 512).


async def _stream_back_to_back(dut) -> tuple["OutValidMonitor", list[dict], int]:
    """Reset, then stream TOTAL_LATENCY*2 real images gap-lessly.

    Shared by both back-to-back tests, which differ only in the checks they run on
    the returned monitor. Returns (monitor, records, num_images) once every image's
    out_valid has been collected (or the deadline elapsed).
    """
    spk_in_all, records = _load_manifest()
    # TOTAL_LATENCY*2 images is comfortably more than the pipeline holds
    # (~TOTAL_LATENCY/TIME_STEPS images in flight), so the pipeline reaches and
    # sustains steady state.
    assert len(records) > TOTAL_LATENCY * 2  # This is an assumption that must hold for these tests to run
    num_images = TOTAL_LATENCY * 2
    spk_in_all = spk_in_all[:num_images]
    records    = records[:num_images]

    _start_clock(dut)
    await _reset(dut)

    monitor = OutValidMonitor()
    monitor.start(dut)

    async def feed_all():
        await _new_image_coming(dut)
        for i in range(num_images):
            spike_trains = spk_in_all[i].reshape(TIME_STEPS, NUM_INPUTS)
            # Assert new_image on every image's last step except the final one,
            # so images stream with no idle cycle between them.
            upcoming = i < num_images - 1
            await _feed_image(dut, spike_trains, upcoming_image=upcoming)

    feed = cocotb.start_soon(feed_all())

    # Last image's out_valid lands ~TOTAL_LATENCY after its last time step, i.e.
    # ~TOTAL_LATENCY + num_images*TIME_STEPS cycles in; add margin for the priming
    # cycle and drain (mirrors the timing test's deadline).
    deadline = TOTAL_LATENCY + num_images * TIME_STEPS + 32
    await _wait_for_pulse(monitor, dut, num_images, deadline)

    await feed
    monitor.stop()
    return monitor, records, num_images


def _assert_one_out_valid_per_image(monitor: OutValidMonitor, num_images: int) -> None:
    """Exactly one out_valid per image — no image dropped a result and none emitted
    a spurious extra pulse while the pipeline was kept full."""
    assert len(monitor.pulses) == num_images, (
        f"expected {num_images} out_valid pulses (one per image), got "
        f"{len(monitor.pulses)} at cycles {[p['cycle'] for p in monitor.pulses]}"
    )


def _assert_out_valid_full_throughput(monitor: OutValidMonitor) -> None:
    """Full throughput: consecutive out_valids are separated by exactly TIME_STEPS
    cycles — i.e. the pipeline never stalled and sustained one result per
    image-period across the whole run."""
    gaps = [
        monitor.pulses[i]["cycle"] - monitor.pulses[i - 1]["cycle"]
        for i in range(1, len(monitor.pulses))
    ]
    assert all(g == TIME_STEPS for g in gaps), (
        f"out_valid pulses not spaced every TIME_STEPS ({TIME_STEPS}) cycles "
        f"(pipeline stalled); gaps={gaps}"
    )


# @cocotb.test()
async def throughput(dut):
    """Stream TOTAL_LATENCY*2 images back-to-back; one out_valid per image, no stalls.

    Throughput only (no correctness check), so this passes even at NUM_HIDDEN != 512,
    where the RTL fills weights with 1s and cannot match the manifest.
    """
    monitor, _records, num_images = await _stream_back_to_back(dut)
    _assert_one_out_valid_per_image(monitor, num_images)
    _assert_out_valid_full_throughput(monitor)


# @cocotb.test()
async def correctness_latency_and_throughput(dut):
    """Same back-to-back stream as `throughput`, plus an exact out_valid latency
    check and the manifest correctness check: timing + throughput + correctness in
    one steady-state run.

    The correctness half needs the real 512-neuron weights (NUM_HIDDEN_LAYER == 512);
    at other sizes the RTL fills weights with 1s and the manifest check will fail.
    """
    monitor, records, num_images = await _stream_back_to_back(dut)

    # --- throughput: one out_valid per image, spaced every TIME_STEPS cycles ---
    _assert_one_out_valid_per_image(monitor, num_images)
    _assert_out_valid_full_throughput(monitor)

    # --- latency (timing): each image's out_valid fires exactly TOTAL_LATENCY cycles
    # after the TB drives that image's last time step — the same schedule the timing
    # test checks (see _expected_out_valid_cycles). ---
    got_cycles = [p["cycle"] for p in monitor.pulses]
    expected_cycles = _expected_out_valid_cycles(num_images)
    assert got_cycles == expected_cycles, (
        f"out_valid latency mismatch under back-to-back streaming:\n"
        f"  expected {expected_cycles}\n"
        f"  got      {got_cycles}\n"
    )

    # --- correctness: each pulse, in order, must match its image's manifest counters ---
    mismatches: list[dict] = []
    for i, (record, pulse) in enumerate(zip(records, monitor.pulses)):
        # manifest spike_counts is [class_0=safe/no_collision, class_1=collision]
        expected_no_collision, expected_collision = record["spike_counts"]
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

    if mismatches:
        first = mismatches[0]
        raise AssertionError(
            f"{len(mismatches)}/{num_images} counter mismatches vs manifest under "
            f"back-to-back streaming; first: img {first['index']} "
            f"({first['image_path']}): collision expected {first['expected_collision']} "
            f"got {first['got_collision']}, no_collision expected "
            f"{first['expected_no_collision']} got {first['got_no_collision']}"
        )
