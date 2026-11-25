//add/subtract with overflow flag, one per lane of the datapath (and of each pipeline iteration).
//sum_diff = a + b (add_sub = 0) or a - b (add_sub = 1), wrapping to WIDTH bits. The operation is done
//on WIDTH + 1 bits; overflow = 1 when the true result does not fit in WIDTH bits.
module add_sub #(parameter int WIDTH = 8) (
    input  logic signed [WIDTH-1:0] a,
    input  logic signed [WIDTH-1:0] b,
    input  logic                    add_sub,    // 0 = add, 1 = subtract
    output logic signed [WIDTH-1:0] sum_diff,
    output logic                    overflow
);
    
    logic signed [WIDTH:0] a_ext, b_ext, r_ext;

    assign a_ext = {a[WIDTH-1], a};     // sign-extend by one bit
    assign b_ext = {b[WIDTH-1], b};

    assign r_ext = add_sub ? (a_ext - b_ext) : (a_ext + b_ext);

    assign sum_diff = r_ext[WIDTH-1:0];
    //the top two bits differ only when the result is outside the WIDTH-bit range
    assign overflow = (r_ext[WIDTH] != r_ext[WIDTH-1]);
endmodule