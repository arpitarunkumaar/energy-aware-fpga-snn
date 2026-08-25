`timescale 1ns/1ps

`ifndef CLK_PERIOD_NS
`define CLK_PERIOD_NS 10.0
`endif
`ifndef ACTIVITY_PATH
`define ACTIVITY_PATH "lif_currents.hex"
`endif

module tb_lif_unit_io_power;
    localparam real PERIOD_NS   = `CLK_PERIOD_NS;
    localparam int  TIME_STEPS  = 25;
    localparam int  NUM_VECTORS = 400;
    localparam int  NUM_PASSES  = 10;

    logic clk_in = 1'b0;
    logic rst = 1'b1;
    logic enable = 1'b0;
    logic new_image = 1'b0;
    logic signed [27:0] input_current = '0;
    logic spike;

    logic signed [27:0] stimulus [0:NUM_VECTORS-1];

    lif_unit_io_top dut (
        .clk_in(clk_in),
        .rst(rst),
        .enable(enable),
        .new_image(new_image),
        .input_current(input_current),
        .spike(spike)
    );

    always #(PERIOD_NS/2.0) clk_in = ~clk_in;

    integer pass_idx;
    integer vec_idx;
    initial begin
        $readmemh(`ACTIVITY_PATH, stimulus);

        repeat (5) @(negedge clk_in);
        rst = 1'b0;

        for (pass_idx = 0; pass_idx < NUM_PASSES; pass_idx = pass_idx + 1) begin
            for (vec_idx = 0; vec_idx < NUM_VECTORS; vec_idx = vec_idx + 1) begin
                input_current = stimulus[vec_idx];
                enable        = 1'b1;
                new_image     = (vec_idx % TIME_STEPS == 0);
                @(negedge clk_in);
            end
        end

        enable        = 1'b0;
        new_image     = 1'b0;
        input_current = '0;
        repeat (40) @(negedge clk_in);
        $finish;
    end
endmodule
