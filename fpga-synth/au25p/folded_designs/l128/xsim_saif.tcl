open_saif $::env(L128_SAIF_PATH)
log_saif [get_objects -r /dut/*]
run all
close_saif
quit
