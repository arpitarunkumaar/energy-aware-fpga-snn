#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
vivado=${VIVADO:-/opt/Xilinx/Vivado/2022.1/bin/vivado}

"$vivado" -mode batch -nojournal -nolog \
  -source "$script_dir/e4_l16/impl_point.tcl" \
  -tclargs 4 6.250 engines4_lanes16_160mhz_pipelined_fallback
"$vivado" -mode batch -nojournal -nolog \
  -source "$script_dir/l16_l64/impl_point.tcl" \
  -tclargs 16 2 5.714 lanes16_rb2_175mhz_signoff
"$vivado" -mode batch -nojournal -nolog \
  -source "$script_dir/l16_l64/impl_point.tcl" \
  -tclargs 64 2 8.000 lanes64_rb2_125mhz
"$vivado" -mode batch -nojournal -nolog \
  -source "$script_dir/l128/impl_point.tcl" \
  -tclargs 4.000 250mhz

