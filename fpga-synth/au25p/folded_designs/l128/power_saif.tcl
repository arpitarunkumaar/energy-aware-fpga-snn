if {[llength $argv] != 2} {
    error "usage: power_saif.tcl <label> <saif_path>"
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

open_checkpoint $build_dir/post_route.dcp
read_saif -verbose -strip_path tb_l128_power/dut \
    -out_file $report_dir/post_route_saif_unmatched.rpt $saif_path
report_power -verbose -file $report_dir/post_route_power_saif.rpt
report_power -hierarchical_depth 8 \
    -file $report_dir/post_route_power_saif_hierarchical.rpt
puts "L128_POWER label=$label saif=$saif_path"
close_project
