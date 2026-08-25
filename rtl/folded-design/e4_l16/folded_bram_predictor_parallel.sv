`timescale 1ns/1ps

// K-way neuron-parallel variant of folded_bram_predictor.
//
// All engines consume the same spike word in lock-step, but each owns two
// BRAM-backed weight-row buffers, a folded adder, partial accumulators, and a
// hidden LIF.  The single 64-bit row stream fills those buffers serially while
// the active neuron batch computes.  NUM_ENGINES=4 is the retained point;
// NUM_ENGINES=6 saturates the 64-bit row stream.
module folded_bram_predictor_parallel #(
    parameter int NUM_INPUTS          = 4096,
    parameter int NUM_HIDDEN          = 512,
    parameter int TIME_STEPS          = 25,
    parameter int LANES               = 16,
    parameter int NUM_ENGINES         = 4,
    parameter int IN_WIDTH            = 16,
    parameter int WEIGHT_STREAM_WIDTH = 64,
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
    input  logic                                      spike_valid,
    output logic                                      spike_ready,
    input  logic [LANES-1:0]                          spike_data,
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
    localparam int NUM_BATCHES           = (NUM_HIDDEN + NUM_ENGINES - 1) / NUM_ENGINES;
    localparam int HIDDEN_BITS           = $clog2(NUM_HIDDEN);
    localparam int ENGINE_BITS           = (NUM_ENGINES <= 1) ? 1 : $clog2(NUM_ENGINES);
    localparam int BATCH_BITS            = (NUM_BATCHES <= 1) ? 1 : $clog2(NUM_BATCHES);
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
        if (NUM_ENGINES < 1 || NUM_ENGINES > NUM_HIDDEN)
            $error("NUM_ENGINES must be between 1 and NUM_HIDDEN");
        if (ROW_WIDTH % WEIGHT_STREAM_WIDTH != 0)
            $error("LANES*IN_WIDTH must be divisible by WEIGHT_STREAM_WIDTH");
    end

    // Shared spike-image memory.  One BRAM read fans out to all engines because
    // they process the same (timestep, fold) coordinate in lock-step.
    (* ram_style = "block" *) logic [LANES-1:0] spike_mem [0:SPIKE_WORDS-1];
    logic [SPIKE_ADDR_BITS-1:0] spike_write_addr;
    logic [LANES-1:0] spike_row_q;

    logic [ROW_WIDTH-1:0] weight_pack;
    logic [ROW_WIDTH-1:0] weight_pack_next;
    logic [FOLD_BITS-1:0] load_fold;
    logic [BEAT_BITS-1:0] load_beat;
    logic [WEIGHT_COUNT_BITS-1:0] weight_count;
    logic [ENGINE_BITS-1:0] load_engine;
    logic [BATCH_BITS:0] load_batch;
    logic load_buffer_sel;
    logic weight_fire;
    logic weight_word_write;

    always_comb begin
        weight_pack_next = weight_pack;
        weight_pack_next[load_beat*WEIGHT_STREAM_WIDTH +: WEIGHT_STREAM_WIDTH] = weight_data;
    end

    assign weight_fire = weight_valid && weight_ready;
    assign weight_word_write = weight_fire && (load_beat == WEIGHT_BEATS_PER_FOLD-1);

    // Engine-private row memories.  Both ping-pong rows share one 2*FOLDS-deep
    // SDP memory per engine.  At 16 lanes this is 512x256 and packs into four
    // RAMB36E2s; two separately declared 256x256 arrays would waste half of
    // every primitive and consume eight RAMB36E2s per engine.
    logic [ROW_WIDTH-1:0] weight_row_q [0:NUM_ENGINES-1];
    logic [ROW_WIDTH-1:0] active_weight_row_q [0:NUM_ENGINES-1];
    logic active_buffer;
    logic [NUM_ENGINES-1:0] active_engine;
    logic compute_issue;
    logic [FOLD_BITS-1:0] issue_fold;

    generate
        for (genvar e = 0; e < NUM_ENGINES; e = e + 1) begin : row_engine
            (* ram_style = "block" *) logic [ROW_WIDTH-1:0] rows [0:2*FOLDS-1];

            always_ff @(posedge clk) begin
                if (weight_word_write && (load_engine == e))
                    rows[{load_buffer_sel, load_fold}] <= weight_pack_next;
                if (compute_issue && active_engine[e])
                    weight_row_q[e] <= rows[{active_buffer, issue_fold}];
            end

            assign active_weight_row_q[e] = weight_row_q[e];
        end
    endgenerate

    // Parameter ROMs are read only by the serial row loader; their values are
    // copied into the same per-engine/per-bank metadata as each loaded row.
    (* rom_style = "block" *) logic signed [IN_WIDTH-1:0] layer1_biases [0:NUM_HIDDEN-1];
    (* rom_style = "block" *) logic signed [IN_WIDTH-1:0] layer2_weights [0:2*NUM_HIDDEN-1];
    logic signed [IN_WIDTH-1:0] layer2_biases [0:1];

    initial begin
        $readmemh(LAYER1_BIASES_PATH, layer1_biases);
        $readmemh(LAYER2_WEIGHTS_PATH, layer2_weights);
        $readmemh(LAYER2_BIASES_PATH, layer2_biases);
    end

    logic [1:0][NUM_ENGINES-1:0] buffer_valid;
    logic [HIDDEN_BITS-1:0] buffer_neuron [0:1][0:NUM_ENGINES-1];
    logic signed [IN_WIDTH-1:0] buffer_l1_bias [0:1][0:NUM_ENGINES-1];
    logic signed [IN_WIDTH-1:0] buffer_l2_no_collision [0:1][0:NUM_ENGINES-1];
    logic signed [IN_WIDTH-1:0] buffer_l2_collision [0:1][0:NUM_ENGINES-1];

    logic signed [IN_WIDTH-1:0] active_l1_bias [0:NUM_ENGINES-1];
    logic signed [IN_WIDTH-1:0] active_l2_no_collision [0:NUM_ENGINES-1];
    logic signed [IN_WIDTH-1:0] active_l2_collision [0:NUM_ENGINES-1];

    typedef enum logic [1:0] {L_IDLE, L_REQUEST, L_RECEIVE} loader_state_t;
    loader_state_t loader_state;
    logic [HIDDEN_BITS:0] load_neuron;
    logic image_active;
    logic compute_holds_rows;

    assign load_buffer_sel = load_batch[0];
    assign row_request_valid = (loader_state == L_REQUEST);
    assign row_request_neuron = load_neuron[HIDDEN_BITS-1:0];
    assign weight_ready = (loader_state == L_RECEIVE);

    typedef enum logic [3:0] {
        C_IDLE,
        C_LOAD_SPIKES,
        C_WAIT_BATCH,
        C_PREP_COMPUTE,
        C_COMPUTE,
        C_HIDDEN_LIF,
        C_ACCUM_L2,
        C_OUTPUT_LIF,
        C_EMIT
    } compute_state_t;
    compute_state_t compute_state;

    logic [BATCH_BITS-1:0] compute_batch;
    logic [STEP_BITS-1:0] issue_tstep;
    logic [STEP_BITS-1:0] lif_tstep;
    logic issuing;
    logic read_valid;
    logic [STEP_BITS-1:0] read_tstep;
    logic [RESULT_COUNT_BITS-1:0] result_count;
    logic [SPIKE_ADDR_BITS-1:0] compute_spike_addr;
    logic batch_ready;

    assign active_buffer = compute_batch[0];
    assign compute_holds_rows = (compute_state == C_PREP_COMPUTE)
                             || (compute_state == C_COMPUTE);
    assign compute_issue = (compute_state == C_COMPUTE) && issuing;
    assign compute_spike_addr = SPIKE_ADDR_BITS'(issue_tstep * FOLDS + issue_fold);

    always_comb begin
        batch_ready = 1'b1;
        active_engine = '0;
        for (int e = 0; e < NUM_ENGINES; e = e + 1) begin
            if ((compute_batch * NUM_ENGINES + e) < NUM_HIDDEN) begin
                active_engine[e] = 1'b1;
                if (!buffer_valid[compute_batch[0]][e]
                        || buffer_neuron[compute_batch[0]][e]
                           != HIDDEN_BITS'(compute_batch * NUM_ENGINES + e))
                    batch_ready = 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (spike_valid && spike_ready)
            spike_mem[spike_write_addr] <= spike_data;
        if (compute_issue)
            spike_row_q <= spike_mem[compute_spike_addr];
    end

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

    logic signed [TREE_SUM_WIDTH-1:0] folded_sum [0:NUM_ENGINES-1];
    logic signed [ACC_WIDTH-1:0] folded_sum_ext [0:NUM_ENGINES-1];
    logic signed [LANES-1:0][IN_WIDTH-1:0] active_weights [0:NUM_ENGINES-1];

    generate
        for (genvar e = 0; e < NUM_ENGINES; e = e + 1) begin : compute_engine
            assign active_weights[e] = active_weight_row_q[e];
            assign folded_sum_ext[e] = {
                {(ACC_WIDTH-TREE_SUM_WIDTH){folded_sum[e][TREE_SUM_WIDTH-1]}},
                folded_sum[e]
            };

            cascaded_adder_synth #(
                .NUM_INPUTS(LANES),
                .IN_WIDTH(IN_WIDTH),
                .OUT_WIDTH(TREE_SUM_WIDTH),
                .PIPE(0)
            ) folded_adder (
                .clk(clk),
                .rst_n(~rst),
                .spike(spike_row_q),
                .weight(active_weights[e]),
                .valid_in(read_valid),
                .out(folded_sum[e]),
                .valid_out()
            );
        end
    endgenerate

    logic signed [ACC_WIDTH-1:0] partial [0:NUM_ENGINES-1][0:TIME_STEPS-1];
    logic signed [ACC_WIDTH-1:0] l2_no_collision [0:TIME_STEPS-1];
    logic signed [ACC_WIDTH-1:0] l2_collision [0:TIME_STEPS-1];
    logic signed [ACC_WIDTH-1:0] l1_current [0:NUM_ENGINES-1];
    logic [NUM_ENGINES-1:0] l1_spike;
    logic [NUM_ENGINES-1:0] l1_spike_q;
    logic l1_enable;
    logic l1_new_image;

    assign l1_enable = (compute_state == C_HIDDEN_LIF);
    assign l1_new_image = l1_enable && (lif_tstep == 0);

    generate
        for (genvar e = 0; e < NUM_ENGINES; e = e + 1) begin : hidden_lif_engine
            assign l1_current[e] = partial[e][lif_tstep]
                + {{(ACC_WIDTH-IN_WIDTH){active_l1_bias[e][IN_WIDTH-1]}}, active_l1_bias[e]};

            lif_model #(
                .k(FIRST_LAYER_K),
                .uth(FIRST_LAYER_THRESHOLD)
            ) hidden_lif (
                .clk(clk),
                .rst(rst),
                .enable(l1_enable && active_engine[e]),
                .new_image(l1_new_image && active_engine[e]),
                .input_current(l1_current[e]),
                .spike(l1_spike[e])
            );
        end
    endgenerate

    logic signed [ACC_WIDTH-1:0] batch_l2_no_collision;
    logic signed [ACC_WIDTH-1:0] batch_l2_collision;

    always_comb begin
        batch_l2_no_collision = '0;
        batch_l2_collision = '0;
        for (int e = 0; e < NUM_ENGINES; e = e + 1) begin
            if (active_engine[e] && l1_spike_q[e]) begin
                batch_l2_no_collision = batch_l2_no_collision
                    + {{(ACC_WIDTH-IN_WIDTH){active_l2_no_collision[e][IN_WIDTH-1]}},
                       active_l2_no_collision[e]};
                batch_l2_collision = batch_l2_collision
                    + {{(ACC_WIDTH-IN_WIDTH){active_l2_collision[e][IN_WIDTH-1]}},
                       active_l2_collision[e]};
            end
        end
    end

    logic output_enable;
    logic output_new_image;
    logic no_collision_spike;
    logic collision_spike;

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
    integer e;
    always_ff @(posedge clk) begin
        if (rst) begin
            compute_state <= C_IDLE;
            loader_state <= L_IDLE;
            image_active <= 1'b0;
            spike_write_addr <= '0;
            load_neuron <= '0;
            load_engine <= '0;
            load_batch <= '0;
            load_fold <= '0;
            load_beat <= '0;
            weight_count <= '0;
            weight_pack <= '0;
            buffer_valid <= '0;
            compute_batch <= '0;
            issue_tstep <= '0;
            issue_fold <= '0;
            lif_tstep <= '0;
            issuing <= 1'b0;
            result_count <= '0;
            l1_spike_q <= '0;
            inference_valid <= 1'b0;
            collision_counter <= '0;
            no_collision_counter <= '0;
            protocol_error <= 1'b0;
            for (e = 0; e < NUM_ENGINES; e = e + 1) begin
                buffer_neuron[0][e] <= '0;
                buffer_neuron[1][e] <= '0;
                buffer_l1_bias[0][e] <= '0;
                buffer_l1_bias[1][e] <= '0;
                buffer_l2_no_collision[0][e] <= '0;
                buffer_l2_no_collision[1][e] <= '0;
                buffer_l2_collision[0][e] <= '0;
                buffer_l2_collision[1][e] <= '0;
                active_l1_bias[e] <= '0;
                active_l2_no_collision[e] <= '0;
                active_l2_collision[e] <= '0;
                for (t = 0; t < TIME_STEPS; t = t + 1)
                    partial[e][t] <= '0;
            end
            for (t = 0; t < TIME_STEPS; t = t + 1) begin
                l2_no_collision[t] <= '0;
                l2_collision[t] <= '0;
            end
        end else begin
            inference_valid <= 1'b0;

            case (loader_state)
                L_IDLE: begin
                    if (image_active && (load_neuron < NUM_HIDDEN)
                            && !buffer_valid[load_buffer_sel][load_engine]
                            && !(compute_holds_rows && (active_buffer == load_buffer_sel)))
                        loader_state <= L_REQUEST;
                end

                L_REQUEST: begin
                    if (row_request_ready) begin
                        load_fold <= '0;
                        load_beat <= '0;
                        weight_count <= '0;
                        weight_pack <= '0;
                        buffer_l1_bias[load_buffer_sel][load_engine]
                            <= layer1_biases[load_neuron[HIDDEN_BITS-1:0]];
                        buffer_l2_no_collision[load_buffer_sel][load_engine]
                            <= layer2_weights[load_neuron[HIDDEN_BITS-1:0]];
                        buffer_l2_collision[load_buffer_sel][load_engine]
                            <= layer2_weights[NUM_HIDDEN + load_neuron[HIDDEN_BITS-1:0]];
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
                            buffer_valid[load_buffer_sel][load_engine] <= 1'b1;
                            buffer_neuron[load_buffer_sel][load_engine]
                                <= load_neuron[HIDDEN_BITS-1:0];
                            load_neuron <= load_neuron + 1'b1;
                            if (load_engine == ENGINE_BITS'(NUM_ENGINES-1)) begin
                                load_engine <= '0;
                                load_batch <= load_batch + 1'b1;
                            end else begin
                                load_engine <= load_engine + 1'b1;
                            end
                            loader_state <= L_IDLE;
                        end else begin
                            weight_count <= weight_count + 1'b1;
                        end
                    end
                end

                default: loader_state <= L_IDLE;
            endcase

            case (compute_state)
                C_IDLE: begin
                    if (start_image) begin
                        compute_state <= C_LOAD_SPIKES;
                        loader_state <= L_IDLE;
                        image_active <= 1'b0;
                        spike_write_addr <= '0;
                        load_neuron <= '0;
                        load_engine <= '0;
                        load_batch <= '0;
                        buffer_valid <= '0;
                        compute_batch <= '0;
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
                            compute_state <= C_WAIT_BATCH;
                            for (t = 0; t < TIME_STEPS; t = t + 1) begin
                                l2_no_collision[t]
                                    <= {{(ACC_WIDTH-IN_WIDTH){layer2_biases[0][IN_WIDTH-1]}}, layer2_biases[0]};
                                l2_collision[t]
                                    <= {{(ACC_WIDTH-IN_WIDTH){layer2_biases[1][IN_WIDTH-1]}}, layer2_biases[1]};
                            end
                        end else begin
                            spike_write_addr <= spike_write_addr + 1'b1;
                        end
                    end
                end

                C_WAIT_BATCH: begin
                    if (batch_ready) begin
                        for (e = 0; e < NUM_ENGINES; e = e + 1) begin
                            active_l1_bias[e] <= buffer_l1_bias[compute_batch[0]][e];
                            active_l2_no_collision[e]
                                <= buffer_l2_no_collision[compute_batch[0]][e];
                            active_l2_collision[e]
                                <= buffer_l2_collision[compute_batch[0]][e];
                            for (t = 0; t < TIME_STEPS; t = t + 1)
                                partial[e][t] <= '0;
                        end
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
                        for (e = 0; e < NUM_ENGINES; e = e + 1) begin
                            if (active_engine[e])
                                partial[e][read_tstep]
                                    <= partial[e][read_tstep] + folded_sum_ext[e];
                        end

                        if (result_count == SPIKE_WORDS-1) begin
                            for (e = 0; e < NUM_ENGINES; e = e + 1) begin
                                if (active_engine[e])
                                    buffer_valid[active_buffer][e] <= 1'b0;
                            end
                            result_count <= '0;
                            lif_tstep <= '0;
                            compute_state <= C_HIDDEN_LIF;
                        end else begin
                            result_count <= result_count + 1'b1;
                        end
                    end
                end

                C_HIDDEN_LIF: begin
                    // Break the hidden-LIF -> multi-engine L2 adder -> L2 RAM
                    // critical path.  The LIF state and this spike register are
                    // updated together; L2 accumulation follows one cycle later.
                    l1_spike_q <= l1_spike;
                    compute_state <= C_ACCUM_L2;
                end

                C_ACCUM_L2: begin
                    l2_no_collision[lif_tstep]
                        <= l2_no_collision[lif_tstep] + batch_l2_no_collision;
                    l2_collision[lif_tstep]
                        <= l2_collision[lif_tstep] + batch_l2_collision;

                    if (lif_tstep == TIME_STEPS-1) begin
                        lif_tstep <= '0;
                        if (compute_batch == NUM_BATCHES-1) begin
                            image_active <= 1'b0;
                            compute_state <= C_OUTPUT_LIF;
                        end else begin
                            compute_batch <= compute_batch + 1'b1;
                            compute_state <= C_WAIT_BATCH;
                        end
                    end else begin
                        lif_tstep <= lif_tstep + 1'b1;
                        compute_state <= C_HIDDEN_LIF;
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
