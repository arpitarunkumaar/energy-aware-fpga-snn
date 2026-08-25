#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: run_point.sh <label> <num-engines> <clock-period-ns>" >&2
    exit 2
fi

label=$1
engines=$2
period_ns=$3
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../../../.." && pwd)
vivado_bin=/opt/Xilinx/Vivado/2022.1/bin
checkpoint="$script_dir/../run/build/$label/post_route.dcp"
run_dir="$script_dir/run/$label"
report_dir="$script_dir/../run/reports/$label"
netlist="$run_dir/folded_bram_predictor_parallel_funcsim.v"
saif="$run_dir/full_inference.saif"

mkdir -p "$run_dir" "$report_dir"
test -f "$checkpoint"

"$vivado_bin/vivado" -mode batch -nolog -nojournal \
    -source "$script_dir/export_funcsim.tcl" \
    -tclargs "$checkpoint" "$netlist" \
    >"$run_dir/export.log" 2>&1

cd "$run_dir"
"$vivado_bin/xvlog" --nolog "$netlist" >xvlog_netlist.log 2>&1
"$vivado_bin/xvlog" --nolog --sv \
    -d "CLK_PERIOD_NS=$period_ns" \
    -d "NUM_ENGINES=$engines" \
    -d "L1_WEIGHTS_PATH=\"$script_dir/../../common/data/model_params/layer1_weights.hex\"" \
    -d "SPIKE_ACTIVITY_PATH=\"$script_dir/../../common/data/activity/activity_images.hex\"" \
    "$script_dir/tb_parallel_lif_saif.sv" >xvlog_tb.log 2>&1
"$vivado_bin/xelab" --nolog --relax --mt 8 --debug typical \
    -L unisims_ver -L unimacro_ver -L secureip \
    --snapshot "tb_saif_$label" tb_parallel_lif_saif glbl \
    >xelab.log 2>&1
export SAIF_PATH="$saif"
"$vivado_bin/xsim" "tb_saif_$label" --nolog \
    --tclbatch "$script_dir/xsim_saif.tcl" >xsim.log 2>&1
grep -Eq '\(DURATION +[1-9][0-9]*\)' "$saif"
grep -q 'SAIF_WORKLOAD_PASS' xsim.log

"$vivado_bin/vivado" -mode batch -nolog -nojournal \
    -source "$script_dir/report_power.tcl" \
    -tclargs "$checkpoint" "$saif" "$report_dir" \
    tb_parallel_lif_saif/dut >power.log 2>&1

echo "SAIF_POINT_PASS label=$label engines=$engines period_ns=$period_ns"
