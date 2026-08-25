# Dispatches cocotb runs to the per-DUT pytest runner. Usage:
#   make test  DUT=cascaded_adder
#   make test  DUT=lif_model
#   make test  DUT=sequential
#   make test  DUT=folded/e4_l16
#   make test  DUT=folded/l16_l64
#   make test  DUT=folded/l128
#   make waves DUT=cascaded_adder N=4096 CASE=random_vectors
#   make waves DUT=lif_model BUILD=sim_build_defaults CASE=random_stimulus
#   make clean DUT=cascaded_adder

ifndef DUT
$(error DUT not supplied. Usage: make <target> DUT=<module>)
endif

N ?= 4096
BUILD ?= sim_build_n$(N)

.PHONY: test waves clean

test:
	cd $(DUT) && pytest test_runner.py -v

waves:
	gtkwave $(DUT)/$(BUILD)/dump_$(CASE).vcd &

clean:
	rm -rf $(DUT)/sim_build* $(DUT)/*.xml $(DUT)/dump.vcd
