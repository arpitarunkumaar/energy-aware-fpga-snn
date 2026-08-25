#!/usr/bin/env bash
# LIF with BUFG and registered I/O at the retained 100 MHz point.
set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
console_dir="$script_dir/run/console"
vivado=${VIVADO:-/opt/Xilinx/Vivado/2022.1/bin/vivado}
mkdir -p "$console_dir"

stamp() { date -Is; }

run_label() {
    local label=$1 period=$2
    echo "$(stamp) [$label] impl start (period ${period} ns, board/non-OOC)"
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/lif_unit_board_impl.tcl" \
        -tclargs "$period" "$label" \
        > "$console_dir/impl_${label}.log" 2>&1
    local rc=$?
    echo "$(stamp) [$label] impl exit=$rc"
    if (( rc != 0 )); then
        echo "$(stamp) [$label] FAILED impl; see $console_dir/impl_${label}.log"
        return $rc
    fi

    echo "$(stamp) [$label] SAIF start"
    "$script_dir/run_lif_board_saif.sh" "$label" "$period" \
        > "$console_dir/saif_${label}.log" 2>&1
    rc=$?
    echo "$(stamp) [$label] SAIF exit=$rc"
    if (( rc != 0 )); then
        echo "$(stamp) [$label] FAILED SAIF; see $console_dir/saif_${label}.log"
        return $rc
    fi

    echo "$(stamp) [$label] power start"
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/lif_unit_board_power.tcl" \
        -tclargs "$label" "$script_dir/run/activity/$label/post_route_fully_fed.saif" \
        > "$console_dir/power_${label}.log" 2>&1
    rc=$?
    echo "$(stamp) [$label] power exit=$rc"
    return $rc
}

overall=0
echo "$(stamp) LIF_BOARD_START"
run_label lif_board_100mhz 10.0   || overall=1
echo "$(stamp) LIF_BOARD_DONE overall=$overall"

if (( overall == 0 )); then
    for label in lif_board_100mhz; do
        echo "== $label =="
        cat "$script_dir/run/reports/$label/fresh_flow_summary.txt"
        echo "-- SAIF power --"
        rg -n "Total On-Chip Power|Dynamic \(W\)|Device Static|Clocks|CLB Logic|Register|Signals|I/O |Confidence Level|Design nets matched" \
            "$script_dir/run/reports/$label/post_route_power_saif.rpt" || true
        echo
    done
fi
exit $overall
