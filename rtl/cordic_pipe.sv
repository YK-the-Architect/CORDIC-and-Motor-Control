//Pipelined CORDIC engine: takes a new operation every clock and gives the same results as
//cordic_ss, bit for bit (tb_pipeline and tb_pipe_exhaustive check this).
//
//Every iteration has its own add/subs with a fixed shift and a fixed angle, so there is no
//barrel shifter, no angle table mux and no input mux. The gain correction x K is a carry-save
//tree plus one add, so it can be split across two stages. A register rank can sit at any of
//the ITER + 4 cut points (CUTS), so the same RTL gives every depth from 1 clock (all the logic
//between the inputs and the output register) to ITER + 5 clocks.
//
//Each operation carries its own mode bits, flags and tag down the pipeline, so the mode can
//change on every clock. Linear operations pass through the i = 0 stage unchanged (linear mode
//starts at i = 1), so every operation has the same latency and results leave in order.
//
//Handshake (valid/ready, as in AXI-Stream):
//  in:  an operation is taken on a clock with in_valid && in_ready
//  out: a result is taken on a clock with out_valid && out_ready. While out_valid is high and
//       out_ready is low, the result and its tag hold.
//Stalls: when the consumer stops taking results, every rank holds (one shared enable) and
//in_ready drops, so nothing is dropped, repeated or reordered. The 2-entry skid buffer at the
//output makes in_ready a register: there is no combinational path from out_ready to in_ready,
//and the enable that reaches every rank starts at a flop.
//Bubbles (clocks with no operation) need nothing special. Data registers load only for real
//operations, so empty stages do not toggle.
//There are no hazards inside: operations never feed each other. An operation that needs an
//earlier result (inverse Park after Park and PI, say) must wait until that result comes out;
//its tag tells the requester which result is which.
module cordic_pipe #(
    parameter int WIDTH = 16,
    parameter int ITER  = 16,
    parameter int G     = $clog2(ITER) + 1,   // guard bits, as in cordic_ss
    parameter int TAG_W = 4,                  // the tag comes back with the result
    //register cut points: bit 0 after the input stage, bit j (1 to ITER) after iteration j - 1,
    //bit ITER + 1 after the x K carry-save tree, bit ITER + 2 after the x K final add, bit
    //ITER + 3 after rounding. The output register is always there, so the latency is
    //(number of 1s in CUTS) + 1 clocks.
    parameter logic [ITER + 3 : 0] CUTS = '1,
    //1: valid/ready with stalls. 0: no stall support (in_ready = 1, out_ready ignored, data
    //registers load every clock); only there to measure what stall support costs.
    parameter bit STALL = 1
)(
    input  logic clk, rst,
    input  logic in_valid,
    output logic in_ready,
    input  logic mode_cl, mode_rv,
    input  logic signed [WIDTH - 1 : 0] x_in, y_in, z_in,
    input  logic [TAG_W - 1 : 0] in_tag,
    output logic out_valid,
    input  logic out_ready,
    output logic signed [WIDTH - 1 : 0] x_corr, y_corr, z,
    output logic ovf,
    output logic [TAG_W - 1 : 0] out_tag
);
    localparam int IW = WIDTH + 2 + G;        // lane width, as in cordic_ss
    localparam int F  = WIDTH + 2;            // fraction bits of K, as in error_correction
    localparam logic [F:0] C = (F + 1)'(int'(0.6072529 * (2.0 ** F)));
    localparam int AW = IW + F + 1;           // x K width, as in error_correction
    localparam int RW = WIDTH + 4;            // a rounded value always fits in WIDTH + 4 bits
    localparam int NC = ITER + 4;             // number of cut points
    localparam bit EN = STALL;
    localparam logic [IW - 1 : 0] ONE = IW'(1) << (WIDTH - 1 + G);   // 1.0 in the z lane (linear)
    localparam logic signed [RW - 1 : 0] MAXV =  (RW'(1) <<< (WIDTH - 1)) - 1;
    localparam logic signed [RW - 1 : 0] MINV = -(RW'(1) <<< (WIDTH - 1));

    //what an operation carries from stage to stage
    typedef struct packed {                   // through the iterations
        logic cl, rv, zh, ov;                 // modes, zero-vector hold, sticky overflow
        logic [TAG_W - 1 : 0] tag;
        logic signed [IW - 1 : 0] x, y, z;
    } lane_t;
    typedef struct packed {                   // after the x K carry-save tree
        logic cl, ov;
        logic [TAG_W - 1 : 0] tag;
        logic [AW - 1 : 0] xs, xc, ys, yc;    // x K = xs + xc and y K = ys + yc (mod 2^AW)
        logic signed [IW - 1 : 0] z;
    } csa_t;
    typedef struct packed {                   // after x K
        logic cl, ov;
        logic [TAG_W - 1 : 0] tag;
        logic signed [AW - 1 : 0] x, y;
        logic signed [IW - 1 : 0] z;
    } prod_t;
    typedef struct packed {                   // after rounding
        logic cl, ov;
        logic [TAG_W - 1 : 0] tag;
        logic signed [RW - 1 : 0] x, y, z;
    } rnd_t;
    typedef struct packed {                   // the result
        logic ov;
        logic [TAG_W - 1 : 0] tag;
        logic signed [WIDTH - 1 : 0] x, y, z;
    } res_t;

    logic  adv;                               // every rank moves on this clock
    logic  v_d [NC] /*verilator split_var*/;  // valid into and out of each cut point
    logic  v_q [NC] /*verilator split_var*/;
    lane_t it_d [ITER + 1] /*verilator split_var*/;   // [0] input stage, [i + 1] after iteration i
    lane_t it_q [ITER + 1] /*verilator split_var*/;   // the same after its cut point
    lane_t in_s;
    csa_t  cs_d, cs_q;
    prod_t pr_d, pr_q;
    rnd_t  rn_d, rn_q;
    res_t  res_d;

    //input stage: the same pre-rotation and flags as datapath and cordic_ss
    function automatic logic [WIDTH : 0] mag(input logic signed [WIDTH - 1 : 0] v);
        logic signed [WIDTH : 0] w;
        w = v;
        return w < 0 ? -w : w;
    endfunction

    logic fold, neg_xy;
    logic signed [IW - 1 : 0] x_in_ext, y_in_ext;
    logic signed [WIDTH - 1 : 0] z_in_folded;
    assign fold        = !mode_cl && (mode_rv ? x_in[WIDTH - 1] : ^z_in[WIDTH - 1 : WIDTH - 2]);
    assign neg_xy      = fold || (mode_cl && mode_rv && x_in[WIDTH - 1]);
    assign x_in_ext    = IW'(x_in) <<< G;
    assign y_in_ext    = IW'(y_in) <<< G;
    assign z_in_folded = fold ? {~z_in[WIDTH - 1], z_in[WIDTH - 2 : 0]} : z_in;
    always_comb begin
        in_s.cl  = mode_cl;
        in_s.rv  = mode_rv;
        in_s.zh  = !mode_cl && mode_rv && (x_in == '0) && (y_in == '0);
        in_s.ov  = mode_cl && mode_rv && (mag(y_in) >= mag(x_in));    // divide out of range
        in_s.tag = in_tag;
        in_s.x   = neg_xy ? -x_in_ext : x_in_ext;
        in_s.y   = neg_xy ? -y_in_ext : y_in_ext;
        in_s.z   = IW'(z_in_folded) <<< G;
    end
    assign it_d[0] = in_s;
    assign v_d[0]  = in_valid;

    //one stage per iteration: fixed shift, fixed angle, and the same add/subs, direction rule
    //and overflow flags as one clock of the datapath in cordic_ss
    logic [IW - 1 : 0] atan_tbl [ITER];
    atan_rom #(.WIDTH(IW), .ITER(ITER), .ANGLE_BITS(WIDTH + G)) u_atan_rom (.atan_out(atan_tbl));

    for (genvar i = 0; i < ITER; i++) begin : g_iter
        lane_t a, b;
        logic sigma, skip, x_o, y_o, z_o;
        logic signed [IW - 1 : 0] xs, ysh, ys, zang, x_s, y_s, z_s;
        assign a     = it_q[i];
        assign skip  = a.cl && (i == 0);                  // linear mode starts at i = 1
        assign sigma = a.rv ? a.y[IW - 1] : ~a.z[IW - 1]; // vectoring: sign of y, rotation: sign of z
        assign xs    = $signed(a.x) >>> i;
        assign ysh   = $signed(a.y) >>> i;
        assign ys    = a.cl ? '0 : ysh;                   // linear mode: x does not change
        assign zang  = a.cl ? $signed(ONE >> i) : $signed(atan_tbl[i]);
        add_sub #(.WIDTH(IW)) u_x (.a(a.x), .b(ys),   .add_sub(sigma),  .sum_diff(x_s), .overflow(x_o));
        add_sub #(.WIDTH(IW)) u_y (.a(a.y), .b(xs),   .add_sub(!sigma), .sum_diff(y_s), .overflow(y_o));
        add_sub #(.WIDTH(IW)) u_z (.a(a.z), .b(zang), .add_sub(sigma),  .sum_diff(z_s), .overflow(z_o));
        always_comb begin
            b = a;
            if (!skip) begin
                b.x  = x_s;
                b.y  = y_s;
                if (!a.zh) b.z = z_s;                     // zero vector: z holds
                b.ov = a.ov | x_o | y_o | z_o;
            end
        end
        assign it_d[i + 1] = b;
        assign v_d[i + 1]  = v_q[i];
    end

    for (genvar j = 0; j <= ITER; j++) begin : g_cut
        pipe_cut #(.W($bits(lane_t)), .REG(CUTS[j]), .EN(EN)) u_cut (
            .clk, .rst, .adv, .v_d(v_d[j]), .d(it_d[j]), .v_q(v_q[j]), .q(it_q[j]));
    end

    //output stage, step 1: x K for circular operations, as a carry-save pair. K is written in
    //non-adjacent form (digits +1, 0, -1, never two non-zero side by side): 7 shifted copies of x
    //at F = 18 instead of the 10 set bits error_correction adds. -(x << k) is ~(x << k) + 1, and
    //all those +1s go into one constant. A tree of 3:2 compressors reduces the copies to two
    //numbers; their one carry-propagate add is step 2. The integer result is exactly
    //error_correction's sum. Linear operations get (x << F, 0) instead, which puts them on the
    //same scale, so one rounding of F + G bits gives exactly error_correction's rounding of G bits.
    function automatic int naf_digit(input int c, input int k);   // digit k of c in that form
        int v, d;
        v = c;
        d = 0;
        for (int j = 0; j <= k; j++) begin
            if (v % 2 != 0) begin
                d = 2 - (v % 4);              // +1 when v mod 4 = 1, -1 when v mod 4 = 3
                v = v - d;
            end else d = 0;
            v = v / 2;
        end
        return d;
    endfunction
    localparam int ND = F + 2;                // digits of K in that form
    function automatic int naf_count(input int c, input int sign);  // digits that are +1 (sign 1), -1 (-1) or either (0)
        int n;
        n = 0;
        for (int k = 0; k < ND; k++)
            if (naf_digit(c, k) != 0 && (sign == 0 || naf_digit(c, k) == sign)) n++;
        return n;
    endfunction
    function automatic int naf_pos(input int c, input int t);       // position of the t-th non-zero digit
        int n;
        n = 0;
        for (int k = 0; k < ND; k++)
            if (naf_digit(c, k) != 0) begin
                if (n == t) return k;
                n++;
            end
        return 0;
    endfunction
    localparam int NT   = naf_count(int'(C), 0);   // shifted copies
    localparam int NNEG = naf_count(int'(C), -1);  // of them negative

    lane_t ls;
    logic signed [AW - 1 : 0] kxe, kye;
    logic [NT : 0][AW - 1 : 0] kx_in, ky_in;
    logic [AW - 1 : 0] kx_s, kx_c, ky_s, ky_c;
    assign ls  = it_q[ITER];
    assign kxe = $signed(ls.x);
    assign kye = $signed(ls.y);
    for (genvar t = 0; t < NT; t++) begin : g_kterm
        localparam int  P   = naf_pos(int'(C), t);
        localparam bit  NEG = naf_digit(int'(C), P) < 0;
        assign kx_in[t] = NEG ? ~(kxe <<< P) : (kxe <<< P);
        assign ky_in[t] = NEG ? ~(kye <<< P) : (kye <<< P);
    end
    assign kx_in[NT] = AW'(NNEG);
    assign ky_in[NT] = AW'(NNEG);
    csa_tree #(.N(NT + 1), .W(AW)) u_kx (.in(kx_in), .s(kx_s), .c(kx_c));
    csa_tree #(.N(NT + 1), .W(AW)) u_ky (.in(ky_in), .s(ky_s), .c(ky_c));
    always_comb begin
        cs_d.cl  = ls.cl;
        cs_d.ov  = ls.ov;
        cs_d.tag = ls.tag;
        cs_d.z   = ls.z;
        cs_d.xs  = ls.cl ? AW'(kxe <<< F) : kx_s;
        cs_d.xc  = ls.cl ? '0 : kx_c;
        cs_d.ys  = ls.cl ? AW'(kye <<< F) : ky_s;
        cs_d.yc  = ls.cl ? '0 : ky_c;
    end
    assign v_d[ITER + 1] = v_q[ITER];
    pipe_cut #(.W($bits(csa_t)), .REG(CUTS[ITER + 1]), .EN(EN)) u_cut_c (
        .clk, .rst, .adv, .v_d(v_d[ITER + 1]), .d(cs_d), .v_q(v_q[ITER + 1]), .q(cs_q));

    //output stage, step 2: the carry-propagate add of x K
    always_comb begin
        pr_d.cl  = cs_q.cl;
        pr_d.ov  = cs_q.ov;
        pr_d.tag = cs_q.tag;
        pr_d.z   = cs_q.z;
        pr_d.x   = cs_q.xs + cs_q.xc;
        pr_d.y   = cs_q.ys + cs_q.yc;
    end
    assign v_d[ITER + 2] = v_q[ITER + 1];
    pipe_cut #(.W($bits(prod_t)), .REG(CUTS[ITER + 2]), .EN(EN)) u_cut_k (
        .clk, .rst, .adv, .v_d(v_d[ITER + 2]), .d(pr_d), .v_q(v_q[ITER + 2]), .q(pr_q));

    //output stage, step 3: one round half to even, as in error_correction
    function automatic logic signed [AW - 1 : 0] round_even(input logic signed [AW - 1 : 0] v, input int s);
        logic signed [AW - 1 : 0] q;
        logic [AW - 1 : 0] below;
        if (s == 0) return v;
        q = v >>> s;
        below = v & ((AW'(1) << (s - 1)) - 1);
        return q + $signed(AW'(v[s - 1] & ((|below) | q[0])));
    endfunction

    always_comb begin
        logic signed [AW - 1 : 0] xr, yr, zr, ze;
        xr = round_even($signed(pr_q.x), F + G);
        yr = round_even($signed(pr_q.y), F + G);
        ze = $signed(pr_q.z);
        zr = round_even(ze, G);
        rn_d.cl  = pr_q.cl;
        rn_d.ov  = pr_q.ov;
        rn_d.tag = pr_q.tag;
        rn_d.x   = xr[RW - 1 : 0];
        rn_d.y   = yr[RW - 1 : 0];
        rn_d.z   = zr[RW - 1 : 0];
    end
    assign v_d[ITER + 3] = v_q[ITER + 2];
    pipe_cut #(.W($bits(rnd_t)), .REG(CUTS[ITER + 3]), .EN(EN)) u_cut_r (
        .clk, .rst, .adv, .v_d(v_d[ITER + 3]), .d(rn_d), .v_q(v_q[ITER + 3]), .q(rn_q));

    //output stage, step 4: x and y saturate; z saturates in linear mode and wraps in circular
    always_comb begin
        logic xh, xl, yh, yl, zh, zl;
        xh = $signed(rn_q.x) > MAXV;
        xl = $signed(rn_q.x) < MINV;
        yh = $signed(rn_q.y) > MAXV;
        yl = $signed(rn_q.y) < MINV;
        zh = $signed(rn_q.z) > MAXV;
        zl = $signed(rn_q.z) < MINV;
        res_d.x   = xh ? MAXV[WIDTH - 1 : 0] : xl ? MINV[WIDTH - 1 : 0] : rn_q.x[WIDTH - 1 : 0];
        res_d.y   = yh ? MAXV[WIDTH - 1 : 0] : yl ? MINV[WIDTH - 1 : 0] : rn_q.y[WIDTH - 1 : 0];
        res_d.z   = !rn_q.cl ? rn_q.z[WIDTH - 1 : 0]
                  : zh ? MAXV[WIDTH - 1 : 0] : zl ? MINV[WIDTH - 1 : 0] : rn_q.z[WIDTH - 1 : 0];
        res_d.ov  = rn_q.ov | xh | xl | yh | yl | (rn_q.cl & (zh | zl));
        res_d.tag = rn_q.tag;
    end

    //output register plus one skid entry (STALL = 1), or a plain output register (STALL = 0)
    res_t m_q, s_q;
    logic m_v, s_v, push;
    assign push = adv && v_q[NC - 1];
    if (STALL) begin : g_skid
        assign adv = !s_v;                    // a flop: in_ready never depends on out_ready
        always_ff @(posedge clk) begin
            if (rst) begin
                m_v <= 1'b0;
                s_v <= 1'b0;
            end else begin
                m_v <= s_v || push || (m_v && !out_ready);
                s_v <= (s_v && !out_ready) || (m_v && !out_ready && push);
            end
        end
        always_ff @(posedge clk) begin
            if ((!m_v || out_ready) && (s_v || push)) m_q <= s_v ? s_q : res_d;  // refill the output
            if (m_v && !out_ready && push)            s_q <= res_d;              // park the one in flight
        end
    end else begin : g_free
        assign adv = 1'b1;
        assign s_v = 1'b0;
        assign s_q = '0;
        always_ff @(posedge clk) begin
            if (rst) m_v <= 1'b0;
            else     m_v <= v_q[NC - 1];
        end
        always_ff @(posedge clk) m_q <= res_d;
    end
    assign in_ready  = adv;
    assign out_valid = m_v;
    assign x_corr    = m_q.x;
    assign y_corr    = m_q.y;
    assign z         = m_q.z;
    assign ovf       = m_q.ov;
    assign out_tag   = m_q.tag;

endmodule
