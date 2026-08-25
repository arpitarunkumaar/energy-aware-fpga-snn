#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: run_saif.sh <label> <clock-period-ns>" >&2
    exit 2
fi

label=$1
period_ns=$2
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
run_root="$script_dir/run"
build_dir="$run_root/build/$label"
xsim_work="$run_root/xsim/$label"
activity_dir="$run_root/activity/$label"
vivado_bin=/opt/Xilinx/Vivado/2022.1/bin
netlist="$build_dir/collision_predictor_${label}_funcsim.v"
tb="$script_dir/tb/tb_l128_power.sv"
saif="$activity_dir/post_route_trained_image0.saif"

mkdir -p "$xsim_work" "$activity_dir"
cd "$xsim_work"

"$vivado_bin/xvlog" --nolog "$netlist"
"$vivado_bin/xvlog" --nolog --sv \
    -d "L128_CLOCK_PERIOD_NS=$period_ns" \
    -d "L128_L1_WEIGHTS_PATH=\"$script_dir/../common/data/model_params/layer1_weights.hex\"" \
    -d "L128_SPIKE_WORDS_PATH=\"$script_dir/../common/data/activity/spk_img000_128.hex\"" \
    "$tb"
"$vivado_bin/xelab" --log "$activity_dir/xelab.log" \
    --relax --mt 8 --debug typical \
    -L unisims_ver -L unimacro_ver -L secureip \
    --snapshot "tb_l128_power_$label" tb_l128_power glbl

export L128_SAIF_PATH="$saif"
"$vivado_bin/xsim" "tb_l128_power_$label" \
    --tclbatch "$script_dir/xsim_saif.tcl" \
    --log "$activity_dir/xsim_saif.log"

if ! grep -q 'L128_POWER_PASS' "$activity_dir/xsim_saif.log"; then
    echo "post-route power workload did not complete: $activity_dir/xsim_saif.log" >&2
    exit 1
fi

if ! grep -Eq '\(DURATION +[1-9][0-9]*\)' "$saif"; then
    echo "SAIF generation failed or recorded zero duration: $saif" >&2
    exit 1
fi

"$vivado_bin/vivado" -mode batch -nojournal -nolog \
    -source "$script_dir/power_saif.tcl" -tclargs "$label" "$saif" \
    >"$activity_dir/power_saif.log" 2>&1

echo "$saif"
