`timescale 1ns/1ps

// 128-lane synaptic reduction bank.
//
// Eight independent, fully-pipelined 16-input adder trees accept one fold per
// cycle.  Their results are reduced by three additional registered stages.
// Control metadata follows the arithmetic pipeline; no output-side cycle
// counter is used to reconstruct valid, timestep, phase, or fold boundaries.
module l128_adder_bank #(
    parameter int IN_WIDTH = 16,
    parameter int TIMESTEP_BITS = 5
) (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic                                      valid_in,
    input  logic                                      last_fold_in,
    input  logic                                      output_phase_in,
    input  logic                                      output_neuron_in,
    input  logic [TIMESTEP_BITS-1:0]                  timestep_in,
    input  logic [127:0]                              spike_in,
    input  logic signed [127:0][IN_WIDTH-1:0]         weight_in,

    output logic                                      valid_out,
    output logic                                      last_fold_out,
    output logic                                      output_phase_out,
    output logic                                      output_neuron_out,
    output logic [TIMESTEP_BITS-1:0]                  timestep_out,
    output logic signed [IN_WIDTH+7-1:0]              sum_out
);
    localparam int TREE_INPUTS = 16;
    localparam int TREE_STAGES = 4;
    localparam int TREE_WIDTH  = IN_WIDTH + TREE_STAGES;
    localparam int SUM_WIDTH   = IN_WIDTH + 7;

    logic signed [TREE_WIDTH-1:0] tree_sum [0:7];
    logic [7:0] tree_valid;

    genvar tree;
    generate
        for (tree = 0; tree < 8; tree = tree + 1) begin : trees
            cascaded_adder #(
                .NUM_INPUTS(TREE_INPUTS),
                .IN_WIDTH(IN_WIDTH),
                .OUT_WIDTH(TREE_WIDTH)
            ) adder (
                .clk(clk),
                .rst_n(~rst),
                .spike(spike_in[tree*TREE_INPUTS +: TREE_INPUTS]),
                .weight(weight_in[tree*TREE_INPUTS +: TREE_INPUTS]),
                .valid_in(valid_in),
                .out(tree_sum[tree]),
                .valid_out(tree_valid[tree])
            );
        end
    endgenerate

    // Metadata delay through the four registered levels in each 16-input
    // tree.  Stage TREE_STAGES is sampled together with tree_sum by reduce1.
    logic last_fold_pipe [0:TREE_STAGES];
    logic output_phase_pipe [0:TREE_STAGES];
    logic output_neuron_pipe [0:TREE_STAGES];
    logic [TIMESTEP_BITS-1:0] timestep_pipe [0:TREE_STAGES];

    integer meta_stage;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (meta_stage = 0; meta_stage <= TREE_STAGES;
                 meta_stage = meta_stage + 1) begin
                last_fold_pipe[meta_stage] <= 1'b0;
                output_phase_pipe[meta_stage] <= 1'b0;
                output_neuron_pipe[meta_stage] <= 1'b0;
                timestep_pipe[meta_stage] <= '0;
            end
        end else begin
            last_fold_pipe[0] <= last_fold_in;
            output_phase_pipe[0] <= output_phase_in;
            output_neuron_pipe[0] <= output_neuron_in;
            timestep_pipe[0] <= timestep_in;
            for (meta_stage = 1; meta_stage <= TREE_STAGES;
                 meta_stage = meta_stage + 1) begin
                last_fold_pipe[meta_stage] <= last_fold_pipe[meta_stage-1];
                output_phase_pipe[meta_stage] <= output_phase_pipe[meta_stage-1];
                output_neuron_pipe[meta_stage] <= output_neuron_pipe[meta_stage-1];
                timestep_pipe[meta_stage] <= timestep_pipe[meta_stage-1];
            end
        end
    end

    logic signed [TREE_WIDTH:0] reduce1 [0:3];
    logic signed [TREE_WIDTH+1:0] reduce2 [0:1];
    logic signed [SUM_WIDTH-1:0] reduce3;
    logic valid_reduce1, valid_reduce2, valid_reduce3;
    logic last_reduce1, last_reduce2, last_reduce3;
    logic phase_reduce1, phase_reduce2, phase_reduce3;
    logic neuron_reduce1, neuron_reduce2, neuron_reduce3;
    logic [TIMESTEP_BITS-1:0] tstep_reduce1, tstep_reduce2, tstep_reduce3;

    integer pair;
    always_ff @(posedge clk) begin
        for (pair = 0; pair < 4; pair = pair + 1) begin
            reduce1[pair] <=
                {tree_sum[2*pair][TREE_WIDTH-1], tree_sum[2*pair]} +
                {tree_sum[2*pair+1][TREE_WIDTH-1], tree_sum[2*pair+1]};
        end
        reduce2[0] <=
            {reduce1[0][TREE_WIDTH], reduce1[0]} +
            {reduce1[1][TREE_WIDTH], reduce1[1]};
        reduce2[1] <=
            {reduce1[2][TREE_WIDTH], reduce1[2]} +
            {reduce1[3][TREE_WIDTH], reduce1[3]};
        reduce3 <=
            {reduce2[0][TREE_WIDTH+1], reduce2[0]} +
            {reduce2[1][TREE_WIDTH+1], reduce2[1]};

        if (rst) begin
            valid_reduce1 <= 1'b0;
            valid_reduce2 <= 1'b0;
            valid_reduce3 <= 1'b0;
            last_reduce1 <= 1'b0;
            last_reduce2 <= 1'b0;
            last_reduce3 <= 1'b0;
            phase_reduce1 <= 1'b0;
            phase_reduce2 <= 1'b0;
            phase_reduce3 <= 1'b0;
            neuron_reduce1 <= 1'b0;
            neuron_reduce2 <= 1'b0;
            neuron_reduce3 <= 1'b0;
            tstep_reduce1 <= '0;
            tstep_reduce2 <= '0;
            tstep_reduce3 <= '0;
        end else begin
            valid_reduce1 <= tree_valid[0];
            valid_reduce2 <= valid_reduce1;
            valid_reduce3 <= valid_reduce2;
            last_reduce1 <= last_fold_pipe[TREE_STAGES];
            last_reduce2 <= last_reduce1;
            last_reduce3 <= last_reduce2;
            phase_reduce1 <= output_phase_pipe[TREE_STAGES];
            phase_reduce2 <= phase_reduce1;
            phase_reduce3 <= phase_reduce2;
            neuron_reduce1 <= output_neuron_pipe[TREE_STAGES];
            neuron_reduce2 <= neuron_reduce1;
            neuron_reduce3 <= neuron_reduce2;
            tstep_reduce1 <= timestep_pipe[TREE_STAGES];
            tstep_reduce2 <= tstep_reduce1;
            tstep_reduce3 <= tstep_reduce2;
        end
    end

    assign valid_out = valid_reduce3;
    assign last_fold_out = last_reduce3;
    assign output_phase_out = phase_reduce3;
    assign output_neuron_out = neuron_reduce3;
    assign timestep_out = tstep_reduce3;
    assign sum_out = reduce3;

endmodule
