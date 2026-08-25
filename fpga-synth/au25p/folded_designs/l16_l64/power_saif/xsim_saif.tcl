open_saif $::env(SAIF_PATH)
log_saif [get_objects -r /tb_folded_bram_saif/dut/*]
run all
close_saif
quit
