`timescale 1ns/1ps

// L128 folded 4096-512-2 collision-prediction SNN.
//
// Schedule (one fold issued per cycle):
//   hidden: 32 folds x 25 timesteps x 512 neurons
//   output:  4 folds x 25 timesteps x 2 neurons
//
// All 25x4096 input spikes are captured in BRAM before compute.  Layer-1
// weights arrive once per neuron over a 128-bit stream.  Sixteen narrow BRAM
// banks form each 8 KiB row buffer, allowing one 128-bit write per load cycle
// and one 2048-bit (128-weight) read per compute cycle.  The two row buffers
// ping-pong, so a 512-cycle row load is hidden by an 800-cycle hidden-neuron
// computation.  Only the small biases and 2 KiB layer-2 matrix use readmemh.
module collision_predictor #(
    parameter string LAYER2_WEIGHTS_PATH = "../sw/model_params/layer2_weights.hex",
    parameter string LAYER1_BIASES_PATH  = "../sw/model_params/layer1_biases.hex",
    parameter string LAYER2_BIASES_PATH  = "../sw/model_params/layer2_biases.hex",
    parameter int FIRST_LAYER_K          = 15,
    parameter int SECOND_LAYER_K         = 15,
    parameter int FIRST_LAYER_THRESHOLD  = 8938,
    parameter int SECOND_LAYER_THRESHOLD = 6775
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          start_image,
    output logic          image_ready,

    // Exactly 25*4096/128 = 800 accepted words, timestep-major and then
    // fold-major, constitute one image.
    input  logic          spike_valid,
    output logic          spike_ready,
    input  logic [127:0]  spike_data,

    // One request and 4096*16/128 = 512 accepted beats per hidden neuron.
    // Weight zero occupies weight_data[15:0].
    output logic          row_request_valid,
    input  logic          row_request_ready,
    output logic [8:0]    row_request_neuron,
    input  logic          weight_valid,
    output logic          weight_ready,
    input  logic [127:0]  weight_data,
    input  logic          weight_last,

    output logic          inference_valid,
    output logic [4:0]    collision_counter,
    output logic [4:0]    no_collision_counter,
    output logic          classification,
    output logic          protocol_error,

    // Per-inference accounting.  compute_cycles is the accepted fold count;
    // weight_load_cycles and input_load_cycles are accepted stream cycles.
    output logic [31:0]   inference_cycles,
    output logic [31:0]   compute_cycles,
    output logic [31:0]   weight_load_cycles,
    output logic [31:0]   input_load_cycles,
    output logic [31:0]   row_stall_cycles,

    // Verification trace: one pulse for every bit-exact LIF result.
    output logic          hidden_spike_valid,
    output logic [8:0]    hidden_spike_neuron,
    output logic [4:0]    hidden_spike_timestep,
    output logic          hidden_spike,
    output logic          output_spike_valid,
    output logic          output_spike_neuron,
    output logic [4:0]    output_spike_timestep,
    output logic          output_spike
);
    localparam int NUM_INPUTS       = 4096;
    localparam int NUM_HIDDEN       = 512;
    localparam int TIME_STEPS       = 25;
    localparam int LANES            = 128;
    localparam int ADDERS           = 8;
    localparam int ADDER_INPUTS     = 16;
    localparam int IN_WIDTH         = 16;
    localparam int ACC_WIDTH        = 28;
    localparam int HIDDEN_FOLDS     = NUM_INPUTS / LANES;  // 32
    localparam int OUTPUT_FOLDS     = NUM_HIDDEN / LANES;  // 4
    localparam int INPUT_WORDS      = TIME_STEPS * HIDDEN_FOLDS; // 800
    localparam int WEIGHTS_PER_BEAT = 128 / IN_WIDTH;      // 8
    localparam int WEIGHT_BANKS     = LANES / WEIGHTS_PER_BEAT; // 16
    localparam int WEIGHT_BEATS     = NUM_INPUTS / WEIGHTS_PER_BEAT; // 512
    localparam int BANK_SUM_WIDTH   = IN_WIDTH + $clog2(LANES); // 23

    initial begin
        if (ADDERS * ADDER_INPUTS != LANES)
            $error("L128 geometry must be eight 16-input adders");
        if (WEIGHT_BANKS * WEIGHTS_PER_BEAT != LANES)
            $error("weight-bank geometry does not cover one L128 fold");
        if (FIRST_LAYER_K != SECOND_LAYER_K)
            $error("the shared LIF requires equal layer decay shifts");
    end

    // ------------------------------------------------------------------
    // Small resident parameters.  The 4 MiB layer-1 matrix is intentionally
    // absent; only these 4.5 KiB of biases/layer-2 weights are initialized.
    // ------------------------------------------------------------------
    (* rom_style = "block" *) logic signed [IN_WIDTH-1:0]
        layer1_biases [0:NUM_HIDDEN-1];
    (* rom_style = "distributed" *) logic signed [IN_WIDTH-1:0]
        layer2_weights [0:2*NUM_HIDDEN-1];
    logic signed [IN_WIDTH-1:0] layer2_biases [0:1];

    initial begin
        $readmemh(LAYER1_BIASES_PATH, layer1_biases);
        $readmemh(LAYER2_WEIGHTS_PATH, layer2_weights);
        $readmemh(LAYER2_BIASES_PATH, layer2_biases);
    end

    // ------------------------------------------------------------------
    // Input and hidden-spike storage.
    // ------------------------------------------------------------------
    (* ram_style = "block" *) logic [LANES-1:0]
        input_spike_mem [0:INPUT_WORDS-1];
    logic [9:0] input_write_addr;

    // Distributed RAM: this hidden-spike matrix is 12.8 Kibit with bit writes
    // and 128-bit reads.
    (* ram_style = "distributed" *) logic [NUM_HIDDEN-1:0]
        hidden_spike_mem [0:TIME_STEPS-1];

    // ------------------------------------------------------------------
    // Streamed layer-1 row loader and ping-pong memories.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {L_IDLE, L_REQUEST, L_RECEIVE} loader_state_t;
    loader_state_t loader_state;
    logic [9:0] load_neuron;
    logic [8:0] weight_count;
    logic load_buffer_sel;
    logic [3:0] load_bank;
    logic [4:0] load_fold;
    logic weight_fire;
    logic image_active;
    logic [1:0] buffer_valid;
    logic [8:0] buffer_neuron [0:1];

    assign load_buffer_sel = load_neuron[0];
    assign load_bank = weight_count[3:0];
    assign load_fold = weight_count[8:4];
    assign row_request_valid = (loader_state == L_REQUEST);
    assign row_request_neuron = load_neuron[8:0];
    assign weight_ready = (loader_state == L_RECEIVE);
    assign weight_fire = weight_valid && weight_ready;

    logic [127:0] row0_q [0:WEIGHT_BANKS-1];
    logic [127:0] row1_q [0:WEIGHT_BANKS-1];
    logic hidden_issue;
    logic active_buffer;
    logic [4:0] issue_fold;

    genvar bank;
    generate
        for (bank = 0; bank < WEIGHT_BANKS; bank = bank + 1) begin : row_banks
            (* ram_style = "block" *) logic [127:0]
                row0 [0:HIDDEN_FOLDS-1];
            (* ram_style = "block" *) logic [127:0]
                row1 [0:HIDDEN_FOLDS-1];

            always_ff @(posedge clk) begin
                if (weight_fire && !load_buffer_sel && (load_bank == bank))
                    row0[load_fold] <= weight_data;
                if (hidden_issue && !active_buffer)
                    row0_q[bank] <= row0[issue_fold];

                if (weight_fire && load_buffer_sel && (load_bank == bank))
                    row1[load_fold] <= weight_data;
                if (hidden_issue && active_buffer)
                    row1_q[bank] <= row1[issue_fold];
            end
        end
    endgenerate

    logic [LANES*IN_WIDTH-1:0] active_hidden_weights;
    integer selected_bank;
    always_comb begin
        active_hidden_weights = '0;
        for (selected_bank = 0; selected_bank < WEIGHT_BANKS;
             selected_bank = selected_bank + 1) begin
            active_hidden_weights[selected_bank*128 +: 128] = active_buffer
                ? row1_q[selected_bank] : row0_q[selected_bank];
        end
    end

    // ------------------------------------------------------------------
    // Neuron-major controller and BRAM-read boundary.
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        C_IDLE,
        C_LOAD_INPUT,
        C_WAIT_ROW,
        C_HIDDEN,
        C_OUTPUT,
        C_EMIT
    } compute_state_t;
    compute_state_t compute_state;

    logic [8:0] compute_neuron;
    logic [4:0] issue_timestep;
    logic issue_output_neuron;
    logic issue_active;
    logic compute_issue;
    logic issue_output_phase;
    logic issue_last_fold;
    logic [9:0] input_read_addr;
    logic [LANES-1:0] spike_q;
    logic [LANES*IN_WIDTH-1:0] output_weight_q;
    logic bram_valid_q;
    logic bram_last_fold_q;
    logic bram_output_phase_q;
    logic bram_output_neuron_q;
    logic [4:0] bram_timestep_q;

    assign issue_output_phase = (compute_state == C_OUTPUT);
    assign compute_issue = issue_active
                         && ((compute_state == C_HIDDEN)
                             || (compute_state == C_OUTPUT));
    assign hidden_issue = compute_issue && !issue_output_phase;
    assign issue_last_fold = issue_output_phase
                           ? (issue_fold == OUTPUT_FOLDS-1)
                           : (issue_fold == HIDDEN_FOLDS-1);
    assign input_read_addr = {issue_timestep, issue_fold};

    integer lane;
    always_ff @(posedge clk) begin
        if (rst) begin
            bram_valid_q <= 1'b0;
            bram_last_fold_q <= 1'b0;
            bram_output_phase_q <= 1'b0;
            bram_output_neuron_q <= 1'b0;
            bram_timestep_q <= '0;
            spike_q <= '0;
            output_weight_q <= '0;
        end else begin
            bram_valid_q <= compute_issue;
            if (compute_issue) begin
                bram_last_fold_q <= issue_last_fold;
                bram_output_phase_q <= issue_output_phase;
                bram_output_neuron_q <= issue_output_neuron;
                bram_timestep_q <= issue_timestep;
                if (!issue_output_phase) begin
                    spike_q <= input_spike_mem[input_read_addr];
                end else begin
                    spike_q <= hidden_spike_mem[issue_timestep]
                        [issue_fold*LANES +: LANES];
                    for (lane = 0; lane < LANES; lane = lane + 1) begin
                        output_weight_q[lane*IN_WIDTH +: IN_WIDTH] <=
                            layer2_weights[issue_output_neuron*NUM_HIDDEN
                                         + issue_fold*LANES + lane];
                    end
                end
            end
        end
    end

    logic signed [127:0][IN_WIDTH-1:0] adder_weights;
    always_comb begin
        if (bram_output_phase_q)
            adder_weights = output_weight_q;
        else
            adder_weights = active_hidden_weights;
    end

    logic adder_valid;
    logic adder_last_fold;
    logic adder_output_phase;
    logic adder_output_neuron;
    logic [4:0] adder_timestep;
    logic signed [BANK_SUM_WIDTH-1:0] adder_sum;

    l128_adder_bank #(
        .IN_WIDTH(IN_WIDTH),
        .TIMESTEP_BITS(5)
    ) adder_bank (
        .clk(clk),
        .rst(rst),
        .valid_in(bram_valid_q),
        .last_fold_in(bram_last_fold_q),
        .output_phase_in(bram_output_phase_q),
        .output_neuron_in(bram_output_neuron_q),
        .timestep_in(bram_timestep_q),
        .spike_in(spike_q),
        .weight_in(adder_weights),
        .valid_out(adder_valid),
        .last_fold_out(adder_last_fold),
        .output_phase_out(adder_output_phase),
        .output_neuron_out(adder_output_neuron),
        .timestep_out(adder_timestep),
        .sum_out(adder_sum)
    );

    // ------------------------------------------------------------------
    // One accumulator and one shared LIF for both network layers.
    // ------------------------------------------------------------------
    logic signed [ACC_WIDTH-1:0] dot_accumulator;
    logic signed [ACC_WIDTH-1:0] adder_sum_ext;
    logic signed [IN_WIDTH-1:0] active_l1_bias;
    logic signed [IN_WIDTH-1:0] result_bias;
    logic signed [ACC_WIDTH-1:0] result_bias_ext;
    logic signed [ACC_WIDTH-1:0] lif_current;
    logic signed [29:0] lif_threshold;
    logic lif_enable;
    logic lif_new_sequence;
    logic lif_spike;

    assign adder_sum_ext = {{(ACC_WIDTH-BANK_SUM_WIDTH){adder_sum[BANK_SUM_WIDTH-1]}},
                            adder_sum};
    always_comb begin
        result_bias = adder_output_phase
                    ? layer2_biases[adder_output_neuron]
                    : active_l1_bias;
        result_bias_ext = {{(ACC_WIDTH-IN_WIDTH){result_bias[IN_WIDTH-1]}},
                           result_bias};
        lif_current = dot_accumulator + adder_sum_ext + result_bias_ext;
        lif_threshold = adder_output_phase
                      ? SECOND_LAYER_THRESHOLD : FIRST_LAYER_THRESHOLD;
    end

    assign lif_enable = adder_valid && adder_last_fold;
    assign lif_new_sequence = lif_enable && (adder_timestep == 0);

    lif_model #(
        .k(FIRST_LAYER_K)
    ) shared_lif (
        .clk(clk),
        .rst(rst),
        .enable(lif_enable),
        .new_image(lif_new_sequence),
        .input_current(lif_current),
        .uth(lif_threshold),
        .spike(lif_spike)
    );

    assign image_ready = (compute_state == C_IDLE);
    assign spike_ready = (compute_state == C_LOAD_INPUT);
    assign classification = (collision_counter > no_collision_counter);

    logic [31:0] cycle_work;
    logic target_buffer;
    logic target_row_ready;
    assign target_buffer = compute_neuron[0];
    assign target_row_ready = buffer_valid[target_buffer]
                           && (buffer_neuron[target_buffer] == compute_neuron);

    always_ff @(posedge clk) begin
        if (rst) begin
            loader_state <= L_IDLE;
            compute_state <= C_IDLE;
            load_neuron <= '0;
            weight_count <= '0;
            image_active <= 1'b0;
            buffer_valid <= '0;
            buffer_neuron[0] <= '0;
            buffer_neuron[1] <= '0;
            input_write_addr <= '0;
            compute_neuron <= '0;
            active_buffer <= 1'b0;
            active_l1_bias <= '0;
            issue_timestep <= '0;
            issue_fold <= '0;
            issue_output_neuron <= 1'b0;
            issue_active <= 1'b0;
            dot_accumulator <= '0;
            collision_counter <= '0;
            no_collision_counter <= '0;
            inference_valid <= 1'b0;
            protocol_error <= 1'b0;
            inference_cycles <= '0;
            compute_cycles <= '0;
            weight_load_cycles <= '0;
            input_load_cycles <= '0;
            row_stall_cycles <= '0;
            cycle_work <= '0;
            hidden_spike_valid <= 1'b0;
            hidden_spike_neuron <= '0;
            hidden_spike_timestep <= '0;
            hidden_spike <= 1'b0;
            output_spike_valid <= 1'b0;
            output_spike_neuron <= 1'b0;
            output_spike_timestep <= '0;
            output_spike <= 1'b0;
        end else begin
            inference_valid <= 1'b0;
            hidden_spike_valid <= 1'b0;
            output_spike_valid <= 1'b0;

            if (compute_state != C_IDLE)
                cycle_work <= cycle_work + 1'b1;
            if (compute_issue)
                compute_cycles <= compute_cycles + 1'b1;
            if (weight_fire)
                weight_load_cycles <= weight_load_cycles + 1'b1;

            // Independent row-loader FSM.
            case (loader_state)
                L_IDLE: begin
                    if (image_active && (load_neuron < NUM_HIDDEN)
                            && !buffer_valid[load_buffer_sel])
                        loader_state <= L_REQUEST;
                end

                L_REQUEST: begin
                    if (row_request_ready) begin
                        weight_count <= '0;
                        loader_state <= L_RECEIVE;
                    end
                end

                L_RECEIVE: begin
                    if (weight_fire) begin
                        if (weight_last != (weight_count == WEIGHT_BEATS-1))
                            protocol_error <= 1'b1;
                        if (weight_count == WEIGHT_BEATS-1) begin
                            buffer_valid[load_buffer_sel] <= 1'b1;
                            buffer_neuron[load_buffer_sel] <= load_neuron[8:0];
                            load_neuron <= load_neuron + 1'b1;
                            loader_state <= L_IDLE;
                        end else begin
                            weight_count <= weight_count + 1'b1;
                        end
                    end
                end

                default: loader_state <= L_IDLE;
            endcase

            // Issue-side controller.  State transitions at the end of a
            // neuron are driven by pipelined last_fold/timestep metadata below.
            case (compute_state)
                C_IDLE: begin
                    if (start_image) begin
                        compute_state <= C_LOAD_INPUT;
                        loader_state <= L_IDLE;
                        load_neuron <= '0;
                        weight_count <= '0;
                        image_active <= 1'b1;
                        buffer_valid <= '0;
                        input_write_addr <= '0;
                        compute_neuron <= '0;
                        issue_timestep <= '0;
                        issue_fold <= '0;
                        issue_output_neuron <= 1'b0;
                        issue_active <= 1'b0;
                        dot_accumulator <= '0;
                        collision_counter <= '0;
                        no_collision_counter <= '0;
                        protocol_error <= 1'b0;
                        inference_cycles <= '0;
                        compute_cycles <= '0;
                        weight_load_cycles <= '0;
                        input_load_cycles <= '0;
                        row_stall_cycles <= '0;
                        cycle_work <= '0;
                    end
                end

                C_LOAD_INPUT: begin
                    if (spike_valid && spike_ready) begin
                        input_spike_mem[input_write_addr] <= spike_data;
                        input_load_cycles <= input_load_cycles + 1'b1;
                        if (input_write_addr == INPUT_WORDS-1) begin
                            input_write_addr <= '0;
                            compute_state <= C_WAIT_ROW;
                        end else begin
                            input_write_addr <= input_write_addr + 1'b1;
                        end
                    end
                end

                C_WAIT_ROW: begin
                    if (target_row_ready) begin
                        active_buffer <= target_buffer;
                        active_l1_bias <= layer1_biases[compute_neuron];
                        issue_timestep <= '0;
                        issue_fold <= '0;
                        issue_active <= 1'b1;
                        dot_accumulator <= '0;
                        compute_state <= C_HIDDEN;
                    end else begin
                        row_stall_cycles <= row_stall_cycles + 1'b1;
                    end
                end

                C_HIDDEN: begin
                    if (issue_active) begin
                        if (issue_fold == HIDDEN_FOLDS-1) begin
                            issue_fold <= '0;
                            if (issue_timestep == TIME_STEPS-1) begin
                                issue_active <= 1'b0;
                            end else begin
                                issue_timestep <= issue_timestep + 1'b1;
                            end
                        end else begin
                            issue_fold <= issue_fold + 1'b1;
                        end
                    end
                end

                C_OUTPUT: begin
                    if (issue_active) begin
                        if (issue_fold == OUTPUT_FOLDS-1) begin
                            issue_fold <= '0;
                            if (issue_timestep == TIME_STEPS-1) begin
                                issue_timestep <= '0;
                                if (!issue_output_neuron) begin
                                    issue_output_neuron <= 1'b1;
                                end else begin
                                    issue_active <= 1'b0;
                                end
                            end else begin
                                issue_timestep <= issue_timestep + 1'b1;
                            end
                        end else begin
                            issue_fold <= issue_fold + 1'b1;
                        end
                    end
                end

                C_EMIT: begin
                    inference_cycles <= cycle_work + 1'b1;
                    inference_valid <= 1'b1;
                    image_active <= 1'b0;
                    compute_state <= C_IDLE;
                end

                default: compute_state <= C_IDLE;
            endcase

            // Result-side accumulation and LIF sequencing.  last_fold is
            // carried through the complete adder pipeline, so there is no
            // second output-side fold counter to drift out of alignment.
            if (adder_valid) begin
                if (adder_last_fold) begin
                    dot_accumulator <= '0;
                    if (!adder_output_phase) begin
                        hidden_spike_mem[adder_timestep][compute_neuron]
                            <= lif_spike;
                        hidden_spike_valid <= 1'b1;
                        hidden_spike_neuron <= compute_neuron;
                        hidden_spike_timestep <= adder_timestep;
                        hidden_spike <= lif_spike;

                        if (adder_timestep == TIME_STEPS-1) begin
                            buffer_valid[active_buffer] <= 1'b0;
                            issue_active <= 1'b0;
                            if (compute_neuron == NUM_HIDDEN-1) begin
                                issue_timestep <= '0;
                                issue_fold <= '0;
                                issue_output_neuron <= 1'b0;
                                issue_active <= 1'b1;
                                compute_state <= C_OUTPUT;
                            end else begin
                                compute_neuron <= compute_neuron + 1'b1;
                                compute_state <= C_WAIT_ROW;
                            end
                        end
                    end else begin
                        output_spike_valid <= 1'b1;
                        output_spike_neuron <= adder_output_neuron;
                        output_spike_timestep <= adder_timestep;
                        output_spike <= lif_spike;
                        if (adder_output_neuron)
                            collision_counter <= collision_counter + lif_spike;
                        else
                            no_collision_counter <= no_collision_counter + lif_spike;

                        if (adder_output_neuron
                                && (adder_timestep == TIME_STEPS-1)) begin
                            issue_active <= 1'b0;
                            compute_state <= C_EMIT;
                        end
                    end
                end else begin
                    dot_accumulator <= dot_accumulator + adder_sum_ext;
                end
            end
        end
    end

endmodule
