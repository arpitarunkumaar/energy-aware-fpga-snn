if {[llength $argv] != 2} {
    error "usage: export_funcsim.tcl <checkpoint> <netlist>"
}
open_checkpoint [file normalize [lindex $argv 0]]
write_verilog -force -mode funcsim [file normalize [lindex $argv 1]]
close_project
