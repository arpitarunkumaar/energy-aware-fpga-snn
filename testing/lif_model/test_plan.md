# `lif` Unit Test Plan

Tests for the leaky integrate-and-fire neuron (`rtl/lif_model.sv`) in
isolation. Every case is checked cycle-by-cycle against a bit-exact software
reference (`common/reference.py::LifModel`) that reproduces the RTL's
unsigned 28-bit membrane arithmetic, including wraparound when
`internal_value < urest`.

Supersedes the legacy SV testbench (`testing/lif_model_tb.sv`): its three
tests (reset, enable-freeze, subthreshold) are ported here, and its TODO
(threshold firing) plus refractory and randomized coverage are added.

## 1. Reset behavior

| Test | Stimulus | Expected |
| --- | --- | --- |
| `reset_clears_state` | `rst=1` with `enable=1`, large current | `spike=0`, `internal_value=0`, `refractory_counter=0`, held for the whole reset |

Note `rst` is sampled only when `enable=1` (reset is gated by enable in the RTL).

## 2. Enable gating

| Test | Stimulus | Expected |
| --- | --- | --- |
| `disabled_neuron_freezes` | Charge partway, then `enable=0` with large current | `spike` forced low, `internal_value` frozen; integration resumes on re-enable |

## 3. Integrate / leak / fire

| Test | Stimulus | Expected |
| --- | --- | --- |
| `subthreshold_never_spikes` | Constant current = 1 | Leakage keeps `internal_value < uth`; no spike over 30 cycles |
| `fires_at_threshold` | Constant current = `uth` | Membrane crosses `uth`; `spike` pulses exactly 1 cycle; membrane clears to 0 and `refractory_counter` starts at 1 |

## 4. Refractory period

| Test | Stimulus | Expected |
| --- | --- | --- |
| `refractory_blocks_input` | Saturating current (4·`uth`) held for many cycles | Input ignored during the refractory window; consecutive spikes exactly `refractory_counter_max + 1` cycles apart |

## 5. Randomized lockstep

| Test | Stimulus | Expected |
| --- | --- | --- |
| `random_stimulus` | 400 cycles of random current (zero / subthreshold / near-threshold / full 28-bit range), ~10% `enable=0`, ~2% `rst` pulses | `spike`, `internal_value`, `refractory_counter` match the golden model every cycle |

Full-range currents deliberately overflow the 28-bit membrane to confirm the
model and RTL wrap identically.

## 6. Parameter sweep

All cases run for each build configuration:

| cfg | k | uth | urest | refractory_counter_max | Why |
| --- | --- | --- | --- | --- | --- |
| `defaults` | 5 | 100 | 0 | 5 | RTL default parameters |
| `sv_tb` | 2 | 20 | 5 | 5 | Legacy SV testbench parameters; `urest > 0` exercises the unsigned-underflow leak path |
| `min_refractory` | 1 | 8 | 0 | 2 | Smallest sane refractory window (counter clears the cycle after a spike) |
