`timescale 1ns/1ps

module lif_model_tb;
    localparam integer K = 2;
    localparam integer UTH = 20;
    localparam integer UREST = 5;
    localparam integer REFRACTORY_MAX = 5;


    localparam integer RESET_VALUE = 0;

    localparam integer SUBTHR_CUR = 1;
    localparam integer FIRE_CUR   = UTH;    

    logic        clk;
    logic        rst;
    logic        enable;
    logic [27:0] input_current;
    logic        spike;

    integer errors = 0;
    integer checks = 0;

    lif_model #(
        .k(K),
        .uth(UTH),
        .urest(UREST),
        .refractory_counter_max(REFRACTORY_MAX)
    ) dut (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .input_current(input_current),
        .spike(spike)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end


    task automatic cycle(input [27:0] cur, input logic en, input logic r);
        input_current = cur;
        enable        = en;
        rst           = r;
        @(posedge clk);
        #1;
    endtask

    task automatic check(input logic cond, input string msg);
        checks = checks + 1;
        if (cond !== 1'b1) begin
            errors = errors + 1;
            $display("  [FAIL] @%0t: %s", $time, msg);
        end else begin
            $display("  [pass] %s", msg);
        end
    endtask

    task automatic do_reset();
        // Hold reset for a couple of enabled cycles.
        cycle(28'd0, 1'b1, 1'b1);
        cycle(28'd0, 1'b1, 1'b1);
    endtask

    initial begin
        $dumpfile("lif_model_tb.vcd");
        $dumpvars(0, lif_model_tb);

        input_current = '0;
        enable        = 0;
        rst           = 0;

        // -----------------------------------------------------------------
        // TEST 1 - Reset returns neuron to its reset state - 0
        // -----------------------------------------------------------------
        $display("\n=== TEST 1: reset to reset state ===");
        do_reset();
        check(spike === 1'b0,
              "reset: spike is 0");
        check(dut.refractory_counter === '0,
              "reset: refractory_counter cleared to 0");
        check(dut.internal_value === RESET_VALUE[27:0],
              $sformatf("reset: internal_value == %0d, got %0d",
                        RESET_VALUE, dut.internal_value));
        // Spike must stay low for the whole time reset is held.
        repeat (3) begin
            cycle(28'd1000, 1'b1, 1'b1);
            check(spike === 1'b0, "reset held: spike stays 0");
            check(dut.internal_value === RESET_VALUE[27:0],
                  "reset held: internal_value stays at reset value");
        end

        // -----------------------------------------------------------------
        // TEST 2 - enable == 0 freezes the neuron
        // -----------------------------------------------------------------
        $display("\n=== TEST 2: enable=0 -> no spike, no accumulation ===");
        do_reset();
        begin
            logic [27:0] frozen;
            cycle(28'd0, 1'b0, 1'b0);          // first disabled cycle
            frozen = dut.internal_value;       // capture frozen membrane value
            repeat (6) begin
                // Drive a large current while disabled; nothing should move.
                cycle(28'd5000, 1'b0, 1'b0);
                check(spike === 1'b0,
                      "enable=0: spike stays 0");
                check(dut.internal_value === frozen,
                      "enable=0: internal_value does not accumulate");
            end
        end

        $display("\n=== TEST 3a: stays below uth -> no spike ===");
        do_reset();
        repeat (15) begin
            cycle(SUBTHR_CUR[27:0], 1'b1, 1'b0);
            check(spike === 1'b0, "below threshold: no spike");
            check(dut.internal_value < UTH[27:0],
                  "below threshold: membrane stays under uth");
        end

        // TODO: need to add internal_value >= uth -> spike = 1

        $display("\n==================================================");
        $display("LIF testbench complete: %0d checks, %0d failures",
                 checks, errors);
        if (errors == 0)
            $display("RESULT: ALL TESTS PASSED");
        else
            $display("RESULT: %0d CHECK(S) FAILED", errors);
        $display("==================================================\n");
        $finish;
    end


    initial begin
        #100000;
        $display("[FAIL] @%0t: watchdog timeout", $time);
        $finish;
    end

endmodule
