open_saif $::env(SN_SAIF_PATH)
log_saif [get_objects -r /tb_lif_unit_board_power/dut/*]
run all
close_saif
quit
