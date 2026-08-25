"""Software golden models for each DUT."""

from typing import Sequence


def adder_sum(spikes: Sequence[int], weights: Sequence[int]) -> int:
    """cascaded_adder reference: signed Σ spike[i] * weight[i]."""
    return sum(int(s) * int(w) for s, w in zip(spikes, weights))


_MASK32 = (1 << 32) - 1
_MASK28 = (1 << 28) - 1


class LifModel:
    """Bit-exact reference for lif (lif_model.sv), stepped once per clk edge.

    Mirrors the RTL's unsigned arithmetic exactly: the membrane update
    `u - ((u - urest) >> k) + input_current` is evaluated at 32 bits (the
    integer parameters widen the expression) and truncated to 28 bits on
    assignment, so subtractions wrap instead of going negative. That wrap
    is intentional here — it reproduces what the hardware does when
    u < urest or the current overflows, so the model stays cycle-accurate
    for any parameter set and any stimulus.
    """

    def __init__(self, k: int = 5, uth: int = 100, urest: int = 0,
                 refractory_counter_max: int = 5):
        self.k = k
        self.uth = uth
        self.urest = urest
        self.rmax = refractory_counter_max
        self.u = 0      # internal_value
        self.ctr = 0    # refractory_counter
        self.spike = 0

    def step(self, input_current: int, enable: int = 1, rst: int = 0) -> int:
        """Advance one clock; returns the spike output for this cycle."""
        if not enable:
            self.spike = 0          # state held, spike forced low
            return self.spike
        if rst or self.ctr == self.rmax - 1:
            self.spike, self.ctr, self.u = 0, 0, 0
        elif self.u >= self.uth:
            self.spike, self.u, self.ctr = 1, 0, 1
        elif self.ctr != 0:
            self.spike = 0
            self.ctr = (self.ctr + 1) & 0xF   # 4-bit counter
        else:
            self.spike = 0
            leak = ((self.u - self.urest) & _MASK32) >> self.k
            self.u = (self.u - leak + input_current) & _MASK28
        return self.spike
