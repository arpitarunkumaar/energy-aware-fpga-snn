`timescale 1ns/1ps

// Folded 4096-512-2 SNN core.
//
// The schedule is neuron-major:
//   1. Buffer all TIME_STEPS input-spike frames in BRAM.
//   2. Stream one 4096x16-bit hidden-neuron weight row into BRAM.
//   3. Reuse that row for all TIME_STEPS dot products.
//   4. Step one reused hidden LIF and accumulate both output currents.
//
// Two weight-row buffers allow row n+1 to load while row n computes.  This
// module deliberately exposes a transport-neutral stream; DDR, AXI/DataMover,
// FrontPanel, clock-domain crossing, and board-shell logic are not part of the
// synthesis top.
module folded_bram_predictor #(
    parameter int NUM_INPUTS          = 4096,
    parameter int NUM_HIDDEN          = 512,
    parameter int TIME_STEPS          = 25,
    parameter int LANES               = 16,
    parameter int IN_WIDTH            = 16,
    parameter int WEIGHT_STREAM_WIDTH = 64,
    parameter int ROW_BUFFERS         = 2,
    parameter int ACC_WIDTH           = IN_WIDTH + $clog2(NUM_INPUTS),
    parameter int FIRST_LAYER_K       = 15,
    parameter int SECOND_LAYER_K      = 15,
    parameter int FIRST_LAYER_THRESHOLD  = 8938,
    parameter int SECOND_LAYER_THRESHOLD = 6775,
    parameter string LAYER2_WEIGHTS_PATH = "../sw/model_params/layer2_weights.hex",
    parameter string LAYER1_BIASES_PATH  = "../sw/model_params/layer1_biases.hex",
    parameter string LAYER2_BIASES_PATH  = "../sw/model_params/layer2_biases.hex"
) (
    input  logic                                      clk,
    input  logic                                      rst,

    input  logic                                      start_image,
    output logic                                      image_ready,

    // Timestep-major, then fold-major: TIME_STEPS * (NUM_INPUTS/LANES)
    // accepted words constitute one complete image.
    input  logic                                      spike_valid,
    output logic                                      spike_ready,
    input  logic [LANES-1:0]                          spike_data,

    // Exactly one request and NUM_INPUTS*IN_WIDTH/WEIGHT_STREAM_WIDTH
    // accepted stream beats per hidden neuron.  Weight 0 is in the least
    // significant IN_WIDTH bits of the first beat.
    output logic                                      row_request_valid,
    input  logic                                      row_request_ready,
    output logic [$clog2(NUM_HIDDEN)-1:0]             row_request_neuron,
    input  logic                                      weight_valid,
    output logic                                      weight_ready,
    input  logic [WEIGHT_STREAM_WIDTH-1:0]            weight_data,
    input  logic                                      weight_last,

    output logic                                      inference_valid,
    output logic [4:0]                                collision_counter,
    output logic [4:0]                                no_collision_counter,
    output logic                                      classification,
    output logic                                      protocol_error
);
    localparam int FOLDS                 = NUM_INPUTS / LANES;
    localparam int ROW_WIDTH             = LANES * IN_WIDTH;
    localparam int WEIGHT_BEATS_PER_FOLD = ROW_WIDTH / WEIGHT_STREAM_WIDTH;
    localparam int WEIGHT_BEATS_PER_ROW  = NUM_INPUTS * IN_WIDTH / WEIGHT_STREAM_WIDTH;
    localparam int SPIKE_WORDS           = TIME_STEPS * FOLDS;
    localparam int HIDDEN_BITS           = $clog2(NUM_HIDDEN);
    localparam int FOLD_BITS             = (FOLDS <= 1) ? 1 : $clog2(FOLDS);
    localparam int STEP_BITS             = (TIME_STEPS <= 1) ? 1 : $clog2(TIME_STEPS);
    localparam int SPIKE_ADDR_BITS       = (SPIKE_WORDS <= 1) ? 1 : $clog2(SPIKE_WORDS);
    localparam int BEAT_BITS             = (WEIGHT_BEATS_PER_FOLD <= 1) ? 1 : $clog2(WEIGHT_BEATS_PER_FOLD);
    localparam int WEIGHT_COUNT_BITS     = (WEIGHT_BEATS_PER_ROW <= 1) ? 1 : $clog2(WEIGHT_BEATS_PER_ROW);
    localparam int RESULT_COUNT_BITS     = (SPIKE_WORDS <= 1) ? 1 : $clog2(SPIKE_WORDS);
    localparam int TREE_SUM_WIDTH        = IN_WIDTH + $clog2(LANES);

    initial begin
        if (NUM_INPUTS % LANES != 0)
            $error("NUM_INPUTS must be divisible by LANES");
        if ((1 << $clog2(LANES)) != LANES)
            $error("LANES must be a power of two");
        if (ROW_WIDTH % WEIGHT_STREAM_WIDTH != 0)
            $error("LANES*IN_WIDTH must be divisible by WEIGHT_STREAM_WIDTH");
        if (ROW_BUFFERS != 1 && ROW_BUFFERS != 2)
            $error("ROW_BUFFERS must be 1 or 2");
    end

    // ---------------------------------------------------------------------
    // Input spikes: all timesteps are resident before weight processing.
    // A registered read gives the adder a clean BRAM-to-logic boundary.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *) logic [LANES-1:0] spike_mem [0:SPIKE_WORDS-1];
    logic [SPIKE_ADDR_BITS-1:0] spike_write_addr;
    logic [LANES-1:0] spike_row_q;

    // ---------------------------------------------------------------------
    // Ping-pong weight-row BRAMs.  Each logical buffer is
    // FOLDS x (LANES*16) = 65,536 bits; physical BRAM count grows with the
    // required read width, which the synthesis reports expose explicitly.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *) logic [ROW_WIDTH-1:0] weight_rows_0 [0:FOLDS-1];
    logic [ROW_WIDTH-1:0] weight_row_0_q;

    generate
        if (ROW_BUFFERS == 2) begin : second_row_buffer
            (* ram_style = "block" *) logic [ROW_WIDTH-1:0] weight_rows_1 [0:FOLDS-1];
            logic [ROW_WIDTH-1:0] weight_row_1_q;
        end
    endgenerate

    logic [ROW_WIDTH-1:0] weight_pack;
    logic [ROW_WIDTH-1:0] weight_pack_next;
    logic [FOLD_BITS-1:0] load_fold;
    logic [BEAT_BITS-1:0] load_beat;
    logic [WEIGHT_COUNT_BITS-1:0] weight_count;
    logic load_buffer_sel;
    logic weight_fire;
    logic weight_word_write;

    always_comb begin
        weight_pack_next = weight_pack;
        weight_pack_next[load_beat*WEIGHT_STREAM_WIDTH +: WEIGHT_STREAM_WIDTH] = weight_data;
    end

    assign weight_fire      = weight_valid && weight_ready;
    assign weight_word_write = weight_fire && (load_beat == WEIGHT_BEATS_PER_FOLD-1);

    // ---------------------------------------------------------------------
    // Small on-chip parameter memories.  They are sampled when a buffered row
    // is selected, long before the corresponding LIF step consumes them.
    // ---------------------------------------------------------------------
    (* rom_style = "block" *) logic signed [IN_WIDTH-1:0] layer1_biases [0:NUM_HIDDEN-1];
    (* rom_style = "block" *) logic signed [IN_WIDTH-1:0] layer2_weights [0:2*NUM_HIDDEN-1];
    logic signed [IN_WIDTH-1:0] layer2_biases [0:1];

    initial begin
        $readmemh(LAYER1_BIASES_PATH, layer1_biases);
        $readmemh(LAYER2_WEIGHTS_PATH, layer2_weights);
        $readmemh(LAYER2_BIASES_PATH, layer2_biases);
    end

    logic signed [IN_WIDTH-1:0] l1_bias_q;
    logic signed [IN_WIDTH-1:0] l2_weight_no_collision_q;
    logic signed [IN_WIDTH-1:0] l2_weight_collision_q;

    // ---------------------------------------------------------------------
    // Independent row loader.  It may run concurrently with compute when the
    // other ping-pong buffer is free.
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {L_IDLE, L_REQUEST, L_RECEIVE} loader_state_t;
    loader_state_t loader_state;
    logic [HIDDEN_BITS:0] load_neuron;
    logic image_active;
    logic [1:0] buffer_valid;
    logic [HIDDEN_BITS-1:0] buffer_neuron [0:1];
    logic active_buffer;
    logic compute_holds_row;

    assign load_buffer_sel = (ROW_BUFFERS == 2) ? load_neuron[0] : 1'b0;
    assign row_request_valid = (loader_state == L_REQUEST);
    assign row_request_neuron = load_neuron[HIDDEN_BITS-1:0];
    assign weight_ready = (loader_state == L_RECEIVE);

    // ---------------------------------------------------------------------
    // Compute issue/read/result pipeline.
    // ---------------------------------------------------------------------
    typedef enum logic [3:0] {
        C_IDLE,
        C_LOAD_SPIKES,
        C_WAIT_ROW,
        C_PREP_COMPUTE,
        C_COMPUTE,
        C_HIDDEN_LIF,
        C_OUTPUT_LIF,
        C_EMIT
    } compute_state_t;
    compute_state_t compute_state;

    logic [HIDDEN_BITS-1:0] compute_neuron;
    logic [STEP_BITS-1:0] issue_tstep;
    logic [FOLD_BITS-1:0] issue_fold;
    logic [STEP_BITS-1:0] lif_tstep;
    logic issuing;
    logic read_valid;
    logic [STEP_BITS-1:0] read_tstep;
    logic [RESULT_COUNT_BITS-1:0] result_count;
    logic compute_issue;
    logic [SPIKE_ADDR_BITS-1:0] compute_spike_addr;
    logic [ROW_WIDTH-1:0] active_weight_row_q;

    assign compute_holds_row = (compute_state == C_PREP_COMPUTE)
                            || (compute_state == C_COMPUTE);
    assign compute_issue = (compute_state == C_COMPUTE) && issuing;
    assign compute_spike_addr = SPIKE_ADDR_BITS'(issue_tstep * FOLDS + issue_fold);

    generate
        if (ROW_BUFFERS == 2) begin : select_second_row
            assign active_weight_row_q = active_buffer
                                       ? second_row_buffer.weight_row_1_q
                                       : weight_row_0_q;
        end else begin : select_only_row
            assign active_weight_row_q = weight_row_0_q;
        end
    endgenerate

    // BRAM write/read processes.  Writes target only the inactive row buffer;
    // reads target only the active buffer.
    always_ff @(posedge clk) begin
        if (spike_valid && spike_ready)
            spike_mem[spike_write_addr] <= spike_data;
        if (compute_issue)
            spike_row_q <= spike_mem[compute_spike_addr];

        if (weight_word_write && !load_buffer_sel)
            weight_rows_0[load_fold] <= weight_pack_next;
        if (compute_issue && !active_buffer)
            weight_row_0_q <= weight_rows_0[issue_fold];
    end

    generate
        if (ROW_BUFFERS == 2) begin : second_row_ports
            always_ff @(posedge clk) begin
                if (weight_word_write && load_buffer_sel)
                    second_row_buffer.weight_rows_1[load_fold] <= weight_pack_next;
                if (compute_issue && active_buffer)
                    second_row_buffer.weight_row_1_q <= second_row_buffer.weight_rows_1[issue_fold];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid <= 1'b0;
            read_tstep <= '0;
        end else begin
            read_valid <= compute_issue;
            if (compute_issue)
                read_tstep <= issue_tstep;
        end
    end

    logic signed [TREE_SUM_WIDTH-1:0] folded_sum;
    logic signed [ACC_WIDTH-1:0] folded_sum_ext;
    logic signed [LANES-1:0][IN_WIDTH-1:0] active_weights;

    assign active_weights = active_weight_row_q;
    assign folded_sum_ext = {{(ACC_WIDTH-TREE_SUM_WIDTH){folded_sum[TREE_SUM_WIDTH-1]}}, folded_sum};

    cascaded_adder_synth #(
        .NUM_INPUTS(LANES),
        .IN_WIDTH(IN_WIDTH),
        .OUT_WIDTH(TREE_SUM_WIDTH),
        .PIPE(0)
    ) folded_adder (
        .clk(clk),
        .rst_n(~rst),
        .spike(spike_row_q),
        .weight(active_weights),
        .valid_in(read_valid),
        .out(folded_sum),
        .valid_out()
    );

    logic signed [ACC_WIDTH-1:0] partial [0:TIME_STEPS-1];
    logic signed [ACC_WIDTH-1:0] l2_no_collision [0:TIME_STEPS-1];
    logic signed [ACC_WIDTH-1:0] l2_collision [0:TIME_STEPS-1];

    // ---------------------------------------------------------------------
    // One hidden LIF and two output LIFs.  new_image is asserted at timestep
    // zero to reset the reused state at every hidden neuron/output sequence.
    // ---------------------------------------------------------------------
    logic l1_enable;
    logic l1_new_image;
    logic signed [ACC_WIDTH-1:0] l1_current;
    logic l1_spike;
    logic output_enable;
    logic output_new_image;
    logic no_collision_spike;
    logic collision_spike;

    assign l1_enable = (compute_state == C_HIDDEN_LIF);
    assign l1_new_image = l1_enable && (lif_tstep == 0);
    assign l1_current = partial[lif_tstep]
                      + {{(ACC_WIDTH-IN_WIDTH){l1_bias_q[IN_WIDTH-1]}}, l1_bias_q};

    lif_model #(
        .k(FIRST_LAYER_K),
        .uth(FIRST_LAYER_THRESHOLD)
    ) hidden_lif (
        .clk(clk),
        .rst(rst),
        .enable(l1_enable),
        .new_image(l1_new_image),
        .input_current(l1_current),
        .spike(l1_spike)
    );

    assign output_enable = (compute_state == C_OUTPUT_LIF);
    assign output_new_image = output_enable && (lif_tstep == 0);

    lif_model #(
        .k(SECOND_LAYER_K),
        .uth(SECOND_LAYER_THRESHOLD)
    ) output_no_collision_lif (
        .clk(clk),
        .rst(rst),
        .enable(output_enable),
        .new_image(output_new_image),
        .input_current(l2_no_collision[lif_tstep]),
        .spike(no_collision_spike)
    );

    lif_model #(
        .k(SECOND_LAYER_K),
        .uth(SECOND_LAYER_THRESHOLD)
    ) output_collision_lif (
        .clk(clk),
        .rst(rst),
        .enable(output_enable),
        .new_image(output_new_image),
        .input_current(l2_collision[lif_tstep]),
        .spike(collision_spike)
    );

    assign image_ready = (compute_state == C_IDLE);
    assign spike_ready = (compute_state == C_LOAD_SPIKES);
    assign classification = (collision_counter > no_collision_counter);

    integer t;
    always_ff @(posedge clk) begin
        if (rst) begin
            compute_state <= C_IDLE;
            loader_state <= L_IDLE;
            image_active <= 1'b0;
            spike_write_addr <= '0;
            load_neuron <= '0;
            load_fold <= '0;
            load_beat <= '0;
            weight_count <= '0;
            weight_pack <= '0;
            buffer_valid <= '0;
            buffer_neuron[0] <= '0;
            buffer_neuron[1] <= '0;
            active_buffer <= 1'b0;
            compute_neuron <= '0;
            issue_tstep <= '0;
            issue_fold <= '0;
            lif_tstep <= '0;
            issuing <= 1'b0;
            result_count <= '0;
            l1_bias_q <= '0;
            l2_weight_no_collision_q <= '0;
            l2_weight_collision_q <= '0;
            inference_valid <= 1'b0;
            collision_counter <= '0;
            no_collision_counter <= '0;
            protocol_error <= 1'b0;
            for (t = 0; t < TIME_STEPS; t = t + 1) begin
                partial[t] <= '0;
                l2_no_collision[t] <= '0;
                l2_collision[t] <= '0;
            end
        end else begin
            inference_valid <= 1'b0;

            // -------------------------------------------------------------
            // Row loader: request and receive rows independently of compute.
            // -------------------------------------------------------------
            case (loader_state)
                L_IDLE: begin
                    if (image_active && (load_neuron < NUM_HIDDEN)
                            && !buffer_valid[load_buffer_sel]
                            && !(compute_holds_row && (active_buffer == load_buffer_sel)))
                        loader_state <= L_REQUEST;
                end

                L_REQUEST: begin
                    if (row_request_ready) begin
                        load_fold <= '0;
                        load_beat <= '0;
                        weight_count <= '0;
                        weight_pack <= '0;
                        loader_state <= L_RECEIVE;
                    end
                end

                L_RECEIVE: begin
                    if (weight_fire) begin
                        if (weight_last != (weight_count == WEIGHT_BEATS_PER_ROW-1))
                            protocol_error <= 1'b1;

                        if (load_beat == WEIGHT_BEATS_PER_FOLD-1) begin
                            load_beat <= '0;
                            weight_pack <= '0;
                            if (load_fold != FOLDS-1)
                                load_fold <= load_fold + 1'b1;
                        end else begin
                            load_beat <= load_beat + 1'b1;
                            weight_pack <= weight_pack_next;
                        end

                        if (weight_count == WEIGHT_BEATS_PER_ROW-1) begin
                            buffer_valid[load_buffer_sel] <= 1'b1;
                            buffer_neuron[load_buffer_sel] <= load_neuron[HIDDEN_BITS-1:0];
                            load_neuron <= load_neuron + 1'b1;
                            loader_state <= L_IDLE;
                        end else begin
                            weight_count <= weight_count + 1'b1;
                        end
                    end
                end

                default: loader_state <= L_IDLE;
            endcase

            // -------------------------------------------------------------
            // Compute and LIF sequencer.
            // -------------------------------------------------------------
            case (compute_state)
                C_IDLE: begin
                    if (start_image) begin
                        compute_state <= C_LOAD_SPIKES;
                        loader_state <= L_IDLE;
                        image_active <= 1'b0;
                        spike_write_addr <= '0;
                        load_neuron <= '0;
                        buffer_valid <= '0;
                        compute_neuron <= '0;
                        collision_counter <= '0;
                        no_collision_counter <= '0;
                        protocol_error <= 1'b0;
                    end
                end

                C_LOAD_SPIKES: begin
                    if (spike_valid && spike_ready) begin
                        if (spike_write_addr == SPIKE_WORDS-1) begin
                            spike_write_addr <= '0;
                            image_active <= 1'b1;
                            compute_state <= C_WAIT_ROW;
                            for (t = 0; t < TIME_STEPS; t = t + 1) begin
                                l2_no_collision[t] <= {{(ACC_WIDTH-IN_WIDTH){layer2_biases[0][IN_WIDTH-1]}}, layer2_biases[0]};
                                l2_collision[t] <= {{(ACC_WIDTH-IN_WIDTH){layer2_biases[1][IN_WIDTH-1]}}, layer2_biases[1]};
                            end
                        end else begin
                            spike_write_addr <= spike_write_addr + 1'b1;
                        end
                    end
                end

                C_WAIT_ROW: begin
                    if (buffer_valid[(ROW_BUFFERS == 2) ? compute_neuron[0] : 1'b0]
                            && buffer_neuron[(ROW_BUFFERS == 2) ? compute_neuron[0] : 1'b0]
                               == compute_neuron) begin
                        active_buffer <= (ROW_BUFFERS == 2) ? compute_neuron[0] : 1'b0;
                        l1_bias_q <= layer1_biases[compute_neuron];
                        l2_weight_no_collision_q <= layer2_weights[compute_neuron];
                        l2_weight_collision_q <= layer2_weights[NUM_HIDDEN + compute_neuron];
                        for (t = 0; t < TIME_STEPS; t = t + 1)
                            partial[t] <= '0;
                        compute_state <= C_PREP_COMPUTE;
                    end
                end

                C_PREP_COMPUTE: begin
                    issue_tstep <= '0;
                    issue_fold <= '0;
                    result_count <= '0;
                    issuing <= 1'b1;
                    compute_state <= C_COMPUTE;
                end

                C_COMPUTE: begin
                    if (issuing) begin
                        if (issue_fold == FOLDS-1) begin
                            issue_fold <= '0;
                            if (issue_tstep == TIME_STEPS-1)
                                issuing <= 1'b0;
                            else
                                issue_tstep <= issue_tstep + 1'b1;
                        end else begin
                            issue_fold <= issue_fold + 1'b1;
                        end
                    end

                    if (read_valid) begin
                        partial[read_tstep] <= partial[read_tstep] + folded_sum_ext;
                        if (result_count == SPIKE_WORDS-1) begin
                            buffer_valid[active_buffer] <= 1'b0;
                            result_count <= '0;
                            lif_tstep <= '0;
                            compute_state <= C_HIDDEN_LIF;
                        end else begin
                            result_count <= result_count + 1'b1;
                        end
                    end
                end

                C_HIDDEN_LIF: begin
                    if (l1_spike) begin
                        l2_no_collision[lif_tstep] <= l2_no_collision[lif_tstep]
                            + {{(ACC_WIDTH-IN_WIDTH){l2_weight_no_collision_q[IN_WIDTH-1]}}, l2_weight_no_collision_q};
                        l2_collision[lif_tstep] <= l2_collision[lif_tstep]
                            + {{(ACC_WIDTH-IN_WIDTH){l2_weight_collision_q[IN_WIDTH-1]}}, l2_weight_collision_q};
                    end

                    if (lif_tstep == TIME_STEPS-1) begin
                        lif_tstep <= '0;
                        if (compute_neuron == NUM_HIDDEN-1) begin
                            image_active <= 1'b0;
                            compute_state <= C_OUTPUT_LIF;
                        end else begin
                            compute_neuron <= compute_neuron + 1'b1;
                            compute_state <= C_WAIT_ROW;
                        end
                    end else begin
                        lif_tstep <= lif_tstep + 1'b1;
                    end
                end

                C_OUTPUT_LIF: begin
                    if (no_collision_spike)
                        no_collision_counter <= no_collision_counter + 1'b1;
                    if (collision_spike)
                        collision_counter <= collision_counter + 1'b1;

                    if (lif_tstep == TIME_STEPS-1) begin
                        lif_tstep <= '0;
                        compute_state <= C_EMIT;
                    end else begin
                        lif_tstep <= lif_tstep + 1'b1;
                    end
                end

                C_EMIT: begin
                    inference_valid <= 1'b1;
                    compute_state <= C_IDLE;
                end

                default: compute_state <= C_IDLE;
            endcase
        end
    end

endmodule
