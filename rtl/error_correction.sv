//Output stage. The lanes arrive WIDTH + 2 + G bits wide (2 headroom bits on top,
//G guard bits below). x and y get the gain correction x K in circular mode, and all
//three lanes are rounded back to WIDTH bits here.
//Still to do (RTL changes 4 and 5): banker's rounding instead of round half up, and
//saturation with a sticky ovf instead of keeping the low WIDTH bits.
module error_correction #(
    parameter WIDTH = 8,
    parameter G = 0                      // guard bits in the lanes
) (
    input   logic scale_en, out_valid,
    input   logic signed [WIDTH + 2 + G - 1 : 0] x, y, z,
    output  logic signed [WIDTH - 1 : 0] x_corr, y_corr, z_corr
);
    localparam int IW = WIDTH + 2 + G;   // lane width
    //fraction bits of K. WIDTH + 2 keeps the error from K under 0.1 LSB; WIDTH + 2 + G was
    //no more accurate in tb_datatypes but cost about 900 more cells at W = 16 (15 terms vs 10)
    localparam int F = WIDTH + 2;
    localparam logic [F:0] C = (F + 1)'(int'(0.6072529 * (2.0 ** F))); //the correction factor

    logic signed [IW+F:0] x_ext, x_acc, y_ext, y_acc, z_ext;

    //round half up, then drop s fraction bits
    function automatic logic signed [IW+F:0] round_off(input logic signed [IW+F:0] v, input int s);
        if (s == 0) return v;
        return (v + ((IW+F+1)'(1) <<< (s - 1))) >>> s;
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
        if(out_valid && scale_en) begin
            x_corr = WIDTH'(round_off(x_acc, F + G));
            y_corr = WIDTH'(round_off(y_acc, F + G));
        end
        else begin
            x_corr = WIDTH'(round_off(x_ext, G));
            y_corr = WIDTH'(round_off(y_ext, G));
        end
        z_corr = WIDTH'(round_off(z_ext, G));
    end



endmodule
