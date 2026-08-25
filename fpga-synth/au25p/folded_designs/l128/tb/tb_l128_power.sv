`timescale 1ns/1ps

`ifndef L128_CLOCK_PERIOD_NS
`define L128_CLOCK_PERIOD_NS 5.000
`endif
`ifndef L128_L1_WEIGHTS_PATH
`define L128_L1_WEIGHTS_PATH "sw/model_params/layer1_weights.hex"
`endif
`ifndef L128_SPIKE_WORDS_PATH
`define L128_SPIKE_WORDS_PATH "fpga-synth/au25p/l128/activity/spk_img000_128.hex"
`endif

module tb_l128_power;
    localparam int NUM_INPUTS = 4096;
    localparam int NUM_HIDDEN = 512;
    localparam int INPUT_WORDS = 800;
    localparam int ROW_BEATS = 512;
    localparam int WEIGHTS = NUM_INPUTS * NUM_HIDDEN;

    logic clk = 0;
    logic rst = 1;
    logic start_image = 0;
    logic image_ready;
    logic spike_valid = 0;
    logic spike_ready;
    logic [127:0] spike_data = 0;
    logic row_request_valid;
    logic row_request_ready = 1;
    logic [8:0] row_request_neuron;
    logic weight_valid;
    logic weight_ready;
    logic [127:0] weight_data;
    logic weight_last;
    logic inference_valid;
    logic [4:0] collision_counter;
    logic [4:0] no_collision_counter;
    logic classification;
    logic protocol_error;
    logic [31:0] inference_cycles;
    logic [31:0] compute_cycles;
    logic [31:0] weight_load_cycles;
    logic [31:0] input_load_cycles;
    logic [31:0] row_stall_cycles;
    logic hidden_spike_valid;
    logic [8:0] hidden_spike_neuron;
    logic [4:0] hidden_spike_timestep;
    logic hidden_spike;
    logic output_spike_valid;
    logic output_spike_neuron;
    logic [4:0] output_spike_timestep;
    logic output_spike;

    logic [15:0] l1_weights [0:WEIGHTS-1];
    logic [127:0] spike_words [0:INPUT_WORDS-1];
    logic streaming = 0;
    logic [8:0] stream_row = 0;
    logic [8:0] stream_beat = 0;
    longint unsigned cycle_count = 0;
    integer request_count = 0;

    always #(`L128_CLOCK_PERIOD_NS/2.0) clk = ~clk;

    initial begin
        $readmemh(`L128_L1_WEIGHTS_PATH, l1_weights);
        $readmemh(`L128_SPIKE_WORDS_PATH, spike_words);
    end

    collision_predictor dut (.*);

    always_comb begin
        weight_data = {
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 7],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 6],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 5],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 4],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 3],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 2],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 1],
            l1_weights[stream_row*NUM_INPUTS + stream_beat*8 + 0]
        };
        weight_valid = streaming;
        weight_last = streaming && (stream_beat == ROW_BEATS-1);
    end

    always @(posedge clk) begin
        if (rst) begin
            streaming <= 0;
            stream_row <= 0;
            stream_beat <= 0;
            cycle_count <= 0;
            request_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (row_request_valid && row_request_ready) begin
                streaming <= 1;
                stream_row <= row_request_neuron;
                stream_beat <= 0;
                request_count <= request_count + 1;
            end else if (streaming && weight_ready) begin
                if (stream_beat == ROW_BEATS-1) begin
                    streaming <= 0;
                    stream_beat <= 0;
                end else begin
                    stream_beat <= stream_beat + 1'b1;
                end
            end
            if ((cycle_count != 0) && ((cycle_count % 100000) == 0))
                $display("L128_POWER_PROGRESS cycles=%0d requests=%0d compute=%0d weights=%0d input=%0d stalls=%0d",
                         cycle_count, request_count, compute_cycles,
                         weight_load_cycles, input_load_cycles,
                         row_stall_cycles);
            if (cycle_count > 64'd700000)
                $fatal(1, "SAIF workload timeout requests=%0d compute=%0d weights=%0d input=%0d stalls=%0d",
                       request_count, compute_cycles, weight_load_cycles,
                       input_load_cycles, row_stall_cycles);
        end
    end

    initial begin : stimulus
        integer word_index;
        // glbl.GSR remains asserted for the first 100 ns in a post-route
        // functional simulation. Delay stimulus so start_image is not lost.
        #200;
        repeat (8) @(negedge clk);
        rst = 0;

        wait (image_ready);
        @(negedge clk);
        start_image = 1;
        @(negedge clk);
        start_image = 0;

        wait (spike_ready);
        word_index = 0;
        spike_valid = 1;
        while (word_index < INPUT_WORDS) begin
            spike_data = spike_words[word_index];
            @(posedge clk);
            if (spike_ready)
                word_index = word_index + 1;
            @(negedge clk);
        end
        spike_valid = 0;
        spike_data = 0;

        wait (inference_valid);
        #1;
        if (request_count != NUM_HIDDEN)
            $fatal(1, "expected %0d row requests, got %0d",
                   NUM_HIDDEN, request_count);
        if (protocol_error)
            $fatal(1, "protocol_error asserted");
        if (compute_cycles != 409800 || weight_load_cycles != 262144
                || input_load_cycles != 800 || row_stall_cycles != 0)
            $fatal(1, "counter mismatch compute=%0d weights=%0d input=%0d stalls=%0d",
                   compute_cycles, weight_load_cycles, input_load_cycles,
                   row_stall_cycles);
        $display("L128_POWER_PASS cycles=%0d requests=%0d collision=%0d no_collision=%0d",
                 inference_cycles, request_count, collision_counter,
                 no_collision_counter);
        $finish;
    end
endmodule
