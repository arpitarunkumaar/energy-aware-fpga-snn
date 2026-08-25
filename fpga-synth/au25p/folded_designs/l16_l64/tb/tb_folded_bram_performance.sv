`timescale 1ns/1ps

// Full-size ideal-stream cycle benchmark.  Arithmetic values are deliberately
// simple; bit-exact trained-network correctness is covered by cocotb.
module tb_folded_bram_performance #(
    parameter int LANES = 16,
    parameter int ROW_BUFFERS = 2
);
    localparam int NUM_INPUTS = 4096;
    localparam int NUM_HIDDEN = 512;
    localparam int TIME_STEPS = 25;
    localparam int WEIGHT_STREAM_WIDTH = 64;
    localparam int SPIKE_WORDS = TIME_STEPS * NUM_INPUTS / LANES;
    localparam int WEIGHT_BEATS = NUM_INPUTS * 16 / WEIGHT_STREAM_WIDTH;

    logic clk = 0;
    logic rst = 1;
    logic start_image = 0;
    logic image_ready;
    logic spike_valid = 0;
    logic spike_ready;
    logic [LANES-1:0] spike_data = '1;
    logic row_request_valid;
    logic row_request_ready = 0;
    logic [$clog2(NUM_HIDDEN)-1:0] row_request_neuron;
    logic weight_valid = 0;
    logic weight_ready;
    logic [WEIGHT_STREAM_WIDTH-1:0] weight_data = {4{16'h0001}};
    logic weight_last = 0;
    logic inference_valid;
    logic [4:0] collision_counter;
    logic [4:0] no_collision_counter;
    logic classification;
    logic protocol_error;

    longint unsigned cycles = 0;
    longint unsigned start_cycle = 0;
    longint unsigned requests = 0;
    longint unsigned beats = 0;

    folded_bram_predictor #(
        .LANES(LANES),
        .ROW_BUFFERS(ROW_BUFFERS),
        .WEIGHT_STREAM_WIDTH(WEIGHT_STREAM_WIDTH),
        .LAYER1_BIASES_PATH("sw/model_params/layer1_biases.hex"),
        .LAYER2_WEIGHTS_PATH("sw/model_params/layer2_weights.hex"),
        .LAYER2_BIASES_PATH("sw/model_params/layer2_biases.hex")
    ) dut (.*);

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            if (start_image && image_ready)
                start_cycle = cycles;
            if (cycles - start_cycle > 64'd20000000)
                $fatal(1, "timeout compute_state=%0d loader_state=%0d neuron=%0d",
                       dut.compute_state, dut.loader_state, dut.compute_neuron);
        end
    end

    initial begin : weight_source
        integer beat;
        forever begin
            wait (row_request_valid);
            @(negedge clk);
            row_request_ready = 1;
            @(negedge clk);
            row_request_ready = 0;
            requests = requests + 1;

            wait (weight_ready);
            weight_valid = 1;
            for (beat = 0; beat < WEIGHT_BEATS; beat = beat + 1) begin
                weight_last = (beat == WEIGHT_BEATS-1);
                @(negedge clk);
                beats = beats + 1;
            end
            weight_valid = 0;
            weight_last = 0;
        end
    end

    initial begin : stimulus
        integer word;
        repeat (5) @(negedge clk);
        rst = 0;
        wait (image_ready);
        @(negedge clk);
        start_image = 1;
        @(negedge clk);
        start_image = 0;

        wait (spike_ready);
        spike_valid = 1;
        for (word = 0; word < SPIKE_WORDS; word = word + 1)
            @(negedge clk);
        spike_valid = 0;

        wait (inference_valid);
        #1;
        if (requests != NUM_HIDDEN)
            $fatal(1, "row request count %0d != %0d", requests, NUM_HIDDEN);
        if (beats != NUM_HIDDEN * WEIGHT_BEATS)
            $fatal(1, "accepted beat count %0d != %0d", beats,
                   NUM_HIDDEN * WEIGHT_BEATS);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");

        $display("PERF lanes=%0d row_buffers=%0d elapsed_cycles=%0d rows=%0d beats=%0d",
                 LANES, ROW_BUFFERS, cycles-start_cycle, requests, beats);
        $finish;
    end
endmodule
