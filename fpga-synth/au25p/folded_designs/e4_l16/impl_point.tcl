if {[llength $argv] != 3} {
    error "usage: impl_point.tcl <num_engines> <period_ns> <label>"
}

set num_engines [lindex $argv 0]
set period      [lindex $argv 1]
set label       [lindex $argv 2]

set lanes       16
set stream_bits 64
set part        xcau25p-ffvb676-2-e
set top         folded_bram_predictor_parallel
set script_dir  [file dirname [file normalize [info script]]]
set origin      [file normalize $script_dir/../../..]
set run_root    [file normalize $script_dir/run]
set build_dir   [file normalize $run_root/build/$label]
set report_dir  [file normalize $run_root/reports/$label]

proc property_or_dash {object property_name} {
    if {[catch {set value [get_property $property_name $object]}]} {
        return "-"
    }
    if {$value eq ""} {
        return "-"
    }
    return $value
}

proc write_bram_inventory {path stage num_engines lanes} {
    set report [open $path w]
    set folds [expr {4096 / $lanes}]
    set row_width [expr {$lanes * 16}]
    set spike_words [expr {25 * $folds}]

    puts $report "Stage: $stage"
    puts $report "Logical shared spike memory: $spike_words x $lanes = [expr {$spike_words * $lanes}] bits"
    puts $report "Logical row memory per bank/engine: $folds x $row_width = [expr {$folds * $row_width}] bits"
    puts $report "Logical ping-pong row storage: $num_engines engines x 2 banks x [expr {$folds * $row_width}] bits"
    puts $report "Note: physical RAM count and port widths below are authoritative after synthesis."
    puts $report ""

    set cells [lsort [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]]
    set tiles 0.0
    foreach cell $cells {
        set ref [property_or_dash $cell REF_NAME]
        if {[string match "RAMB36*" $ref]} {
            set tiles [expr {$tiles + 1.0}]
        } elseif {[string match "RAMB18*" $ref]} {
            set tiles [expr {$tiles + 0.5}]
        }
    }

    puts $report "Primitive count: [llength $cells]"
    puts $report "Equivalent BRAM36 tiles: $tiles"
    puts $report ""
    puts $report [format "%-112s %-12s %-8s %-8s %-8s %-8s %-10s %-10s %-12s %-14s" \
        "cell" "primitive" "RWA" "RWB" "WWA" "WWB" "DOA_REG" "DOB_REG" "RAM_MODE" "LOC"]

    foreach cell $cells {
        puts $report [format "%-112s %-12s %-8s %-8s %-8s %-8s %-10s %-10s %-12s %-14s" \
            $cell \
            [property_or_dash $cell REF_NAME] \
            [property_or_dash $cell READ_WIDTH_A] \
            [property_or_dash $cell READ_WIDTH_B] \
            [property_or_dash $cell WRITE_WIDTH_A] \
            [property_or_dash $cell WRITE_WIDTH_B] \
            [property_or_dash $cell DOA_REG] \
            [property_or_dash $cell DOB_REG] \
            [property_or_dash $cell RAM_MODE] \
            [property_or_dash $cell LOC]]
    }
    close $report
}

proc write_bram_properties {path stage} {
    set report [open $path w]
    puts $report "Stage: $stage"
    set properties [list \
        REF_NAME PRIMITIVE_TYPE LOC BEL RAM_MODE \
        READ_WIDTH_A READ_WIDTH_B WRITE_WIDTH_A WRITE_WIDTH_B \
        DOA_REG DOB_REG WRITE_MODE_A WRITE_MODE_B \
        EN_ECC_READ EN_ECC_WRITE CASCADE_ORDER_A CASCADE_ORDER_B]

    foreach cell [lsort [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]] {
        puts $report ""
        puts $report "CELL $cell"
        foreach property_name $properties {
            puts $report [format "  %-22s %s" $property_name \
                [property_or_dash $cell $property_name]]
        }
    }
    close $report
}

file mkdir $build_dir
file mkdir $report_dir

create_project -force parallel_lif_${label} $build_dir -part $part
set_property target_language Verilog [current_project]
set rtl_dir [file normalize $origin/rtl/folded]
add_files -norecurse [list \
    $rtl_dir/common/cascaded_adder_synth.sv \
    $rtl_dir/common/lif_model.sv \
    $rtl_dir/e4_l16/folded_bram_predictor_parallel.sv]
set_property file_type SystemVerilog [get_files *.sv]
set_property top $top [get_filesets sources_1]

set model_dir $script_dir/../common/data/model_params
set_property generic [list \
    LANES=$lanes \
    NUM_ENGINES=$num_engines \
    WEIGHT_STREAM_WIDTH=$stream_bits \
    LAYER2_WEIGHTS_PATH="$model_dir/layer2_weights.hex" \
    LAYER1_BIASES_PATH="$model_dir/layer1_biases.hex" \
    LAYER2_BIASES_PATH="$model_dir/layer2_biases.hex"] [get_filesets sources_1]

# Core-only (out-of-context) clock constraint. Board I/O, DDR, and CDC
# timing are outside this experiment.
set xdc_path $build_dir/parallel_lif_ooc.xdc
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
report_utilization -hierarchical -hierarchical_depth 8 \
    -file $report_dir/post_synth_utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_synth_timing.rpt
write_bram_inventory $report_dir/post_synth_bram_widths.rpt post_synth $num_engines $lanes
write_bram_properties $report_dir/post_synth_bram_properties.rpt post_synth

opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
write_checkpoint -force $build_dir/post_route.dcp

report_utilization -file $report_dir/post_route_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 8 \
    -file $report_dir/post_route_utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 100 -file $report_dir/post_route_timing.rpt
report_timing -delay_type max -max_paths 100 -nworst 1 \
    -file $report_dir/post_route_worst_setup.rpt
report_timing -delay_type min -max_paths 100 -nworst 1 \
    -file $report_dir/post_route_worst_hold.rpt
report_route_status -file $report_dir/post_route_status.rpt
report_drc -ruledeck default -file $report_dir/post_route_drc.rpt
catch {report_methodology -file $report_dir/post_route_methodology.rpt}
catch {report_ram_utilization -file $report_dir/post_route_ram_utilization.rpt}
report_power -file $report_dir/post_route_power_vectorless.rpt
write_bram_inventory $report_dir/post_route_bram_widths.rpt post_route $num_engines $lanes
write_bram_properties $report_dir/post_route_bram_properties.rpt post_route

set setup_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
set hold_paths  [get_timing_paths -quiet -delay_type min -max_paths 1]
set wns "NA"
set whs "NA"
set timing_met "unknown"
set critical_period "NA"
set local_fmax "NA"

if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
}
if {$wns ne "NA" && $whs ne "NA"} {
    set timing_met [expr {$wns >= 0.0 && $whs >= 0.0}]
    set critical_period [expr {$period - $wns}]
    if {$critical_period > 0.0} {
        set local_fmax [expr {1000.0 / $critical_period}]
    }
}

set ram_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]
set lut_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]
set ff_cells  [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]
set dsp_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP*}]
set bram_tiles 0.0
foreach cell $ram_cells {
    set ref [get_property REF_NAME $cell]
    if {[string match "RAMB36*" $ref]} {
        set bram_tiles [expr {$bram_tiles + 1.0}]
    } elseif {[string match "RAMB18*" $ref]} {
        set bram_tiles [expr {$bram_tiles + 0.5}]
    }
}

set summary [open $report_dir/flow_summary.txt w]
puts $summary "Label: $label"
puts $summary "Part: $part"
puts $summary "Top: $top"
puts $summary "LANES: $lanes"
puts $summary "NUM_ENGINES: $num_engines"
puts $summary "Weight stream width: $stream_bits"
puts $summary "Requested period (ns): $period"
puts $summary "Requested frequency (MHz): [expr {1000.0 / $period}]"
puts $summary "Clock uncertainty (ns): 0.200"
puts $summary "Post-route setup WNS (ns): $wns"
puts $summary "Post-route hold WHS (ns): $whs"
puts $summary "Post-route timing met: $timing_met"
puts $summary "Local critical period (ns): $critical_period"
puts $summary "Local routed Fmax estimate (MHz): $local_fmax"
puts $summary "LUT primitives: [llength $lut_cells]"
puts $summary "FF primitives: [llength $ff_cells]"
puts $summary "DSP primitives: [llength $dsp_cells]"
puts $summary "Physical RAM primitives: [llength $ram_cells]"
puts $summary "Equivalent BRAM36 tiles: $bram_tiles"
puts $summary "External L1 bytes/image: 4194304"
puts $summary "Synaptic interactions/image: 52454400"
close $summary

puts "PARALLEL_LIF_POINT label=$label engines=$num_engines lanes=$lanes period_ns=$period wns_ns=$wns whs_ns=$whs timing_met=$timing_met bram36_tiles=$bram_tiles local_fmax_mhz=$local_fmax"
close_project
