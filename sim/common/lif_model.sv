`timescale 1 ps / 1 ps

module lif_model
#(
    parameter integer k = 15,
    parameter integer uth = 100 << 15,
    parameter integer urest = 0,
    parameter integer refractory_counter_max = 5
)
(
    input logic             clk,
    input logic             rst,
    input logic             enable,
    input logic             new_image,
    input logic [27:0]      input_current,
    output logic            spike
);

logic signed [27:0] internal_value;
logic [3:0] refractory_counter;

always_ff @(posedge clk) begin
    if (rst || new_image) begin
        spike <= 0;
        refractory_counter <= 0;
        if (enable && !rst) begin
            internal_value <= input_current;
        end else begin
            internal_value <= 0;
        end
    end else if (enable) begin
        if (refractory_counter == refractory_counter_max - 1) begin
            spike <= 0; 
            refractory_counter <= 0;
            internal_value <= 0;
        end else begin // for each timestep
            if (internal_value >= uth) begin
                spike <= 1; // spike is high for 1 cycle
                internal_value <= 0;
                refractory_counter <= 1;
            end else if (refractory_counter != 0) begin
                spike <= 0;
                refractory_counter <= refractory_counter + 1;
            end else begin // refactory ctr != 0 and internal_value < uth
                spike <= 0;
                internal_value <= internal_value - ((internal_value - urest) >>> k) + input_current;
            end
        end
    end else begin
        spike <= 0;
    end
end

endmodule

//Add in biases
//Put placeholders for Layer 1, Layer 2 thresholds
//Make sure right-shifts are arithmetic and not logical.
//Add logic for a double residual.