# `cascaded_adder` Unit Test Plan

Black-box tests for verifying `cascaded_adder` in isolation.

## 1. Functional correctness

Compared against a software reference model (`sum = Σ spike[i] * weight[i]`, signed).

| Test | Stimulus | Expected |
| --- | --- | --- |
| Random vectors | Many iterations of random `weight` and `spike` | Matches reference |
| All-zero spikes | `spike[*] = 0`, any weights | `out == 0` |
| All-one spikes | `spike[*] = 1`, any weights | `out == Σ weight` |
| One-hot spike | Exactly one `spike[i] = 1` | `out == weight[i]` |

## 2. Signed and boundary values

| Test | Stimulus | Expected |
| --- | --- | --- |
| Max positive sum | All spikes high, all weights = `0x7FFF` | No overflow; matches reference |
| Max negative sum | All spikes high, all weights = `0x8000` | No overflow; correct sign |
| Mixed-sign cancellation | Alternating `+0x4000` / `-0x4000`, all spikes high | `out ≈ 0` |

Catches sign-extension bugs and confirms `OUT_WIDTH` accommodates worst-case growth.

## 3. Pipeline timing

| Test | Stimulus | Expected |
| --- | --- | --- |
| Latency | Single `valid_in` pulse | `valid_out` rises after the spec'd fixed latency |
| Saturated throughput | `valid_in` held high for many cycles, distinct data each cycle | One correct result per cycle, in input order |
| Bubbles | `valid_in` pattern with gaps (e.g. `1,1,0,1,1`) | `valid_out` reproduces the same gap pattern |

## 4. Reset behavior

| Test | Stimulus | Expected |
| --- | --- | --- |
| Reset at startup | `rst_n = 0` during initial cycles | `valid_out` stays low; no glitches |
| Mid-flight reset | Assert `rst_n = 0` with iterations in the pipeline | No stale `valid_out` after deassertion |
| Resume after reset | Drive a fresh `valid_in` post-reset | Correct result, correct latency |

## 5. Input contract

| Test | Stimulus | Expected |
| --- | --- | --- |
| Garbage when `valid_in = 0` | Drive arbitrary `spike` / `weight` during idle cycles | Next valid iteration's `out` is uncorrupted |

Documents that inputs are don't-care when `valid_in` is low.

## 6. Parameter sweep (smoke)

Re-run a subset (random vectors, max saturation, reset) with at least one small `NUM_INPUTS` (e.g. 4 or 16) in addition to the target. Catches tree-depth bugs that only manifest at specific `NUM_STAGES`.
