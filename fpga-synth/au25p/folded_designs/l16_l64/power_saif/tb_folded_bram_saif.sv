`timescale 1ns/1ps

`ifndef CLK_PERIOD_NS
`define CLK_PERIOD_NS 10.0
`endif
`ifndef LANES
`define LANES 16
`endif
`ifndef L1_WEIGHTS_PATH
`define L1_WEIGHTS_PATH "sw/model_params/layer1_weights.hex"
`endif
`ifndef SPIKE_ACTIVITY_PATH
`define SPIKE_ACTIVITY_PATH "fpga-synth/au25p/single_neuron_e2e/activity/activity_images.hex"
`endif

// One complete, trained-weight inference for post-route SAIF generation.
// The weight source is ideal and gap-free; DDR/AXI/shell activity is outside
// this core-only experiment.
module tb_folded_bram_saif;
    localparam real PERIOD_NS = `CLK_PERIOD_NS;
    localparam int NUM_INPUTS = 4096;
    localparam int NUM_HIDDEN = 512;
    localparam int TIME_STEPS = 25;
    localparam int LANES_P = `LANES;
    localparam int FOLDS = NUM_INPUTS / LANES_P;
    localparam int SPIKE_WORDS = TIME_STEPS * FOLDS;
    localparam int ROW_BEATS = NUM_INPUTS * 16 / 64;
    localparam int WEIGHTS = NUM_INPUTS * NUM_HIDDEN;

    logic clk = 0;
    logic rst = 1;
    logic start_image = 0;
    logic image_ready;
    logic spike_valid = 0;
    logic spike_ready;
    logic [LANES_P-1:0] spike_data = 0;
    logic row_request_valid;
    logic row_request_ready = 0;
    logic [8:0] row_request_neuron;
    logic weight_valid = 0;
    logic weight_ready;
    logic [63:0] weight_data = 0;
    logic weight_last = 0;
    logic inference_valid;
    logic [4:0] collision_counter;
    logic [4:0] no_collision_counter;
    logic classification;
    logic protocol_error;

    logic [15:0] l1_weights [0:WEIGHTS-1];
    logic [NUM_INPUTS-1:0] spike_frames [0:399];
    integer request_count = 0;
    integer beat_count = 0;
    longint unsigned cycles = 0;

    folded_bram_predictor dut (.*);

    always #(PERIOD_NS/2.0) clk = ~clk;

    initial begin
        $readmemh(`L1_WEIGHTS_PATH, l1_weights);
        $readmemh(`SPIKE_ACTIVITY_PATH, spike_frames);
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if ((cycles % 500000) == 0)
                $display("SAIF_PROGRESS lanes=%0d cycles=%0d rows=%0d beats=%0d req=%0d ready=%0d",
                         LANES_P, cycles, request_count, beat_count,
                         row_request_valid, weight_ready);
            if (cycles > 64'd20000000)
                $fatal(1, "SAIF workload timeout");
        end
    end

    initial begin : weight_source
        integer beat;
        integer row;
        forever begin
            wait (row_request_valid);
            row = row_request_neuron;
            @(negedge clk);
            row_request_ready = 1;
            @(negedge clk);
            row_request_ready = 0;
            request_count = request_count + 1;

            wait (weight_ready);
            for (beat = 0; beat < ROW_BEATS; beat = beat + 1) begin
                @(negedge clk);
                weight_valid = 1;
                weight_data = {
                    l1_weights[row*NUM_INPUTS + beat*4 + 3],
                    l1_weights[row*NUM_INPUTS + beat*4 + 2],
                    l1_weights[row*NUM_INPUTS + beat*4 + 1],
                    l1_weights[row*NUM_INPUTS + beat*4 + 0]
                };
                weight_last = (beat == ROW_BEATS-1);
                beat_count = beat_count + 1;
            end
            @(negedge clk);
            weight_valid = 0;
            weight_last = 0;
            weight_data = 0;
        end
    end

    initial begin : stimulus
        integer word;
        integer tstep;
        integer fold;

        // Keep the explicit design reset asserted beyond the functional
        // netlist's global startup reset (GSR, nominally 100 ns).
        #200;
        repeat (5) @(negedge clk);
        rst = 0;
        repeat (3) @(negedge clk);
        if (image_ready !== 1'b1)
            $fatal(1, "image_ready did not assert after post-GSR reset");
        wait (image_ready);
        @(negedge clk);
        start_image = 1;
        @(negedge clk);
        start_image = 0;

        wait (spike_ready);
        for (word = 0; word < SPIKE_WORDS; word = word + 1) begin
            tstep = word / FOLDS;
            fold = word % FOLDS;
            @(negedge clk);
            spike_valid = 1;
            spike_data = spike_frames[tstep][fold*LANES_P +: LANES_P];
        end
        @(negedge clk);
        spike_valid = 0;
        spike_data = 0;

        wait (inference_valid);
        #1;
        if (request_count != NUM_HIDDEN)
            $fatal(1, "row requests %0d != %0d", request_count, NUM_HIDDEN);
        if (beat_count != NUM_HIDDEN * ROW_BEATS)
            $fatal(1, "weight beats %0d != %0d", beat_count,
                   NUM_HIDDEN * ROW_BEATS);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");
        $display("SAIF_WORKLOAD_PASS lanes=%0d cycles=%0d rows=%0d beats=%0d class=%0d",
                 LANES_P, cycles, request_count, beat_count, classification);
        repeat (5) @(negedge clk);
        $finish;
    end
endmodule
