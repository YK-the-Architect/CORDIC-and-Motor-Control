//Output stage. The lanes arrive WIDTH + 2 + G bits wide (2 headroom bits on top,
//G guard bits below). x and y get the gain correction x K in circular mode, then every
//lane is rounded once, half to even (banker's rounding, RTL change 4), back to WIDTH bits.
//x and y saturate instead of wrapping, and so does z in linear mode; in circular mode z is
//an angle and wraps by design. sat tells the ovf logic that a result was clamped.
module error_correction #(
    parameter WIDTH = 8,
    parameter G = 0                      // guard bits in the lanes
) (
    input   logic scale_en, out_valid,
    input   logic signed [WIDTH + 2 + G - 1 : 0] x, y, z,
    output  logic signed [WIDTH - 1 : 0] x_corr, y_corr, z_corr,
    output  logic sat
);
    localparam int IW = WIDTH + 2 + G;   // lane width
    //fraction bits of K. WIDTH + 2 keeps the error from K under 0.1 LSB; WIDTH + 2 + G was
    //no more accurate in tb_datatypes but cost about 900 more cells at W = 16 (15 terms vs 10)
    localparam int F = WIDTH + 2;
    localparam logic [F:0] C = (F + 1)'(int'(0.6072529 * (2.0 ** F))); //the correction factor
    localparam int AW = IW + F + 1;      // accumulator width
    localparam logic signed [AW-1:0] MAXV =  (AW'(1) <<< (WIDTH - 1)) - 1;   // +1.99994 at W = 16
    localparam logic signed [AW-1:0] MINV = -(AW'(1) <<< (WIDTH - 1));       // -2.0

    logic signed [AW-1:0] x_ext, x_acc, y_ext, y_acc, z_ext, xr, yr, zr;
    logic x_sat, y_sat, z_sat;

    //round half to even, dropping s fraction bits: round up when the first dropped bit is 1
    //and either a later dropped bit is 1 or the kept LSB is odd (round_up = g & (s | lsb))
    function automatic logic signed [AW-1:0] round_even(input logic signed [AW-1:0] v, input int s);
        logic signed [AW-1:0] q;
        logic [AW-1:0] below;
        if (s == 0) return v;
        q = v >>> s;
        below = v & ((AW'(1) << (s - 1)) - 1);
        return q + $signed(AW'(v[s - 1] & ((|below) | q[0])));
    endfunction

    always_comb begin
        x_ext = x;
        y_ext = y;
        z_ext = z;
        x_acc = '0;
        y_acc = '0;
        for (int k = 0; k <= F; k++)
            if (C[k])begin
                x_acc = x_acc + (x_ext <<< k);   // add a shifted copy for each set bit of C
                y_acc = y_acc + (y_ext <<< k);
            end
        if(out_valid && scale_en) begin      // circular: x K, then one rounding
            xr = round_even(x_acc, F + G);
            yr = round_even(y_acc, F + G);
        end
        else begin                            // linear (no gain) or not done yet: just round
            xr = round_even(x_ext, G);
            yr = round_even(y_ext, G);
        end
        zr = round_even(z_ext, G);

        //saturate x and y to the WIDTH-bit range
        x_sat = (xr > MAXV) || (xr < MINV);
        y_sat = (yr > MAXV) || (yr < MINV);
        x_corr = (xr > MAXV) ? MAXV[WIDTH-1:0] : (xr < MINV) ? MINV[WIDTH-1:0] : xr[WIDTH-1:0];
        y_corr = (yr > MAXV) ? MAXV[WIDTH-1:0] : (yr < MINV) ? MINV[WIDTH-1:0] : yr[WIDTH-1:0];

        //z: a number in linear mode (saturates), an angle in circular mode (wraps)
        if (out_valid && !scale_en) begin
            z_sat = (zr > MAXV) || (zr < MINV);
            z_corr = (zr > MAXV) ? MAXV[WIDTH-1:0] : (zr < MINV) ? MINV[WIDTH-1:0] : zr[WIDTH-1:0];
        end
        else begin
            z_sat = 1'b0;
            z_corr = zr[WIDTH-1:0];
        end
        sat = x_sat | y_sat | z_sat;
    end

endmodule
