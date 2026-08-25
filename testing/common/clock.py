"""Shared clock and reset helpers for cocotb tests."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


_clock_task = None


def start_clock(dut, period_ns: int = 10) -> None:
    """Spawn a free-running clock on dut.clk. Idempotent across tests in the same sim."""
    global _clock_task
    if _clock_task is None:
        _clock_task = cocotb.start_soon(Clock(dut.clk, period_ns, units="ns").start())


async def reset(dut, cycles: int = 2) -> None:
    """Hold rst_n low for `cycles` rising edges, then release."""
    dut.rst_n.value = 0
    dut.valid_in.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
