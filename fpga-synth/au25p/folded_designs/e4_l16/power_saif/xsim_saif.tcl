open_saif $::env(SAIF_PATH)
log_saif [get_objects -r /tb_parallel_lif_saif/dut/*]
run all
close_saif
quit
