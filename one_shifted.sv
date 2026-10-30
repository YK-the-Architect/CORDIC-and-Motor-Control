module one_shifted #(
    WIDTH = 8
)
(   input  logic [$clog2(ITER) - 1 : 0] i,
    output logic [WIDTH - 1 : 0] one_l_shift);
    logic [WIDTH - 2 : 0] t;
    logic [WIDTH - 1 : 0] t2;
    assign t2 = {1'b1, t};
    assign one_l_shift = t2 >> i;
endmodule