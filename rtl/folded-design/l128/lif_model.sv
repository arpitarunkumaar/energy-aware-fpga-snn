`timescale 1ns/1ps

module lif_model
#(
    parameter integer k = 15,
    parameter integer urest = 0,
    parameter integer refractory_counter_max = 5
)
(
    input logic                 clk,
    input logic                 rst,
    input logic                 enable,
    input logic                 new_image,
    input logic signed [27:0]   input_current,
    input logic signed [29:0]   uth,
    output logic                spike
);

logic signed [27:0] internal_value;
logic [3:0] refractory_counter;
logic signed [31:0] membrane_next;
logic threshold_crossed;

assign membrane_next = internal_value - ((internal_value - urest) >>> k) + input_current;
// Signed compare: a mixed signed/unsigned test treated negative currents as large positives.
assign threshold_crossed = new_image
                         ? ($signed(input_current) > $signed(uth))
                         : ($signed(membrane_next) > $signed(uth));
// Combinational spike; membrane and refractory state update on the clock.
assign spike = !rst && enable && threshold_crossed && (new_image || refractory_counter == 0);

always_ff @(posedge clk) begin
    if (rst || new_image) begin
        refractory_counter <= 0;
        if (enable && !rst) begin
            if (threshold_crossed) begin
                refractory_counter <= 1;
                internal_value <= 0;
            end else begin
                internal_value <= input_current;
            end
        end else begin
            internal_value <= 0;
        end
    end else if (enable) begin
        if (refractory_counter == refractory_counter_max) begin
            refractory_counter <= 0;

            // Clamp the membrane after a threshold crossing.
            if (threshold_crossed) begin
                internal_value <= 0;
            end else begin
                internal_value <= membrane_next;
            end
        end else begin
            // A spike on new_image starts a new refractory period.
            if (threshold_crossed) begin
                internal_value <= 0;
                if (refractory_counter == 0) begin
                    refractory_counter <= 1;
                end else begin
                    refractory_counter <= refractory_counter + 1;
                end
            end else if (refractory_counter != 0) begin
                refractory_counter <= refractory_counter + 1;
                internal_value <= membrane_next;
            end else begin
                internal_value <= membrane_next;
            end
        end
    end
end

endmodule
