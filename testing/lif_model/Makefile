SIM      = verilator --binary -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --prefix sim

SRC = lif_model_legacy.sv
TB  = lif_model_tb.sv

OUT      = sim.out

all: run

build:
	$(SIM) $(SIMFLAGS) $(SRC) $(TB)

run: build
	./obj_dir/sim

wave: run
	gtkwave lif_model_tb.vcd

clean:
	rm -rf $(OUT) *.vcd obj_dir
