`timescale 1ns/1ps

// Directed test for K-way hidden-neuron processing, including a final batch
// with fewer valid neurons than NUM_ENGINES.
module tb_folded_bram_predictor_parallel;
    localparam int NUM_INPUTS = 16;
    localparam int NUM_HIDDEN = 6;
    localparam int TIME_STEPS = 2;
    localparam int LANES = 4;
    localparam int NUM_ENGINES = 4;
    localparam int WEIGHT_STREAM_WIDTH = 64;
    localparam int SPIKE_WORDS = TIME_STEPS * NUM_INPUTS / LANES;
    localparam int WEIGHT_BEATS = NUM_INPUTS * 16 / WEIGHT_STREAM_WIDTH;

    logic clk = 0;
    logic rst = 1;
    logic start_image = 0;
    logic image_ready;
    logic spike_valid = 0;
    logic spike_ready;
    logic [LANES-1:0] spike_data = '0;
    logic row_request_valid;
    logic row_request_ready = 0;
    logic [$clog2(NUM_HIDDEN)-1:0] row_request_neuron;
    logic weight_valid = 0;
    logic weight_ready;
    logic [WEIGHT_STREAM_WIDTH-1:0] weight_data = '0;
    logic weight_last = 0;
    logic inference_valid;
    logic [4:0] collision_counter;
    logic [4:0] no_collision_counter;
    logic classification;
    logic protocol_error;

    integer cycles = 0;
    integer requests = 0;
    integer beats = 0;

    folded_bram_predictor_parallel #(
        .NUM_INPUTS(NUM_INPUTS),
        .NUM_HIDDEN(NUM_HIDDEN),
        .TIME_STEPS(TIME_STEPS),
        .LANES(LANES),
        .NUM_ENGINES(NUM_ENGINES),
        .WEIGHT_STREAM_WIDTH(WEIGHT_STREAM_WIDTH),
        .FIRST_LAYER_THRESHOLD(10),
        .SECOND_LAYER_THRESHOLD(5),
        .LAYER1_BIASES_PATH("fpga-synth/au25p/tb/data/parallel_l1_bias.hex"),
        .LAYER2_WEIGHTS_PATH("fpga-synth/au25p/tb/data/parallel_l2_weights.hex"),
        .LAYER2_BIASES_PATH("fpga-synth/au25p/tb/data/parallel_l2_bias.hex")
    ) dut (.*);

    always #5 clk = ~clk;

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 2000)
            $fatal(1,
                   "timeout compute_state=%0d loader_state=%0d batch=%0d load_neuron=%0d",
                   dut.compute_state, dut.loader_state, dut.compute_batch,
                   dut.load_neuron);
    end

    // The ideal source checks that the partial final batch does not cause
    // requests for padded/nonexistent neurons 6 or 7.
    initial begin : weight_source
        integer beat;
        integer requested_neuron;

        forever begin
            wait (row_request_valid);
            requested_neuron = row_request_neuron;
            if (requested_neuron != requests)
                $fatal(1, "row request %0d arrived at position %0d",
                       requested_neuron, requests);

            @(negedge clk);
            row_request_ready = 1;
            @(negedge clk);
            row_request_ready = 0;
            requests = requests + 1;

            wait (weight_ready);
            weight_valid = 1;
            weight_data = {4{16'h0001}};
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
        spike_data = '1;
        for (word = 0; word < SPIKE_WORDS; word = word + 1)
            @(negedge clk);
        spike_valid = 0;

        wait (inference_valid);
        #1;
        if (requests != NUM_HIDDEN)
            $fatal(1, "expected %0d row requests, got %0d",
                   NUM_HIDDEN, requests);
        if (beats != NUM_HIDDEN * WEIGHT_BEATS)
            $fatal(1, "expected %0d accepted beats, got %0d",
                   NUM_HIDDEN * WEIGHT_BEATS, beats);
        if (collision_counter !== 1 || no_collision_counter !== 0)
            $fatal(1, "wrong counters collision=%0d no_collision=%0d",
                   collision_counter, no_collision_counter);
        if (!classification)
            $fatal(1, "classification should select collision");
        if (protocol_error)
            $fatal(1, "protocol_error asserted");

        $display("PASS parallel engines=%0d hidden=%0d cycles=%0d rows=%0d beats=%0d",
                 NUM_ENGINES, NUM_HIDDEN, cycles, requests, beats);
        $finish;
    end
endmodule
