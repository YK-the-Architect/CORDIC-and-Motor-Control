
module add_sub #(parameter int WIDTH = 8) (
    input  logic signed [WIDTH-1:0] a,
    input  logic signed [WIDTH-1:0] b,
    input  logic                    add_sub,    // 0 = add, 1 = subtract
    output logic signed [WIDTH-1:0] sum_diff,
    output logic                    overflow
);
    
    logic signed [WIDTH:0] a_ext, b_ext, r_ext;

    assign a_ext = {a[WIDTH-1], a};     
    assign b_ext = {b[WIDTH-1], b};    

    assign r_ext = add_sub ? (a_ext - b_ext) : (a_ext + b_ext);

    assign sum_diff = r_ext[WIDTH-1:0];           
    assign overflow = (r_ext[WIDTH] != r_ext[WIDTH-1]);  
endmodule