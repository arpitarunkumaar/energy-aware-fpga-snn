if {[llength $argv] != 4} {
    error "usage: impl_point.tcl <lanes> <row_buffers> <period_ns> <label>"
}

set lanes       [lindex $argv 0]
set row_buffers [lindex $argv 1]
set period      [lindex $argv 2]
set label       [lindex $argv 3]
set script_dir  [file dirname [file normalize [info script]]]
set origin      [file normalize $script_dir/../../..]
set run_root    [file normalize $script_dir/run]
set build_dir   [file normalize $run_root/build/$label]
set report_dir  [file normalize $run_root/reports/$label]
set part        xcau25p-ffvb676-2-e
set top         folded_bram_predictor

file mkdir $build_dir
file mkdir $report_dir
create_project -force folded_bram_${label} $build_dir -part $part
set_property target_language Verilog [current_project]
set rtl_dir [file normalize $origin/rtl/folded]
add_files -norecurse [list \
    $rtl_dir/common/cascaded_adder_synth.sv \
    $rtl_dir/common/lif_model.sv \
    $rtl_dir/l16_l64/folded_bram_predictor.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top $top [get_filesets sources_1]

set model_dir $script_dir/../common/data/model_params
set_property generic [list \
    LANES=$lanes \
    ROW_BUFFERS=$row_buffers \
    WEIGHT_STREAM_WIDTH=64 \
    LAYER2_WEIGHTS_PATH="$model_dir/layer2_weights.hex" \
    LAYER1_BIASES_PATH="$model_dir/layer1_biases.hex" \
    LAYER2_BIASES_PATH="$model_dir/layer2_biases.hex"] [get_filesets sources_1]

set xdc_path $build_dir/folded_bram_ooc.xdc
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
report_utilization -hierarchical -hierarchical_depth 6 \
    -file $report_dir/post_synth_utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_synth_timing.rpt

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
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
report_drc -file $report_dir/post_route_drc.rpt
catch {report_ram_utilization -file $report_dir/post_route_ram_utilization.rpt}
report_power -file $report_dir/post_route_power_vectorless.rpt

set mem [open $report_dir/inferred_memory_primitives.rpt w]
puts $mem "Part: $part"
puts $mem "LANES: $lanes"
puts $mem "ROW_BUFFERS: $row_buffers"
puts $mem "Logical row buffer: [expr {4096/$lanes}] x [expr {$lanes*16}] bits = 65536 bits each"
puts $mem "Logical spike memory: [expr {25*4096/$lanes}] x $lanes bits = 102400 bits"
puts $mem ""
puts $mem [format "%-100s %-10s %-6s %-6s %-6s %-6s" \
    "cell" "primitive" "RWA" "RWB" "WWA" "WWB"]
foreach cell [lsort [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]] {
    set ref [get_property REF_NAME $cell]
    foreach prop {READ_WIDTH_A READ_WIDTH_B WRITE_WIDTH_A WRITE_WIDTH_B} {
        if {[catch {set $prop [get_property $prop $cell]}]} {set $prop "-"}
    }
    puts $mem [format "%-100s %-10s %-6s %-6s %-6s %-6s" \
        $cell $ref $READ_WIDTH_A $READ_WIDTH_B $WRITE_WIDTH_A $WRITE_WIDTH_B]
}
close $mem

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set critical_period [expr {$period - $wns}]
set local_fmax [expr {1000.0 / $critical_period}]
set timing_met [expr {$wns >= 0.0 && $whs >= 0.0}]

set summary [open $report_dir/flow_summary.txt w]
puts $summary "Label: $label"
puts $summary "Part: $part"
puts $summary "Top: $top"
puts $summary "LANES: $lanes"
puts $summary "ROW_BUFFERS: $row_buffers"
puts $summary "Weight stream width: 64"
puts $summary "Requested period (ns): $period"
puts $summary "Requested frequency (MHz): [expr {1000.0/$period}]"
puts $summary "Clock uncertainty (ns): 0.200"
puts $summary "Post-route setup WNS (ns): $wns"
puts $summary "Post-route hold WHS (ns): $whs"
puts $summary "Post-route timing met: $timing_met"
puts $summary "Local critical period (ns): $critical_period"
puts $summary "Local routed Fmax estimate (MHz): $local_fmax"
puts $summary "External L1 bytes/image: 4194304"
puts $summary "Synaptic interactions/image: 52454400"
close $summary

puts "FOLDED_BRAM_POINT label=$label lanes=$lanes buffers=$row_buffers period_ns=$period wns_ns=$wns whs_ns=$whs timing_met=$timing_met local_fmax_mhz=$local_fmax"
close_project
