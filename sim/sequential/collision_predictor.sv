`timescale 1ns/1ps

//second_layer_counter tracks the cycle that the lif is producing an output.
//code currently assumes that lif takes only one cycle to execute. If it takes longer, second_layer_counter increment condition will need to be modified.

//Here is an overview of how this code is meant to function:
//cascaded_adder_first_layer_lif is a global counter, showing where we are in the list of weights to be added.
//Note that we begin from the bottom of the LIF weights. We do this to keep cascaded_adder_first_layer_lif + post_final_cycle_counter constant.
//This also helps ensure that resetting cascaded_adder_first_layer_lif to zero does not produce outputs immeidately when reset is lowered.
//We can extrapolate from this counter to determine which output is currently being released from the cascaded adder, as well as when to output the result of the MAC module.
//post_final_cycle_counter tracks how many inputs are currently in the cascaded_adder pipeline.
//We trust that the 4096 input spikes are provided consecutively for 512 cycles. On the first cycle, new_time_step is activated, and new_image is activated if this is the first time-step.
//After 512 cycles of input spikes, the code will output the result of MAC modules to the second layer LIF accumulators.

module collision_predictor 
#(
    parameter integer NUM_HIDDEN_LAYER = 512,
    parameter integer NUM_INPUTS = 4096,
    parameter integer NUM_STAGES_FIRST_LAYER = $clog2(NUM_INPUTS),
    parameter integer NUM_STAGES_SECOND_LAYER = $clog2(NUM_HIDDEN_LAYER),
    parameter integer IN_WIDTH = 16,
    parameter integer FIRST_LAYER_WIDTH = IN_WIDTH + NUM_STAGES_FIRST_LAYER,
    parameter integer SECOND_LAYER_WIDTH = IN_WIDTH + NUM_STAGES_SECOND_LAYER,
    parameter integer TIME_STEPS = 25,
    parameter integer FIRST_LAYER_K = 15,
    parameter integer SECOND_LAYER_K = 15,
    parameter integer FIRST_LAYER_THRESHOLD = 8938,
    parameter integer SECOND_LAYER_THRESHOLD = 6775,
    // $readmemh paths are resolved relative to the simulator's CWD.
    // Override with -GLAYER1_WEIGHTS_PATH=... / -GLAYER2_WEIGHTS_PATH=... at elab time.
    parameter string LAYER1_WEIGHTS_PATH = "sw/model_params/layer1_weights.hex",
    parameter string LAYER2_WEIGHTS_PATH = "sw/model_params/layer2_weights.hex",
    parameter string LAYER1_BIASES_PATH = "sw/model_params/layer1_biases.hex",
    parameter string LAYER2_BIASES_PATH = "sw/model_params/layer2_biases.hex"
) (
    input logic clk,
    input logic rst,
    input logic [NUM_INPUTS-1:0] spikes,
    input logic new_image,
    input logic new_time_step,
    output logic out_valid,
    output logic [4:0] collision_counter,
    output logic [4:0] no_collision_counter,
    output logic ready_for_new_time_step,
    output logic ready_for_new_image
);

logic [4:0] input_time_step;
logic [4:0] output_time_step;

// Layer 1: 512 hidden neurons x 4096 inputs. layer1_weights.hex is one 16-bit
// Q1.15 value per line, row-major (neuron 0's 4096 weights first).
logic signed [15:0] layer1_weights [0:NUM_HIDDEN_LAYER-1][0:NUM_INPUTS-1];
logic signed [15:0] layer1_biases [0:NUM_HIDDEN_LAYER-1];

// Layer 2: 2 output classes x 512 hidden neurons. File is class-major:
// class 0 (no_collision) weights first, then class 1 (collision).
logic signed [15:0] layer2_weights [0:1][0:NUM_HIDDEN_LAYER-1];
logic signed [15:0] layer2_biases [0:1];

// Packed view of the currently-selected layer-1 row, wired to cascaded_adder.
logic signed [NUM_INPUTS-1:0][15:0] layer1_weight_row;
logic signed [15:0] layer1_bias_row;

logic in_valid_cascaded_adder;
logic out_valid_cascaded_adder;
logic in_valid_lif_first_layer;
logic [FIRST_LAYER_WIDTH-1:0] cascaded_adder_output;
logic [FIRST_LAYER_WIDTH-1:0] input_current;
logic [NUM_STAGES_SECOND_LAYER:0] cascaded_adder_first_layer_lif;
logic [3:0] post_final_cycle_counter;

logic [SECOND_LAYER_WIDTH-1:0] input_current_to_collision_lif;
logic [SECOND_LAYER_WIDTH-1:0] input_current_to_no_collision_lif;
logic lif_spike_output [0:NUM_HIDDEN_LAYER-1];
logic [NUM_STAGES_SECOND_LAYER-1:0] lif_output_to_read_from;
logic collision_spike;
logic no_collision_spike;
logic output_not_relayed;
logic lif_output_valid;
logic second_layer_enable;

initial begin
    $readmemh(LAYER1_WEIGHTS_PATH, layer1_weights);
    $readmemh(LAYER2_WEIGHTS_PATH, layer2_weights);
    $readmemh(LAYER1_BIASES_PATH, layer1_biases);
    $readmemh(LAYER2_BIASES_PATH, layer2_biases);
end

integer i;
always_comb begin
    for (i = 0; i < NUM_INPUTS; i = i + 1) begin
        layer1_weight_row[i] = layer1_weights[cascaded_adder_first_layer_lif][i];
        layer1_bias_row = (cascaded_adder_first_layer_lif + post_final_cycle_counter == 0) ? 0 : ((cascaded_adder_first_layer_lif + post_final_cycle_counter - 1 >= NUM_HIDDEN_LAYER) ? layer1_biases[cascaded_adder_first_layer_lif + post_final_cycle_counter - NUM_HIDDEN_LAYER] : layer1_biases[cascaded_adder_first_layer_lif + post_final_cycle_counter - 1]);
    end
end


always_ff @(posedge clk) begin
    if (rst) begin
        input_time_step <= 0;
        in_valid_cascaded_adder <= 0;
        ready_for_new_image <= 0;
        ready_for_new_time_step <= 0;
        cascaded_adder_first_layer_lif <= 0;
    end else begin
        if (new_image) begin
            input_time_step <= TIME_STEPS-1;
            in_valid_cascaded_adder <= 1;
            cascaded_adder_first_layer_lif <= NUM_HIDDEN_LAYER-1;
            ready_for_new_image <= 0;
        end else if (new_time_step) begin
            cascaded_adder_first_layer_lif <= NUM_HIDDEN_LAYER-1;
            in_valid_cascaded_adder <= 1;
            input_time_step <= input_time_step - 1;
            ready_for_new_time_step <= 0;
        end else if (cascaded_adder_first_layer_lif == 2) begin
            cascaded_adder_first_layer_lif <= 1;
            in_valid_cascaded_adder <= 1;
            if (input_time_step != 0) begin
                ready_for_new_time_step <= 1;
                ready_for_new_image <= 0;
            end else begin
                ready_for_new_image <= 1;
                ready_for_new_time_step <= 0;
            end
        end else if (cascaded_adder_first_layer_lif != 0) begin
            cascaded_adder_first_layer_lif <= cascaded_adder_first_layer_lif - 1;
            in_valid_cascaded_adder <= 1;
        end else if (input_time_step != 0) begin
            ready_for_new_time_step <= 1;
            in_valid_cascaded_adder <= 0;
            ready_for_new_image <= 0;
        end else begin
            ready_for_new_image <= 1;
            in_valid_cascaded_adder <= 0;
            ready_for_new_time_step <= 0;
        end
    end
end

//when out_valid falls to zero from the cascaded adder, then we know that this is the last cycle.

cascaded_adder
#(
    .NUM_INPUTS(NUM_INPUTS)
)
input_cascaded_adder
(
    .clk(clk),
    .rst_n(~rst),
    .spike(spikes),
    .weight(layer1_weight_row),
    .valid_in(in_valid_cascaded_adder),
    .out(cascaded_adder_output),
    .valid_out(out_valid_cascaded_adder)
);

genvar j;
generate
    for (j = 0; j < NUM_HIDDEN_LAYER; j = j + 1) begin
        lif_model #(.k(FIRST_LAYER_K), .uth(FIRST_LAYER_THRESHOLD)) thread (clk, rst, (in_valid_lif_first_layer && ((cascaded_adder_first_layer_lif + post_final_cycle_counter == j) || (cascaded_adder_first_layer_lif + post_final_cycle_counter - NUM_HIDDEN_LAYER == j))), ((input_time_step == TIME_STEPS-1) && (cascaded_adder_first_layer_lif + post_final_cycle_counter == NUM_HIDDEN_LAYER-1)), input_current, lif_spike_output[j]);
    end
endgenerate

//second layer enable goes to 1 exactly when the last element is added to the MAC module. The second layer LIF models move forward one time-step when this happens.

always_ff @(posedge clk) begin
    if (rst) begin
        lif_output_valid <= 0;
        lif_output_to_read_from <= 0;
        input_current_to_collision_lif <= 0;
        input_current_to_no_collision_lif <= 0;
        second_layer_enable <= 0;
    end else begin
        in_valid_lif_first_layer <= out_valid_cascaded_adder;
        lif_output_valid <= in_valid_lif_first_layer;
        input_current <= cascaded_adder_output + layer1_bias_row;
        if (!out_valid_cascaded_adder) begin
            if (new_time_step || (cascaded_adder_first_layer_lif != 0)) begin //New time step needs to be high when new image is high
                post_final_cycle_counter <= post_final_cycle_counter + 1;
            end
        end else begin
            if (!new_time_step && (cascaded_adder_first_layer_lif == 0)) begin
                post_final_cycle_counter <= post_final_cycle_counter - 1;
            end
        end
        if (cascaded_adder_first_layer_lif + post_final_cycle_counter >= NUM_HIDDEN_LAYER) begin
            lif_output_to_read_from <= cascaded_adder_first_layer_lif + post_final_cycle_counter - NUM_HIDDEN_LAYER;
        end else begin
            lif_output_to_read_from <= cascaded_adder_first_layer_lif + post_final_cycle_counter;
        end
        if (second_layer_enable && lif_output_valid) begin
            input_current_to_collision_lif <= layer2_biases[1] + (lif_spike_output[lif_output_to_read_from]*layer2_weights[1][lif_output_to_read_from]);
            input_current_to_no_collision_lif <= layer2_biases[0] + (lif_spike_output[lif_output_to_read_from]*layer2_weights[0][lif_output_to_read_from]);
        end else if (lif_output_valid) begin
            input_current_to_collision_lif <= input_current_to_collision_lif + (lif_spike_output[lif_output_to_read_from]*layer2_weights[1][lif_output_to_read_from]);
            input_current_to_no_collision_lif <= input_current_to_no_collision_lif + (lif_spike_output[lif_output_to_read_from]*layer2_weights[0][lif_output_to_read_from]);
        end else if (second_layer_enable) begin
            input_current_to_collision_lif <= 0;
            input_current_to_no_collision_lif <= 0;
        end
        if (lif_output_valid && (lif_output_to_read_from == 0)) begin
            second_layer_enable <= 1;
        end else begin
            second_layer_enable <= 0;
        end
    end
end

lif_model
#(
    .k(SECOND_LAYER_K),
    .uth(SECOND_LAYER_THRESHOLD)
)
second_layer_collision
(
    .clk(clk),
    .rst(rst),
    .enable(second_layer_enable),
    .new_image((input_time_step == TIME_STEPS-1) && (lif_output_to_read_from == NUM_HIDDEN_LAYER-1)),
    .input_current(input_current_to_collision_lif),
    .spike(collision_spike)
);

lif_model
#(
    .k(SECOND_LAYER_K),
    .uth(SECOND_LAYER_THRESHOLD)
)
second_layer_no_collision
(
    .clk(clk),
    .rst(rst),
    .enable(second_layer_enable),
    .new_image((input_time_step == TIME_STEPS-1) && (lif_output_to_read_from == NUM_HIDDEN_LAYER-1)),
    .input_current(input_current_to_no_collision_lif),
    .spike(no_collision_spike)
);

always_ff @(posedge clk) begin
    if (rst) begin
        output_time_step <= 0;
        collision_counter <= 0;
        no_collision_counter <= 0;
        output_not_relayed <= 0;
        out_valid <= 0;
    end else begin
        if (new_image && second_layer_enable) begin
            output_time_step <= output_time_step + TIME_STEPS - 1;
        end else if (new_image) begin
            output_time_step <= output_time_step + TIME_STEPS;
        end else if (second_layer_enable) begin
            output_time_step <= output_time_step - 1;
        end
        if (collision_spike) begin
            collision_counter <= collision_counter + 1;
        end else if (!output_not_relayed) begin
            collision_counter <= 0;
        end
        if (no_collision_spike) begin
            no_collision_counter <= no_collision_counter + 1;
        end else if (!output_not_relayed) begin
            no_collision_counter <= 0;
        end
        if (((output_time_step == 0) || (output_time_step == TIME_STEPS)) && (output_not_relayed)) begin
            out_valid <= 1;
            output_not_relayed <= 0;
        end else if (!output_not_relayed && second_layer_enable) begin
            out_valid <= 0;
            output_not_relayed <= 1;
        end else if (!output_not_relayed) begin
            out_valid <= 0;
        end else begin
            out_valid <= 0;
            output_not_relayed <= 1;
        end
    end
end

//Take the results and apply them to a LIF input (the enable for only that LIF should be activated)
//Spike results are weighted by the weight associated with that LIF neuron. Remember that they come in one neuron at a time, for only one cycle.

endmodule

//Questions:
//Do we need to shorten the clock period of the lif model through pipelining to match that of the cascaded adder?

//cascaded_adder thread (clk, ~rst, spike_array[i][time_step], )
//if (2*(NUM_INPUTS/2) != NUM_INPUTS) begin


// second_layer_enable is not turning on
