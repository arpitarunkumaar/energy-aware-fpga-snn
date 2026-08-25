if {[llength $argv] != 4} {
    error "usage: report_power.tcl <checkpoint> <saif> <report_dir> <strip_path>"
}
set checkpoint [file normalize [lindex $argv 0]]
set saif [file normalize [lindex $argv 1]]
set report_dir [file normalize [lindex $argv 2]]
set strip_path [lindex $argv 3]
file mkdir $report_dir
open_checkpoint $checkpoint
read_saif -verbose -strip_path $strip_path \
    -out_file $report_dir/post_route_saif_unmatched.rpt $saif
report_power -verbose -file $report_dir/post_route_power_saif.rpt
report_power -hierarchical_depth 8 \
    -file $report_dir/post_route_power_saif_hierarchical.rpt
catch {
    report_switching_activity -file $report_dir/post_route_switching_activity.rpt \
        [get_nets -hierarchical]
}
close_project
