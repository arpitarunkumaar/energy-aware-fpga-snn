`timescale 1ns/1ps

// Out-of-context partition of the fully parallel 512-neuron predictor.
// BLOCK_NEURONS=1 is one 4096-input adder tree, bias, and LIF.
module parallel512_weight_partition_ooc #(
    parameter int NUM_INPUTS = 4096,
    parameter int BLOCK_NEURONS = 4,
    parameter int BLOCK_BASE = 0,
    parameter int FIRST_LAYER_K = 15,
    parameter int FIRST_LAYER_THRESHOLD = 8938,
    parameter string WEIGHT_FILE = "layer1_weights_part_000.hex",
    parameter string BIAS_FILE = "layer1_biases.hex"
) (
    input  logic clk,
    input  logic rst,
    input  logic valid_in,
    input  logic lif_new_image,
    input  logic [NUM_INPUTS-1:0] spikes,
    output logic [BLOCK_NEURONS-1:0] valid_out,
    output logic [BLOCK_NEURONS-1:0] lif_spikes,
    output logic signed [BLOCK_NEURONS-1:0][27:0] neuron_currents
);
    localparam int BLOCK_WORDS = BLOCK_NEURONS * NUM_INPUTS;
    localparam int ADDER_WIDTH = 16 + $clog2(NUM_INPUTS);

    logic signed [15:0] weight_mem [0:BLOCK_WORDS-1];
    logic signed [NUM_INPUTS-1:0][15:0] weight_row [0:BLOCK_NEURONS-1];
    logic signed [15:0] all_biases [0:511];
    logic signed [ADDER_WIDTH-1:0] adder_output [0:BLOCK_NEURONS-1];
    logic signed [27:0] input_current [0:BLOCK_NEURONS-1];

    initial begin
        $readmemh(WEIGHT_FILE, weight_mem);
        $readmemh(BIAS_FILE, all_biases);
    end

    generate
        for (genvar neuron = 0; neuron < BLOCK_NEURONS; neuron++) begin : g_neuron
            for (genvar col = 0; col < NUM_INPUTS; col++) begin : g_pack
                assign weight_row[neuron][col] = weight_mem[neuron*NUM_INPUTS + col];
            end

            cascaded_adder #(
                .NUM_INPUTS(NUM_INPUTS)
            ) adder (
                .clk(clk),
                .rst_n(~rst),
                .spike(spikes),
                .weight(weight_row[neuron]),
                .valid_in(valid_in),
                .out(adder_output[neuron]),
                .valid_out(valid_out[neuron])
            );

            always_ff @(posedge clk) begin
                if (rst)
                    input_current[neuron] <= '0;
                else
                    input_current[neuron] <= adder_output[neuron]
                                             + all_biases[BLOCK_BASE + neuron];
            end

            lif_model #(
                .k(FIRST_LAYER_K),
                .uth(FIRST_LAYER_THRESHOLD)
            ) lif (
                .clk(clk),
                .rst(rst),
                .enable(valid_out[neuron]),
                .new_image(lif_new_image),
                .input_current(input_current[neuron]),
                .spike(lif_spikes[neuron])
            );

            assign neuron_currents[neuron] = input_current[neuron];
        end
    endgenerate
endmodule
