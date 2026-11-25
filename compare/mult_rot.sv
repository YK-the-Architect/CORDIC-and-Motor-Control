//Multiplier-based rotation, only for comparison with CORDIC (docs/pipeline_ppa.md). It is not
//part of the engine. Same job and formats as cordic_pipe in circular rotation mode:
//  x_out = x cos z - y sin z,  y_out = x sin z + y cos z
//x, y in Q2.(WIDTH-2), z a binary angle (2^WIDTH = 360 deg). sin and cos come from a
//quarter-wave table (compare/sin_table.sv, 128 intervals) with linear interpolation, then four
//signed multiplies. Each multiply is its partial products summed in a carry-save tree (the same
//technique as the x K step of cordic_pipe), with the carry-propagate add in the next stage, and
//the result is rounded half to even and saturated like cordic_pipe's.
//One rotation per clock, 6 clocks of latency, no stall support (compare with cordic_pipe STALL = 0).
module mult_rot #(parameter int WIDTH = 16) (
    input  logic clk, rst,
    input  logic in_valid,
    input  logic signed [WIDTH - 1 : 0] x_in, y_in, z_in,
    output logic out_valid,
    output logic signed [WIDTH - 1 : 0] x_out, y_out
);
    import sin_table::*;
    localparam int FB = WIDTH - 2 - TB;           // phase bits below the table index
    localparam int CW = TW;                       // sin, cos: SC fraction bits, +1.0 fits
    localparam int PW = WIDTH + CW + 1;           // x cos - y sin, one bit to spare
    localparam int RW = PW - SC;                  // after dropping SC fraction bits
    localparam logic signed [RW - 1 : 0] MAXV =  (RW'(1) <<< (WIDTH - 1)) - 1;
    localparam logic signed [RW - 1 : 0] MINV = -(RW'(1) <<< (WIDTH - 1));

    //stage 1: quadrant; table index and fraction for phi and for 90 deg - phi
    logic [1 : 0] q;
    logic [WIDTH - 2 : 0] ph, phm;                // 2^(WIDTH - 2) = 90 deg
    assign q   = z_in[WIDTH - 1 : WIDTH - 2];
    assign ph  = {1'b0, z_in[WIDTH - 3 : 0]};
    assign phm = (WIDTH - 1)'(1 << (WIDTH - 2)) - ph;
    logic v1;
    logic [1 : 0] q1;
    logic signed [WIDTH - 1 : 0] x1, y1;
    logic [FB - 1 : 0] f1, fm1;
    logic [TW - 1 : 0] ts1, tc1;
    logic [DW - 1 : 0] ds1, dc1;
    always_ff @(posedge clk) begin
        v1  <= rst ? 1'b0 : in_valid;
        q1  <= q;
        x1  <= x_in;
        y1  <= y_in;
        f1  <= ph[FB - 1 : 0];
        fm1 <= phm[FB - 1 : 0];
        ts1 <= sin_t(ph[WIDTH - 2 : FB]);
        ds1 <= sin_d(ph[WIDTH - 2 : FB]);
        tc1 <= sin_t(phm[WIDTH - 2 : FB]);
        dc1 <= sin_d(phm[WIDTH - 2 : FB]);
    end

    //stage 2: linear interpolation: S = sin(phi), C = cos(phi) = sin(90 deg - phi)
    logic v2;
    logic [1 : 0] q2;
    logic signed [WIDTH - 1 : 0] x2, y2;
    logic [TW - 1 : 0] s2, c2;
    always_ff @(posedge clk) begin
        v2 <= rst ? 1'b0 : v1;
        q2 <= q1;
        x2 <= x1;
        y2 <= y1;
        s2 <= ts1 + TW'((ds1 * f1 + (1 << (FB - 1))) >> FB);
        c2 <= tc1 + TW'((dc1 * fm1 + (1 << (FB - 1))) >> FB);
    end

    //stage 3: the quadrant's signs: sin, cos and -sin
    logic v3;
    logic signed [WIDTH - 1 : 0] x3, y3;
    logic signed [CW - 1 : 0] sn3, cs3, ns3;
    always_ff @(posedge clk) begin
        logic signed [CW - 1 : 0] S, C;
        S = $signed(s2);
        C = $signed(c2);
        v3 <= rst ? 1'b0 : v2;
        x3 <= x2;
        y3 <= y2;
        case (q2)
            2'd0:    begin sn3 <=  S; cs3 <=  C; ns3 <= -S; end
            2'd1:    begin sn3 <=  C; cs3 <= -S; ns3 <= -C; end
            2'd2:    begin sn3 <= -S; cs3 <= -C; ns3 <=  S; end
            default: begin sn3 <= -C; cs3 <=  S; ns3 <=  C; end
        endcase
    end

    //stage 4: partial products of x cos + y (-sin) and x sin + y cos, carry-save trees
    logic signed [PW - 1 : 0] cse, sne, nse;
    logic [2 * WIDTH : 0][PW - 1 : 0] px, py;
    logic [PW - 1 : 0] xs_d, xc_d, ys_d, yc_d;
    assign cse = cs3;
    assign sne = sn3;
    assign nse = ns3;
    for (genvar k = 0; k < WIDTH; k++) begin : g_pp
        if (k < WIDTH - 1) begin : g_pos
            assign px[k]         = x3[k] ? (cse <<< k) : '0;
            assign px[WIDTH + k] = y3[k] ? (nse <<< k) : '0;
            assign py[k]         = x3[k] ? (sne <<< k) : '0;
            assign py[WIDTH + k] = y3[k] ? (cse <<< k) : '0;
        end else begin : g_sign                   // the sign bit weighs -2^(WIDTH-1): ~(b << k), +1 below
            assign px[k]         = x3[k] ? ~(cse <<< k) : '0;
            assign px[WIDTH + k] = y3[k] ? ~(nse <<< k) : '0;
            assign py[k]         = x3[k] ? ~(sne <<< k) : '0;
            assign py[WIDTH + k] = y3[k] ? ~(cse <<< k) : '0;
        end
    end
    assign px[2 * WIDTH] = PW'(x3[WIDTH - 1]) + PW'(y3[WIDTH - 1]);
    assign py[2 * WIDTH] = PW'(x3[WIDTH - 1]) + PW'(y3[WIDTH - 1]);
    csa_tree #(.N(2 * WIDTH + 1), .W(PW)) u_tx (.in(px), .s(xs_d), .c(xc_d));
    csa_tree #(.N(2 * WIDTH + 1), .W(PW)) u_ty (.in(py), .s(ys_d), .c(yc_d));
    logic v4;
    logic [PW - 1 : 0] xs4, xc4, ys4, yc4;
    always_ff @(posedge clk) begin
        v4  <= rst ? 1'b0 : v3;
        xs4 <= xs_d;
        xc4 <= xc_d;
        ys4 <= ys_d;
        yc4 <= yc_d;
    end

    //stage 5: carry-propagate adds
    logic v5;
    logic signed [PW - 1 : 0] x5, y5;
    always_ff @(posedge clk) begin
        v5 <= rst ? 1'b0 : v4;
        x5 <= xs4 + xc4;
        y5 <= ys4 + yc4;
    end

    //stage 6: round half to even (drop SC bits) and saturate
    function automatic logic [WIDTH : 0] rnd_sat(input logic signed [PW - 1 : 0] v);   // {sat, value}
        logic signed [RW - 1 : 0] q;
        q = RW'(v >>> SC) + RW'(v[SC - 1] & ((|v[SC - 2 : 0]) | v[SC]));
        if (q > MAXV) return {1'b1, MAXV[WIDTH - 1 : 0]};
        if (q < MINV) return {1'b1, MINV[WIDTH - 1 : 0]};
        return {1'b0, q[WIDTH - 1 : 0]};
    endfunction
    always_ff @(posedge clk) begin
        logic [WIDTH : 0] rx, ry;
        rx = rnd_sat(x5);
        ry = rnd_sat(y5);
        out_valid <= rst ? 1'b0 : v5;
        x_out     <= rx[WIDTH - 1 : 0];
        y_out     <= ry[WIDTH - 1 : 0];
    end
endmodule
