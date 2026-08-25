#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: run_saif.sh <label> <clock-period-ns>" >&2
    exit 2
fi

label=$1
period_ns=$2
script_dir=$(cd "$(dirname "$0")" && pwd)
run_root="$script_dir/run"
sim_export="$run_root/sim/$label"
xsim_work="$run_root/xsim/$label"
activity_dir="$run_root/activity/$label"
vivado_bin=${VIVADO_BIN_DIR:-/opt/Xilinx/Vivado/2022.1/bin}
netlist="$sim_export/parallel512_weight_partition_ooc_${label}_funcsim.v"
tb="$script_dir/tb/tb_single_neuron_power.sv"
activity_hex="$script_dir/activity/activity_images.hex"
saif="$activity_dir/post_route_fully_fed.saif"

if [[ ! -f "$activity_hex" ]]; then
    echo "missing activity stimulus: $activity_hex" >&2
    exit 2
fi
if [[ ! -f "$netlist" ]]; then
    echo "missing funcsim netlist: $netlist" >&2
    exit 2
fi

mkdir -p "$xsim_work" "$activity_dir"
cd "$xsim_work"

"$vivado_bin/xvlog" --nolog "$netlist"
"$vivado_bin/xvlog" --nolog --sv \
    -d "CLK_PERIOD_NS=$period_ns" \
    -d "ACTIVITY_PATH=\"$activity_hex\"" \
    "$tb"
"$vivado_bin/xelab" --log "$activity_dir/xelab.log" \
    --relax --mt 8 --debug typical \
    -L unisims_ver -L unimacro_ver -L secureip \
    --snapshot "tb_single_neuron_power_$label" tb_single_neuron_power glbl

export SN_SAIF_PATH="$saif"
"$vivado_bin/xsim" "tb_single_neuron_power_$label" \
    --tclbatch "$script_dir/xsim_saif.tcl" \
    --log "$activity_dir/xsim_saif.log"

if ! grep -Eq '\(DURATION +[1-9][0-9]*\)' "$saif"; then
    echo "SAIF generation failed or recorded zero duration: $saif" >&2
    exit 1
fi

# Quick activity sanity: require substantial toggle count
python3 - "$saif" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
nonzero = 0
for line in p.open():
    m = re.search(r'\(TC\s+(\d+)\)', line)
    if m and int(m.group(1)) > 0:
        nonzero += 1
print(f'SAIF_SANITY nonzero_TC_nets={nonzero}')
if nonzero < 1000:
    raise SystemExit(f'SAIF looks idle (nonzero TC nets={nonzero}); refusing')
PY

echo "$saif"
