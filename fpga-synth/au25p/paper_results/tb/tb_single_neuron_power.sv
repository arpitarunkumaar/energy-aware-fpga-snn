`timescale 1ns/1ps

`ifndef CLK_PERIOD_NS
`define CLK_PERIOD_NS 10.0
`endif
`ifndef ACTIVITY_PATH
`define ACTIVITY_PATH "activity_images.hex"
`endif

// Drives one 4096-input adder plus one LIF fully fed: a fresh spike vector
// every cycle, so the captured SAIF matches peak-GOPS activity.
module tb_single_neuron_power;
    localparam real PERIOD_NS   = `CLK_PERIOD_NS;
    localparam int  NUM_INPUTS  = 4096;
    localparam int  TIME_STEPS  = 25;
    localparam int  NUM_VECTORS = 400;   // 16 images x 25 time steps
    localparam int  NUM_PASSES  = 10;
    // Adder valid latency (13) + input_current register (1): the step-0 data
    // reaches the LIF this many cycles after it enters the tree.
    localparam int  LIF_MARKER_DELAY = 14;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic valid_in = 1'b0;
    logic [NUM_INPUTS-1:0] spikes = '0;
    logic step0 = 1'b0;

    wire  [0:0]  valid_out;
    wire  [0:0]  lif_spikes;
    wire  [27:0] neuron_currents;

    logic [NUM_INPUTS-1:0] stimulus [0:NUM_VECTORS-1];
    logic [LIF_MARKER_DELAY-1:0] marker_pipe = '0;
    wire  lif_new_image = marker_pipe[LIF_MARKER_DELAY-1];

    parallel512_weight_partition_ooc dut (
        .clk(clk),
        .rst(rst),
        .valid_in(valid_in),
        .lif_new_image(lif_new_image),
        .spikes(spikes),
        .valid_out(valid_out),
        .lif_spikes(lif_spikes),
        // The OOC netlist flattens [0:0][27:0] into an escaped per-element name.
        .\neuron_currents[0] (neuron_currents)
    );

    always #(PERIOD_NS/2.0) clk = ~clk;

    always @(posedge clk) begin
        if (rst) marker_pipe <= '0;
        else     marker_pipe <= {marker_pipe[LIF_MARKER_DELAY-2:0], step0};
    end

    integer pass_idx;
    integer vec_idx;
    initial begin
        $readmemh(`ACTIVITY_PATH, stimulus);

        repeat (5) @(negedge clk);
        rst = 1'b0;

        for (pass_idx = 0; pass_idx < NUM_PASSES; pass_idx = pass_idx + 1) begin
            for (vec_idx = 0; vec_idx < NUM_VECTORS; vec_idx = vec_idx + 1) begin
                spikes   = stimulus[vec_idx];
                valid_in = 1'b1;
                step0    = (vec_idx % TIME_STEPS == 0);
                @(negedge clk);
            end
        end

        valid_in = 1'b0;
        step0    = 1'b0;
        spikes   = '0;
        repeat (40) @(negedge clk);
        $finish;
    end
endmodule
