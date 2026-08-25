`timescale 1ns/1ps

// ============================================================================
// collision_predictor — understanding (written while reverse-engineering)
// ============================================================================
//
// WHAT IT IS
//   A 2-layer spiking neural net that classifies a stream of input "images"
//   as collision / no-collision. Each image is TIME_STEPS (25) time steps; each
//   time step is a NUM_INPUTS (4096)-wide binary spike vector on `spikes`.
//     Layer 1: NUM_HIDDEN_LAYER neurons, each = MAC over 4096 weighted input
//              spikes -> +bias -> LIF -> 1-bit spike.
//     Layer 2: 2 class neurons (no_collision=0, collision=1), each = MAC over
//              the NUM_HIDDEN_LAYER layer-1 spikes -> +bias -> LIF -> spike.
//   collision_counter / no_collision_counter accumulate each class's layer-2
//   spikes across an image's TIME_STEPS; out_valid pulses once per image when
//   those counters hold the final total.
//
// FULL-THROUGHPUT DATAFLOW (one time step per cycle)
//   The MACs are `cascaded_adder` instances: fully-parallel pipelined adder
//   trees, NOT sequential accumulators. A cascaded_adder with N inputs gates
//   spike&weight in stage 0 then reduces over NUM_STAGES=$clog2(N) tree stages,
//   so valid_out / out appear NUM_STAGES+1 cycles after valid_in. Because every
//   neuron has its own tree (generate loop), a fresh spike vector can be pushed
//   every cycle -> new time step each cycle.
//     Layer-1 latency = $clog2(NUM_INPUTS)+1 = 13   (NUM_INPUTS=4096)
//     Layer-2 latency = $clog2(NUM_HIDDEN)+1        (=10 at 512, =3 at 4)
//
// PIPELINE / OUT_VALID PHASE BOOKKEEPING
//   input_time_step: per-image counter, loaded to TIME_STEPS-1 on new_image and
//     counting down to 0 as time steps stream in.
//   post_final_cycle_counter / second_layer_post_final_cycle_counter: track how
//     many valid items are "in flight" in the layer-1 and layer-2 pipelines.
//     They are designed so input_time_step + post_final + second_layer_post is a
//     stable per-image phase; out_valid is meant to fire once per image, when
//     that phase sum is congruent to 0 mod TIME_STEPS (hence the {0, TIME_STEPS,
//     2*TIME_STEPS} compare set below). output_not_relayed is the 1-pulse-per-
//     image handshake that de-bounces the trigger.
//
// BUG FOUND & FIXED (double out_valid per image)
//   output_time_step held that phase sum but was only 5 bits. The steady-state
//   sum ranges ~18..42, so raw value 32 wrapped to 0 and falsely tripped the
//   ==0 branch, emitting a premature 2nd out_valid ~7 cycles before the real one
//   (which fires on the ==TIME_STEPS branch, when the counters are actually
//   final). Widened to 6 bits so the sum no longer aliases. This also affects
//   the real NUM_HIDDEN=512 build, whose sum ranges ~23..47 and likewise aliased
//   32 -> 0. See the width comment on output_time_step.
// ============================================================================

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
    output logic ready_for_new_image
);

logic [4:0] input_time_step;
// 6 bits, not 5: output_time_step holds input_time_step + post_final_cycle_counter
// + second_layer_post_final_cycle_counter, whose steady-state max is ~42 (and can
// reach 54 in the worst case). A 5-bit reg wraps at 32, so raw sum 32 aliases to 0
// and falsely trips the ==0 branch of the out_valid trigger, emitting a second,
// premature out_valid per image. Widening removes the alias so only the intended
// (raw sum mod TIME_STEPS == 0) value fires.
logic [5:0] output_time_step;

// Layer 1: 512 hidden neurons x 4096 inputs. layer1_weights.hex is one 16-bit
// Q1.15 value per line, row-major (neuron 0's 4096 weights first).
//
// STORAGE must be a *fully-unpacked* 2-D array. $readmemh assigns one file token
// per addressable unpacked element, and packed dimensions are NOT addressable.
// The original declaration `[NUM_INPUTS-1:0][15:0] layer1_weights [0:NH-1]`
// (packed inner) is therefore only NH words wide to $readmemh: it consumes just
// NH of the NH*NUM_INPUTS file lines and then reports "address beyond bounds"
// (verified in Verilator). The bug is invisible to the local tests because the
// NUM_HIDDEN != 512 path fills weights with 1s and never calls $readmemh; it only
// bites the real 512-neuron build. Store unpacked, then rebuild the per-neuron
// packed rows the cascaded_adders need via the g_pack_* generate below.
logic signed [15:0] layer1_weights_mem [0:NUM_HIDDEN_LAYER-1][0:NUM_INPUTS-1];
logic signed [15:0] layer1_biases [0:NUM_HIDDEN_LAYER-1];

// Layer 2: 2 output classes x 512 hidden neurons. File is class-major:
// class 0 (no_collision) weights first, then class 1 (collision).
logic signed [15:0] layer2_weights_mem [0:1][0:NUM_HIDDEN_LAYER-1];
logic signed [15:0] layer2_biases [0:1];

// Per-neuron packed weight rows actually wired to the adder ports. Rebuilt from
// the *_mem storage; this mirrors the low-area design's layer1_weight_row repack
// (which is proven correct), extended to every neuron since every neuron here
// has its own adder.
logic signed [NUM_INPUTS-1:0][15:0]       layer1_weights [0:NUM_HIDDEN_LAYER-1];
logic signed [NUM_HIDDEN_LAYER-1:0][15:0] layer2_weights [0:1];

genvar wr, wc;
generate
    for (wr = 0; wr < NUM_HIDDEN_LAYER; wr = wr + 1) begin : g_pack_l1
        for (wc = 0; wc < NUM_INPUTS; wc = wc + 1) begin : col
            assign layer1_weights[wr][wc] = layer1_weights_mem[wr][wc];
        end
    end
    for (wr = 0; wr < 2; wr = wr + 1) begin : g_pack_l2
        for (wc = 0; wc < NUM_HIDDEN_LAYER; wc = wc + 1) begin : col
            assign layer2_weights[wr][wc] = layer2_weights_mem[wr][wc];
        end
    end
endgenerate

logic in_valid_cascaded_adder;
logic out_valid_cascaded_adder [0:NUM_HIDDEN_LAYER-1];
logic in_valid_lif_first_layer;
logic second_layer_out_valid_cascaded_adder [0:1];
logic signed [FIRST_LAYER_WIDTH-1:0] cascaded_adder_output [NUM_HIDDEN_LAYER-1:0];
logic signed [FIRST_LAYER_WIDTH-1:0] input_current [NUM_HIDDEN_LAYER-1:0];
logic signed [SECOND_LAYER_WIDTH-1:0] second_layer_no_collision_cascaded_adder_output;
logic signed [SECOND_LAYER_WIDTH-1:0] second_layer_collision_cascaded_adder_output;
logic signed [SECOND_LAYER_WIDTH-1:0] input_current_to_collision_lif;
logic signed [SECOND_LAYER_WIDTH-1:0] input_current_to_no_collision_lif;
logic lif_spike_output [0:NUM_HIDDEN_LAYER-1];
logic [NUM_HIDDEN_LAYER-1:0] input_spikes_to_second_layer_cascaded_adder;
logic collision_spike;
logic no_collision_spike;
logic output_not_relayed;
logic lif_output_valid;
logic second_layer_enable;

logic [3:0] post_final_cycle_counter;
logic [3:0] second_layer_post_final_cycle_counter;

// The weight/bias .hex files are sized for the real 512-neuron network. When
// NUM_HIDDEN_LAYER is shrunk (e.g. for the timing test, which is value-agnostic),
// $readmemh would overflow the smaller arrays, so instead fill every entry with
// 1. This is a compile-time (generate) choice: whenever NUM_HIDDEN_LAYER == 512
// the fill branch is elided entirely and the real build/synth is unchanged.
generate
    if (NUM_HIDDEN_LAYER == 512) begin : g_load_params
        initial begin
            $readmemh(LAYER1_WEIGHTS_PATH, layer1_weights_mem);
            $readmemh(LAYER2_WEIGHTS_PATH, layer2_weights_mem);
            $readmemh(LAYER1_BIASES_PATH, layer1_biases);
            $readmemh(LAYER2_BIASES_PATH, layer2_biases);
        end
    end else begin : g_fill_params  // debug-only: hidden size != 512
        initial begin : fill_ones
            integer wn, wi;
            for (wn = 0; wn < NUM_HIDDEN_LAYER; wn = wn + 1) begin
                layer1_biases[wn] = 16'sd1;
                for (wi = 0; wi < NUM_INPUTS; wi = wi + 1) begin
                    layer1_weights_mem[wn][wi] = 16'sd1;
                end
            end
            for (wn = 0; wn < 2; wn = wn + 1) begin
                layer2_biases[wn] = 16'sd1;
                for (wi = 0; wi < NUM_HIDDEN_LAYER; wi = wi + 1) begin
                    layer2_weights_mem[wn][wi] = 16'sd1;
                end
            end
        end
    end
endgenerate

integer i;
always_comb begin
    for (i = 0; i < NUM_HIDDEN_LAYER; i = i + 1) begin
        input_spikes_to_second_layer_cascaded_adder[i] = lif_spike_output[i];
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        input_time_step <= 0;
        in_valid_cascaded_adder <= 0;
        ready_for_new_image <= 0;
        post_final_cycle_counter <= 0;
    end else begin
        if (new_image) begin
            input_time_step <= TIME_STEPS-1;
            in_valid_cascaded_adder <= 1;
            ready_for_new_image <= 0;
        end else if (input_time_step == 1) begin
            input_time_step <= 0;
            in_valid_cascaded_adder <= 1;
            ready_for_new_image <= 1;
        end else if ((input_time_step != 0) && (new_time_step == 1)) begin
            input_time_step <= input_time_step - 1;
            in_valid_cascaded_adder <= 1;
            ready_for_new_image <= 0;
        end else begin
            ready_for_new_image <= 1;
            in_valid_cascaded_adder <= 0;
        end
        in_valid_lif_first_layer <= out_valid_cascaded_adder[0];
        if (!out_valid_cascaded_adder[0]) begin
            if (new_image || input_time_step != 0) begin //New time step needs to be high when new image is high
                post_final_cycle_counter <= post_final_cycle_counter + 1;
            end
        end else begin
            if (!new_image && (input_time_step == 0)) begin
                post_final_cycle_counter <= post_final_cycle_counter - 1;
            end
        end
    end
end

integer j;
always_ff @(posedge clk) begin
    for (j = 0; j < NUM_HIDDEN_LAYER; j = j + 1) begin
        if (rst) begin
            input_current[j] <= 0;
        end else begin
            input_current[j] <= cascaded_adder_output[j] + layer1_biases[j];
        end
    end
end

//when out_valid falls to zero from the cascaded adder, then we know that this is the last cycle.

// --- LIF membrane-reset (new_image) markers, data-aligned for gap-less streaming ---
// new_image resets a LIF for a fresh image. It must fire at the image's FIRST step
// (like the golden low-area design, which resets at input_time_step==TIME_STEPS-1),
// NOT the last: in lif_model new_image forces spike = enable & (input_current > uth),
// bypassing the refractory counter, so resetting on the last step produced spurious
// spikes. The phase sum (input_time_step + post_final_cycle_counter) equals the
// input time-step of the data currently at the layer-1 LIF, so == TIME_STEPS-1 marks
// step 0 there. Deriving the marker at the boundary (not a separate priming cycle)
// is what makes back-to-back streaming reset correctly; a plain priming cycle is
// absent when images stream gap-lessly.
wire first_layer_lif_new_image = (input_time_step + post_final_cycle_counter == TIME_STEPS-1);
// The layer-2 first step lags the layer-1 first step by the layer-2 pipeline depth:
// clog2(NUM_HIDDEN)+1 (adder) + 1 (second_layer_enable reg). Delaying the layer-1
// marker (rather than comparing a phase sum) is robust to NUM_HIDDEN — whose growth
// floors input_time_step and shifts the layer-2 phase sum.
localparam int SECOND_LAYER_NI_DELAY = NUM_STAGES_SECOND_LAYER + 2;
logic [SECOND_LAYER_NI_DELAY-1:0] second_layer_ni_pipe;
always_ff @(posedge clk) begin
    if (rst) second_layer_ni_pipe <= '0;
    else     second_layer_ni_pipe <= {second_layer_ni_pipe[SECOND_LAYER_NI_DELAY-2:0], first_layer_lif_new_image};
end
wire second_layer_lif_new_image = second_layer_ni_pipe[SECOND_LAYER_NI_DELAY-1];

genvar p;
genvar q;
generate
    for (p = 0; p < NUM_HIDDEN_LAYER; p = p + 1) begin
        cascaded_adder #(.NUM_INPUTS(NUM_INPUTS)) thread (clk, ~rst, spikes, layer1_weights[p], in_valid_cascaded_adder, cascaded_adder_output[p], out_valid_cascaded_adder[p]);
    end
    for (q = 0; q < NUM_HIDDEN_LAYER; q = q + 1) begin
        lif_model #(.k(FIRST_LAYER_K), .uth(FIRST_LAYER_THRESHOLD)) thread (clk, rst, in_valid_lif_first_layer, first_layer_lif_new_image, input_current[q], lif_spike_output[q]);
    end
endgenerate

cascaded_adder
#(
    .NUM_INPUTS(NUM_HIDDEN_LAYER)
)
second_layer_no_collision_cascaded_adder
(
    .clk(clk),
    .rst_n(~rst),
    .spike(input_spikes_to_second_layer_cascaded_adder),
    .weight(layer2_weights[0]),
    .valid_in(in_valid_lif_first_layer),
    .out(second_layer_no_collision_cascaded_adder_output),
    .valid_out(second_layer_out_valid_cascaded_adder[0])
);

cascaded_adder
#(
    .NUM_INPUTS(NUM_HIDDEN_LAYER)
)
second_layer_collision_cascaded_adder
(
    .clk(clk),
    .rst_n(~rst),
    .spike(input_spikes_to_second_layer_cascaded_adder),
    .weight(layer2_weights[1]),
    .valid_in(in_valid_lif_first_layer),
    .out(second_layer_collision_cascaded_adder_output),
    .valid_out(second_layer_out_valid_cascaded_adder[1])
);

always_ff @(posedge clk) begin
    if (rst) begin
        input_current_to_no_collision_lif <= 0;
        input_current_to_collision_lif <= 0;
        second_layer_enable <= 0;
        second_layer_post_final_cycle_counter <= 0;
    end else begin
        input_current_to_no_collision_lif <= second_layer_no_collision_cascaded_adder_output + layer2_biases[0];
        input_current_to_collision_lif <= second_layer_collision_cascaded_adder_output + layer2_biases[1];
        second_layer_enable <= second_layer_out_valid_cascaded_adder[0];
        if (!second_layer_out_valid_cascaded_adder[0]) begin
            if (out_valid_cascaded_adder[0]) begin
                second_layer_post_final_cycle_counter <= second_layer_post_final_cycle_counter + 1;
            end
        end else begin
            if (!out_valid_cascaded_adder[0]) begin
                second_layer_post_final_cycle_counter <= second_layer_post_final_cycle_counter - 1;
            end
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
    // Reset at the layer-2 image boundary (step 0), delivered by the shadow-delayed
    // marker so gap-less streaming resets correctly. See first/second_layer_lif_new_image.
    .new_image(second_layer_lif_new_image),
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
    // Reset at the layer-2 image boundary (step 0), delivered by the shadow-delayed
    // marker so gap-less streaming resets correctly. See first/second_layer_lif_new_image.
    .new_image(second_layer_lif_new_image),
    .input_current(input_current_to_no_collision_lif),
    .spike(no_collision_spike)
);

// Per-image spike tally. Reset at the layer-2 image boundary (second_layer_lif_new_image
// = step 0 of a new image), so each image's step-0 spike is counted into ITS OWN tally.
// Necessary for gap-less streaming: without it, the next image's step-0 spike — which
// occurs one cycle before the previous image's out_valid — leaked into the previous
// image's count (+1 on the first image of a stream, -1 on the last).
logic [4:0] collision_live, no_collision_live;
always_ff @(posedge clk) begin
    if (rst) begin
        collision_live    <= 0;
        no_collision_live <= 0;
    end else if (second_layer_lif_new_image) begin
        collision_live    <= collision_spike    ? 5'd1 : 5'd0;
        no_collision_live <= no_collision_spike ? 5'd1 : 5'd0;
    end else begin
        if (collision_spike)    collision_live    <= collision_live    + 1;
        if (no_collision_spike) no_collision_live <= no_collision_live + 1;
    end
end

// out_valid fires once per image when this phase sum reaches a multiple of TIME_STEPS
// (unchanged timing — this is what the timing test checks).
wire phase_boundary = (output_time_step == 0) || (output_time_step == TIME_STEPS) || (output_time_step == (TIME_STEPS << 1));

always_ff @(posedge clk) begin
    if (rst) begin
        collision_counter <= 0;
        no_collision_counter <= 0;
        output_time_step <= 0;
        out_valid <= 0;
        output_not_relayed <= 0;
    end else begin
        // Snapshot the completed image's tally into the output counters. At an
        // interior image boundary the marker fires (collision_live pre-reset = the
        // finished image); the LAST image has no following marker, so snapshot when
        // the phase boundary triggers out_valid (collision_live is then the stable,
        // finished count). The two coincide for interior images, so the marker
        // branch wins and the live count is captured before its reset.
        if (second_layer_lif_new_image) begin
            collision_counter    <= collision_live;
            no_collision_counter <= no_collision_live;
        end else if (phase_boundary && output_not_relayed) begin
            collision_counter    <= collision_live;
            no_collision_counter <= no_collision_live;
        end
        output_time_step <= input_time_step + post_final_cycle_counter + second_layer_post_final_cycle_counter;
        if (phase_boundary && output_not_relayed) begin
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

endmodule
