module one_shifted #(
    parameter int WIDTH = 8,
    parameter int ITER  = 8,          // new: lets datapath pass ITER in
    parameter int FRAC  = WIDTH - 1   // bit position of 1.0; WIDTH - 1 is the plain Q1.(WIDTH-1) format
)(
    input  logic [$clog2(ITER)-1:0] i,           // iteration counter
    output logic [WIDTH-1:0]        one_l_shift  // 2^-i
);
    localparam logic [WIDTH-1:0] ONE = WIDTH'(1) << FRAC;  // 1.0, a fixed constant
    assign one_l_shift = ONE >> i;
endmodule
