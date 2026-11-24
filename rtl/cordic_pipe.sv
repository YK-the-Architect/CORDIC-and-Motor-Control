// Fully-pipelined CORDIC engine.
//
// One CORDIC iteration is implemented between each pair of registers.  A new
// operation may be accepted on every rising edge when start is asserted.
// The interface and fixed-point conventions match cordic_ss.sv.
module cordic_pipe #(
    parameter int WIDTH = 8,
    parameter int ITER  = 8,
    parameter int G     = $clog2(ITER) + 1
) (
    input  logic clk,
    input  logic rst,
    input  logic signed [WIDTH-1:0] x_in, y_in, z_in,
    input  logic start,
    input  logic mode_cl, mode_rv,
    output logic out_valid,
    output logic signed [WIDTH-1:0] x_corr, y_corr, z,
    output logic ovf
);
    localparam int IW = WIDTH + 2 + G;

    logic signed [IW-1:0] x_pipe [0:ITER];
    logic signed [IW-1:0] y_pipe [0:ITER];
    logic signed [IW-1:0] z_pipe [0:ITER];
    logic                 valid_pipe [0:ITER];
    logic                 circular_pipe [0:ITER];
    logic                 vectoring_pipe[0:ITER];
    logic                 zhold_pipe [0:ITER];
    logic                 ovf_pipe [0:ITER];

    logic signed [IW-1:0] x_next [0:ITER];
    logic signed [IW-1:0] y_next [0:ITER];
    logic signed [IW-1:0] z_next [0:ITER];
    logic                 valid_next [0:ITER];
    logic                 circular_next [0:ITER];
    logic                 vectoring_next[0:ITER];
    logic                 zhold_next [0:ITER];
    logic                 ovf_next [0:ITER];

    logic [IW-1:0] atan_tbl [ITER];
    logic signed [IW-1:0] x_in_ext, y_in_ext, z_in_ext;
    logic signed [WIDTH-1:0] z_in_folded;
    logic signed [IW-1:0] x_init, y_init, z_init;
    logic fold_init, neg_xy_init, div_bad;
    logic sat;

    atan_rom #(
        .WIDTH(IW),
        .ITER(ITER),
        .ANGLE_BITS(WIDTH + G)
    ) u_atan_rom (.atan_out(atan_tbl));

    function automatic logic [WIDTH:0] mag(input logic signed [WIDTH-1:0] v);
        logic signed [WIDTH:0] w;
        begin
            w = v;
            mag = (w < 0) ? -w : w;
        end
    endfunction

    function automatic logic signed [IW-1:0] linear_step(input int sh);
        logic signed [IW-1:0] value;
        begin
            value = '0;
            if (sh <= WIDTH + G - 1)
                value = IW'(1) <<< (WIDTH - 1 + G - sh);
            linear_step = value;
        end
    endfunction

    function automatic logic addsub_overflow(
        input logic signed [IW-1:0] a,
        input logic signed [IW-1:0] b,
        input logic sub
    );
        logic signed [IW:0] a_ext, b_ext, result;
        begin
            a_ext = {a[IW-1], a};
            b_ext = {b[IW-1], b};
            result = sub ? a_ext - b_ext : a_ext + b_ext;
            addsub_overflow = result[IW] != result[IW-1];
        end
    endfunction

    assign fold_init = !mode_cl &&
                       (mode_rv ? x_in[WIDTH-1]
                                : ^z_in[WIDTH-1:WIDTH-2]);
    assign neg_xy_init = fold_init ||
                         (mode_cl && mode_rv && x_in[WIDTH-1]);

    assign x_in_ext = IW'(x_in) <<< G;
    assign y_in_ext = IW'(y_in) <<< G;
    assign z_in_folded =
    fold_init ? {~z_in[WIDTH-1], z_in[WIDTH-2:0]} : z_in;

    assign z_in_ext = IW'(z_in_folded) <<< G;

    assign x_init = neg_xy_init ? -x_in_ext : x_in_ext;
    assign y_init = neg_xy_init ? -y_in_ext : y_in_ext;
    assign z_init = z_in_ext;

    assign div_bad = mode_cl && mode_rv && (mag(y_in) >= mag(x_in));

    always_comb begin
        for (int k = 0; k <= ITER; k++) begin
            x_next[k] = x_pipe[k];
            y_next[k] = y_pipe[k];
            z_next[k] = z_pipe[k];
            valid_next[k] = valid_pipe[k];
            circular_next[k] = circular_pipe[k];
            vectoring_next[k] = vectoring_pipe[k];
            zhold_next[k] = zhold_pipe[k];
            ovf_next[k] = ovf_pipe[k];
        end

        // Stage zero accepts a new transaction.  The remaining stages shift
        // every clock, including bubbles, so transactions can be back-to-back.
        valid_next[0] = start;
        if (start) begin
            x_next[0] = x_init;
            y_next[0] = y_init;
            z_next[0] = z_init;
            circular_next[0] = !mode_cl;
            vectoring_next[0] = mode_rv;
            zhold_next[0] = !mode_cl && mode_rv &&
                            (x_in == '0) && (y_in == '0);
            ovf_next[0] = div_bad;
        end
        else begin
            ovf_next[0] = 1'b0;
        end

        for (int s = 0; s < ITER; s++) begin
            logic sigma;
            logic signed [IW-1:0] x_shift;
            logic signed [IW-1:0] y_shift;
            logic signed [IW-1:0] angle_step;
            logic signed [IW-1:0] x_result;
            logic signed [IW-1:0] y_result;
            logic signed [IW-1:0] z_result;

            valid_next[s+1] = valid_pipe[s];
            circular_next[s+1] = circular_pipe[s];
            vectoring_next[s+1] = vectoring_pipe[s];
            zhold_next[s+1] = zhold_pipe[s];

            sigma = vectoring_pipe[s] ? y_pipe[s][IW-1]
                                      : ~z_pipe[s][IW-1];
            x_shift = x_pipe[s] >>> (circular_pipe[s] ? s : s + 1);
            y_shift = y_pipe[s] >>> (circular_pipe[s] ? s : s + 1);
            angle_step = circular_pipe[s] ? $signed(atan_tbl[s])
                                          : linear_step(s + 1);

            x_result = sigma ? x_pipe[s] -
                               (circular_pipe[s] ? y_shift : '0)
                             : x_pipe[s] +
                               (circular_pipe[s] ? y_shift : '0);
            y_result = sigma ? y_pipe[s] + x_shift
                             : y_pipe[s] - x_shift;
            z_result = sigma ? z_pipe[s] - angle_step
                             : z_pipe[s] + angle_step;

            x_next[s+1] = x_result;
            y_next[s+1] = y_result;
            z_next[s+1] = zhold_pipe[s] ? z_pipe[s] : z_result;
            ovf_next[s+1] = ovf_pipe[s] |
                addsub_overflow(x_pipe[s],
                                circular_pipe[s] ? y_shift : '0, sigma) |
                addsub_overflow(y_pipe[s], x_shift, !sigma) |
                addsub_overflow(z_pipe[s], angle_step, sigma);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k <= ITER; k++) begin
                x_pipe[k] <= '0;
                y_pipe[k] <= '0;
                z_pipe[k] <= '0;
                valid_pipe[k] <= 1'b0;
                circular_pipe[k] <= 1'b0;
                vectoring_pipe[k] <= 1'b0;
                zhold_pipe[k] <= 1'b0;
                ovf_pipe[k] <= 1'b0;
            end
        end
        else begin
            for (int k = 0; k <= ITER; k++) begin
                x_pipe[k] <= x_next[k];
                y_pipe[k] <= y_next[k];
                z_pipe[k] <= z_next[k];
                valid_pipe[k] <= valid_next[k];
                circular_pipe[k] <= circular_next[k];
                vectoring_pipe[k] <= vectoring_next[k];
                zhold_pipe[k] <= zhold_next[k];
                ovf_pipe[k] <= ovf_next[k];
            end
        end
    end

    assign out_valid = valid_pipe[ITER];

    error_correction #(
        .WIDTH(WIDTH),
        .G(G)
    ) u_error_correction (
        .scale_en(circular_pipe[ITER]),
        .out_valid(out_valid),
        .x(x_pipe[ITER]),
        .y(y_pipe[ITER]),
        .z(z_pipe[ITER]),
        .x_corr(x_corr),
        .y_corr(y_corr),
        .z_corr(z),
        .sat(sat)
    );

    assign ovf = ovf_pipe[ITER] | (out_valid & sat);

endmodule
