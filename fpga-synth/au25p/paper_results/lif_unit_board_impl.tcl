# LIF board top: BUFG, registered I/O, and SAIF-ready funcsim.
# usage: vivado -mode batch -source lif_unit_board_impl.tcl -tclargs <period_ns> <label>
if {[llength $argv] != 2} {
    error "usage: lif_unit_board_impl.tcl <period_ns> <label>"
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
set top         lif_unit_board_top

file mkdir $build_dir
file mkdir $report_dir
file mkdir $sim_dir

create_project -force $label $build_dir -part $part
set_property target_language Verilog [current_project]
set rtl_dir [file normalize $origin/rtl/paper]
add_files -norecurse [list \
    $rtl_dir/lif_model.sv \
    $rtl_dir/lif_unit_board_top.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top $top [get_filesets sources_1]

set xdc_path $build_dir/lif_unit_board.xdc
set xdc [open $xdc_path w]
puts $xdc "create_clock -period $period -name clk_in \[get_ports clk_in\]"
puts $xdc "set_clock_uncertainty 0.200 \[get_clocks clk_in\]"
puts $xdc "set_property IOSTANDARD LVCMOS18 \[get_ports *\]"
# Modest board-facing I/O delays; datapath is registered at the boundary.
puts $xdc "set_input_delay  -clock \[get_clocks clk_in\] -max 2.0 \[get_ports {rst enable new_image input_current[*]}\]"
puts $xdc "set_input_delay  -clock \[get_clocks clk_in\] -min 0.0 \[get_ports {rst enable new_image input_current[*]}\]"
puts $xdc "set_output_delay -clock \[get_clocks clk_in\] -max 2.0 \[get_ports spike\]"
puts $xdc "set_output_delay -clock \[get_clocks clk_in\] -min 0.0 \[get_ports spike\]"
close $xdc
add_files -fileset constrs_1 -norecurse $xdc_path
update_compile_order -fileset sources_1

set_param general.maxThreads 8

# Includes I/O and global clocking (not out_of_context).
synth_design -top $top -part $part -flatten_hierarchy rebuilt
report_utilization -file $report_dir/post_synth_utilization.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -max_paths 20 -file $report_dir/post_synth_timing.rpt

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
write_checkpoint -force $build_dir/post_route.dcp

report_utilization -file $report_dir/post_route_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 5 \
    -file $report_dir/post_route_utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 50 -file $report_dir/post_route_timing.rpt
report_route_status -file $report_dir/post_route_status.rpt
report_drc -file $report_dir/post_route_drc.rpt
report_io -file $report_dir/post_route_io.rpt
report_clock_utilization -file $report_dir/post_route_clock_utilization.rpt
report_power -verbose -file $report_dir/post_route_power_vectorless.rpt

set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
set freq_mhz [expr {1000.0 / $period}]
set timing_met [expr {$wns >= 0.0 && $whs >= 0.0}]
set luts [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]]
set ffs  [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]]
set bufgs [llength [get_cells -quiet -hierarchical -filter {REF_NAME =~ BUFG*}]]

set summary [open $report_dir/fresh_flow_summary.txt w]
puts $summary "Run label: $label"
puts $summary "Part: $part"
puts $summary "Top: $top (LIF + BUFG + registered I/O; not out_of_context)"
puts $summary "Requested period (ns): $period (${freq_mhz} MHz)"
puts $summary "Clock uncertainty (ns): 0.200"
puts $summary "IOSTANDARD: LVCMOS18; input/output delay max 2.0 ns"
puts $summary "Post-route setup WNS (ns): $wns"
puts $summary "Post-route hold WHS (ns): $whs"
puts $summary "Post-route timing met: $timing_met"
puts $summary "LUT primitives: $luts"
puts $summary "FF primitives: $ffs"
puts $summary "BUFG primitives: $bufgs"
close $summary

write_verilog -force -mode funcsim \
    $sim_dir/${top}_${label}_funcsim.v

puts "LIF_BOARD label=$label period_ns=$period wns_ns=$wns whs_ns=$whs timing_met=$timing_met luts=$luts ffs=$ffs bufgs=$bufgs"
close_project
