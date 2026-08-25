# usage: vivado -mode batch -source lif_unit_io_power.tcl -tclargs <label> <saif_path>
if {[llength $argv] != 2} {
    error "usage: lif_unit_io_power.tcl <label> <saif_path>"
}

set label       [lindex $argv 0]
set saif_path   [file normalize [lindex $argv 1]]
set script_dir  [file dirname [file normalize [info script]]]
set run_root    [file normalize $script_dir/run]
set build_dir   [file normalize $run_root/build/$label]
set report_dir  [file normalize $run_root/reports/$label]

if {![file exists $saif_path]} {
    error "SAIF not found: $saif_path"
}
if {![file exists $build_dir/post_route.dcp]} {
    error "missing post-route checkpoint: $build_dir/post_route.dcp"
}

open_checkpoint $build_dir/post_route.dcp

report_power -verbose -file $report_dir/post_route_power_vectorless_typical.rpt
read_saif -verbose -strip_path tb_lif_unit_io_power/dut \
    -out_file $report_dir/post_route_saif_unmatched.rpt $saif_path

# Activity-based, typical process (primary number).
report_power -verbose -file $report_dir/post_route_power_saif_typical.rpt
report_power -hierarchical_depth 6 \
    -file $report_dir/post_route_power_saif_typical_hierarchical.rpt

# Same SAIF activity under maximum process corner.
set_operating_conditions -process maximum
report_power -verbose -file $report_dir/post_route_power_saif_maximum.rpt
set_operating_conditions -process typical

puts "LIF_UNIT_IO_POWER label=$label saif=$saif_path"
close_project
