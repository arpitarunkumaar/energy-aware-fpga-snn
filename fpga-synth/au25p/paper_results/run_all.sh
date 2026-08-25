#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
vivado=${VIVADO:-/opt/Xilinx/Vivado/2022.1/bin/vivado}

run_tree() {
    local label=$1 period=$2
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/single_neuron_impl.tcl" \
        -tclargs "$period" "$label"
    "$script_dir/run_saif.sh" "$label" "$period"
    "$vivado" -mode batch -nojournal -nolog \
        -source "$script_dir/single_neuron_power.tcl" \
        -tclargs "$label" \
        "$script_dir/run/activity/$label/post_route_fully_fed.saif"
}

run_tree 67mhz 14.925
run_tree 280mhz 3.571
"$script_dir/run_lif_io_power.sh"
"$script_dir/run_lif_board.sh"

