#!/usr/bin/env bash
# LIF with BUFG and package I/O (not out-of-context) at the retained 100 MHz point.
set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
console_dir="$script_dir/run/console"
vivado=${VIVADO:-/opt/Xilinx/Vivado/2022.1/bin/vivado}
mkdir -p "$console_dir"

stamp() { date -Is; }

run_label() {
    local label=$1 period=$2
    echo "$(stamp) [$label] impl start (period ${period} ns, BUFG+IO)"
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/lif_unit_io_impl.tcl" \
        -tclargs "$period" "$label" \
        > "$console_dir/impl_${label}.log" 2>&1
    local rc=$?
    echo "$(stamp) [$label] impl exit=$rc"
    if (( rc != 0 )); then
        echo "$(stamp) [$label] impl FAILED; see $console_dir/impl_${label}.log"
        return $rc
    fi

    echo "$(stamp) [$label] xsim SAIF start"
    "$script_dir/run_lif_io_saif.sh" "$label" "$period" \
        > "$console_dir/saif_${label}.log" 2>&1
    rc=$?
    echo "$(stamp) [$label] xsim SAIF exit=$rc"
    if (( rc != 0 )); then
        echo "$(stamp) [$label] SAIF FAILED; see $console_dir/saif_${label}.log"
        return $rc
    fi

    echo "$(stamp) [$label] SAIF power start"
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/lif_unit_io_power.tcl" \
        -tclargs "$label" "$script_dir/run/activity/$label/post_route_fully_fed.saif" \
        > "$console_dir/power_${label}.log" 2>&1
    rc=$?
    echo "$(stamp) [$label] SAIF power exit=$rc"
    if (( rc != 0 )); then
        echo "$(stamp) [$label] power FAILED; see $console_dir/power_${label}.log"
    fi
    return $rc
}

overall=0
echo "$(stamp) LIF_IO_POWER_START"
run_label lif_io_100mhz 10.0    || overall=1

echo "$(stamp) LIF_IO_POWER_DONE overall=$overall"
if (( overall == 0 )); then
    echo "---- summaries ----"
    for label in lif_io_100mhz; do
        echo "== $label =="
        sed -n '1,30p' "$script_dir/run/reports/$label/fresh_flow_summary.txt" 2>/dev/null || true
        echo "-- SAIF typical --"
        rg -n "Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level|I/O|Clocks|CLB Logic|Registers|Design nets matched" \
            "$script_dir/run/reports/$label/post_route_power_saif_typical.rpt" 2>/dev/null || true
        echo "-- SAIF maximum --"
        rg -n "Total On-Chip Power|Dynamic \(W\)|Device Static" \
            "$script_dir/run/reports/$label/post_route_power_saif_maximum.rpt" 2>/dev/null || true
        echo
    done
fi
exit $overall
