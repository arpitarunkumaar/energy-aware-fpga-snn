open_saif $::env(SN_SAIF_PATH)
log_saif [get_objects -r /tb_single_neuron_power/dut/*]
run all
close_saif
quit
