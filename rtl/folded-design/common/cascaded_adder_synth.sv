`timescale 1ns/1ps

// Reduction tree with optional pipeline.
//
//   PIPE = 1  Register stage 0 and every tree stage. valid_out arrives
//             NUM_STAGES+1 cycles after valid_in.
//   PIPE = 0  Combinational; valid_out follows valid_in in the same cycle.
//             clk and rst_n are unused.

module cascaded_adder_synth #(
    parameter  int NUM_INPUTS = 4096,
    parameter  int NUM_STAGES = $clog2(NUM_INPUTS),
    parameter  int IN_WIDTH = 16,
    parameter  int OUT_WIDTH  = IN_WIDTH + NUM_STAGES,
    parameter  int PIPE = 1
) (
    input  logic                                       clk,
    input  logic                                       rst_n,
    input  logic [NUM_INPUTS-1:0]                      spike,
    input  logic signed [NUM_INPUTS-1:0][IN_WIDTH-1:0] weight,
    input  logic                                       valid_in,
    output logic signed [OUT_WIDTH-1:0]                out,
    output logic                                       valid_out
);
    // Stage 0 holds the spike-gated weights at native width.
    logic signed [IN_WIDTH-1:0] stage0_reg [0:NUM_INPUTS-1];

    // Spike-gate each weight: pass the weight or zero.
    generate
        for (genvar k = 0; k < NUM_INPUTS; k++) begin : gate_mux
            if (PIPE != 0) begin : piped
                always_ff @(posedge clk)
                    stage0_reg[k] <= spike[k] ? weight[k] : '0;
            end else begin : comb
                assign stage0_reg[k] = spike[k] ? weight[k] : '0;
            end
        end
    endgenerate

    // Stage s holds NUM_INPUTS>>s sums, each IN_WIDTH+s bits wide.
    generate
        for (genvar s = 1; s <= NUM_STAGES; s++) begin : stage_gen
            localparam int W = IN_WIDTH + s;
            localparam int N = NUM_INPUTS >> s;
            logic signed [W-1:0] reg_arr [0:N-1];

            for (genvar k = 0; k < N; k++) begin : add_pair
                if (s == 1) begin : from_stage0
                    if (PIPE != 0) begin : piped
                        always_ff @(posedge clk)
                            reg_arr[k] <= stage0_reg[2*k] + stage0_reg[2*k+1];
                    end else begin : comb
                        assign reg_arr[k] = stage0_reg[2*k] + stage0_reg[2*k+1];
                    end
                end else begin : from_prev
                    if (PIPE != 0) begin : piped
                        always_ff @(posedge clk)
                            reg_arr[k] <= stage_gen[s-1].reg_arr[2*k]
                                        + stage_gen[s-1].reg_arr[2*k+1];
                    end else begin : comb
                        assign reg_arr[k] = stage_gen[s-1].reg_arr[2*k]
                                          + stage_gen[s-1].reg_arr[2*k+1];
                    end
                end
            end
        end
    endgenerate

    assign out = stage_gen[NUM_STAGES].reg_arr[0];

    // valid_out is valid_in delayed by NUM_STAGES+1 cycles when PIPE=1,
    // or combinational when PIPE=0.
    generate
        if (PIPE != 0) begin : valid_track
            logic valid_pipe [0:NUM_STAGES];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) valid_pipe[0] <= 1'b0;
                else        valid_pipe[0] <= valid_in;
            end

            for (genvar s = 1; s <= NUM_STAGES; s++) begin : vp
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) valid_pipe[s] <= 1'b0;
                    else        valid_pipe[s] <= valid_pipe[s-1];
                end
            end

            assign valid_out = valid_pipe[NUM_STAGES];
        end else begin : valid_comb
            assign valid_out = valid_in;
        end
    endgenerate

endmodule
