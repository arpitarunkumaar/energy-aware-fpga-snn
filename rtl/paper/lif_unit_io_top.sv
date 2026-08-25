`timescale 1ns/1ps

// Standalone LIF with a BUFG clock and package I/O (not out-of-context).
module lif_unit_io_top (
    input  logic                 clk_in,
    input  logic                 rst,
    input  logic                 enable,
    input  logic                 new_image,
    input  logic signed [27:0]   input_current,
    output logic                 spike
);
    logic clk;

    // Global clock buffer for board-style power and timing.
    BUFG bufg_clk (
        .I(clk_in),
        .O(clk)
    );

    lif_model #(
        .k(15),
        .uth(100 << 15),
        .urest(0),
        .refractory_counter_max(5)
    ) u_lif (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .new_image(new_image),
        .input_current(input_current),
        .spike(spike)
    );
endmodule
