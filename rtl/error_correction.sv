module error_correction #(
    parameter WIDTH = 8
) (
    input   logic scale_en, out_valid,
    input   logic signed [WIDTH - 1 : 0] x, y,
    output  logic signed [WIDTH - 1 : 0] x_corr, y_corr
);
    localparam int F = WIDTH + 2;
    localparam logic [F:0] C = (F + 1)'(int'(0.6072529 * (2.0 ** F))); //the correction factor

    logic signed [WIDTH+F:0] x_ext, x_acc, y_ext, y_acc;

    always_comb begin
        x_ext = x;
        y_ext = y;
        x_acc = '0;
        y_acc = '0;
        for (int k = 0; k <= F; k++)
            if (C[k])begin
                x_acc = x_acc + (x_ext <<< k);   // add a shifted copy for each set bit of C
                y_acc = y_acc + (y_ext <<< k);
            end   
        if(out_valid && scale_en) begin
            x_corr = (x_acc + (1 <<< (F - 1))) >>> F;
            y_corr = (y_acc + (1 <<< (F - 1))) >>> F;
        end
        else begin
            x_corr = x;
            y_corr = y;
        end
    end



endmodule