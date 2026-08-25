`timescale 1ns/1ps

// Only NUM_INPUTS oarameter need be passed -- NUM_STAGES and OUT_WIDTH are derived from it and IN_WIDTH is constant
module cascaded_adder #(
    parameter  int NUM_INPUTS = 4096,
    parameter  int NUM_STAGES = $clog2(NUM_INPUTS),     // Corresponds to number of tree layers
    parameter  int IN_WIDTH = 16,
    parameter  int OUT_WIDTH  = IN_WIDTH + NUM_STAGES
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

    // Keeps track of cycles since tb asserted valid_in 
    // (this module will assert valid_out NUM_STAGES cycles after valid_in)
    logic valid_pipe [0:NUM_STAGES];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_pipe[0] <= 1'b0;
        else        valid_pipe[0] <= valid_in;
    end

    // Handle MUX of input pixels (spike), either passing weight or 0 based on its value
    generate
        for (genvar k = 0; k < NUM_INPUTS; k++) begin : gate_mux
            always_ff @(posedge clk)
                stage0_reg[k] <= spike[k] ? weight[k] : '0;
        end
    endgenerate

    // Handle tree's add operations. Each stage declares its own right-sized register
    // array: stage s has (NUM_INPUTS >> s) elements, each (IN_WIDTH + s) bits wide.
    generate
        for (genvar s = 1; s <= NUM_STAGES; s++) begin : stage_gen
            localparam int W = IN_WIDTH + s;
            localparam int N = NUM_INPUTS >> s;
            logic signed [W-1:0] reg_arr [0:N-1];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) valid_pipe[s] <= 1'b0;
                else        valid_pipe[s] <= valid_pipe[s-1];
            end

            for (genvar k = 0; k < N; k++) begin : add_pair
                if (s == 1) begin : from_stage0
                    always_ff @(posedge clk)
                        reg_arr[k] <= stage0_reg[2*k] + stage0_reg[2*k+1];
                end else begin : from_prev
                    always_ff @(posedge clk)
                        reg_arr[k] <= stage_gen[s-1].reg_arr[2*k]
                                    + stage_gen[s-1].reg_arr[2*k+1];
                end
            end
        end
    endgenerate

    assign out       = stage_gen[NUM_STAGES].reg_arr[0];
    assign valid_out = valid_pipe[NUM_STAGES];

endmodule
