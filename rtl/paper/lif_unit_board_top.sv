`timescale 1ns/1ps

// Standalone LIF with BUFG, package I/O, and registered boundary pins
// so I/O timing is FF-to-FF.
module lif_unit_board_top (
    input  logic                 clk_in,
    input  logic                 rst,
    input  logic                 enable,
    input  logic                 new_image,
    input  logic signed [27:0]   input_current,
    output logic                 spike
);
    logic clk;
    logic rst_r, enable_r, new_image_r;
    logic signed [27:0] input_current_r;
    logic spike_i;

    BUFG bufg_clk (
        .I(clk_in),
        .O(clk)
    );

    always_ff @(posedge clk) begin
        rst_r           <= rst;
        enable_r        <= enable;
        new_image_r     <= new_image;
        input_current_r <= input_current;
        spike           <= spike_i;
    end

    lif_model #(
        .k(15),
        .uth(100 << 15),
        .urest(0),
        .refractory_counter_max(5)
    ) u_lif (
        .clk(clk),
        .rst(rst_r),
        .enable(enable_r),
        .new_image(new_image_r),
        .input_current(input_current_r),
        .spike(spike_i)
    );
endmodule
