if {[llength $argv] != 2} {
    error "usage: single_neuron_impl.tcl <period_ns> <label>"
}

set period      [lindex $argv 0]
set label       [lindex $argv 1]
set script_dir  [file dirname [file normalize [info script]]]
set origin      [file normalize $script_dir/../../..]
set run_root    [file normalize $script_dir/run]
set build_dir   [file normalize $run_root/build/$label]
set report_dir  [file normalize $run_root/reports/$label]
set sim_dir     [file normalize $run_root/sim/$label]
set part        xcau25p-ffvb676-2-e
set top         parallel512_weight_partition_ooc

file mkdir $build_dir
file mkdir $report_dir
file mkdir $sim_dir


create_project -force single_neuron_${label} $build_dir -part $part
set_property target_language Verilog [current_project]
set rtl_dir [file normalize $origin/rtl/paper]
add_files -norecurse [list \
    $rtl_dir/cascaded_adder.sv \
    $rtl_dir/lif_model.sv \
    $rtl_dir/parallel512_weight_partition_ooc.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top $top [get_filesets sources_1]

set weight_file [file normalize $script_dir/layer1_weights_row000.hex]
set bias_file   [file normalize $origin/data/layer1_biases.hex]
set_property generic [list \
    BLOCK_NEURONS=1 \
    BLOCK_BASE=0 \
    WEIGHT_FILE="$weight_file" \
    BIAS_FILE="$bias_file"] [get_filesets sources_1]

set xdc_path $build_dir/single_neuron_ooc.xdc
set xdc [open $xdc_path w]
puts $xdc "create_clock -period $period -name clk \[get_ports clk\]"
puts $xdc "set_clock_uncertainty 0.200 \[get_clocks clk\]"
puts $xdc "set_property HD.CLK_SRC BUFGCE_X0Y0 \[get_ports clk\]"
close $xdc
add_files -fileset constrs_1 -norecurse $xdc_path
update_compile_order -fileset sources_1

set_param general.maxThreads 8

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
write_checkpoint -force $build_dir/post_synth.dcp
report_utilization -file $report_dir/post_synth_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_synth_timing.rpt

opt_design -directive Explore
write_checkpoint -force $build_dir/post_opt.dcp
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_opt_timing.rpt

place_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $build_dir/post_place.dcp
report_utilization -file $report_dir/post_place_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_place_timing.rpt

route_design -directive Explore
write_checkpoint -force $build_dir/post_route.dcp

report_utilization -file $report_dir/post_route_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 6 \
    -file $report_dir/post_route_utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_route_timing.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -file $report_dir/post_route_worst_setup.rpt
report_timing -delay_type min -max_paths 100 -nworst 1 \
    -file $report_dir/post_route_worst_hold.rpt
report_route_status -file $report_dir/post_route_status.rpt
report_clock_utilization -file $report_dir/post_route_clock_utilization.rpt
report_drc -file $report_dir/post_route_drc.rpt
catch {report_qor_assessment -file $report_dir/post_route_qor_assessment.rpt}

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set critical_period [expr {$period - $wns}]
set local_fmax [expr {1000.0 / $critical_period}]
set timing_met [expr {$wns >= 0.0 && $whs >= 0.0}]
set freq_mhz [expr {1000.0 / $period}]
# Peak op rate: 4096 adds/cycle x 2 ops per MAC-equivalent.
set peak_gops [expr {4096.0 * 2.0 * $freq_mhz / 1000.0}]
set fmax_peak_gops [expr {4096.0 * 2.0 * $local_fmax / 1000.0}]

set summary [open $report_dir/fresh_flow_summary.txt w]
puts $summary "Run label: $label"
puts $summary "Part: $part"
puts $summary "Top: $top (BLOCK_NEURONS=1, real row-0 weights)"
puts $summary "Flow: synth_design(OOC), opt_design, place_design, phys_opt_design, route_design"
puts $summary "Requested period (ns): $period"
puts $summary "Requested frequency (MHz): $freq_mhz"
puts $summary "Clock uncertainty (ns): 0.200"
puts $summary "Assumed parent-shell clock source: BUFGCE_X0Y0"
puts $summary "Post-route setup WNS (ns): $wns"
puts $summary "Post-route hold WHS (ns): $whs"
puts $summary "Post-route timing met: $timing_met"
puts $summary "Local critical-period estimate (period-WNS, ns): $critical_period"
puts $summary "Local routed Fmax estimate (MHz): $local_fmax"
puts $summary "Paper-style peak GOPS at requested clock (4096 adds x 2 ops): $peak_gops"
puts $summary "Paper-style peak GOPS at local Fmax estimate: $fmax_peak_gops"
close $summary

write_verilog -force -mode funcsim \
    $sim_dir/${top}_${label}_funcsim.v

puts "SINGLE_NEURON label=$label period_ns=$period wns_ns=$wns whs_ns=$whs timing_met=$timing_met local_fmax_mhz=$local_fmax peak_gops=$peak_gops"
close_project
