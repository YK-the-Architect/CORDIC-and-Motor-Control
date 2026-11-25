//Carry-save adder tree: reduces N numbers to two, s and c, with 3:2 compressors (full adders,
//no carry chain), so it is only about log1.5(N) full adders deep. s + c (mod 2^W) is the sum
//of the inputs; the one carry-propagate add can then sit in the next pipeline stage.
module csa_tree #(
    parameter int N = 3,
    parameter int W = 8
)(
    input  logic [N - 1 : 0][W - 1 : 0] in,
    output logic [W - 1 : 0] s, c
);
    localparam int G3 = N / 3;            // groups of three
    localparam int NR = N % 3;            // left over, passed down
    localparam int NN = 2 * G3 + NR;      // numbers after this level

    if (N == 1) begin : g_one
        assign s = in[0];
        assign c = '0;
    end else if (N == 2) begin : g_two
        assign s = in[0];
        assign c = in[1];
    end else begin : g_level
        logic [NN - 1 : 0][W - 1 : 0] nxt;
        for (genvar k = 0; k < G3; k++) begin : g_fa
            assign nxt[2 * k]     = in[3 * k] ^ in[3 * k + 1] ^ in[3 * k + 2];
            assign nxt[2 * k + 1] = ((in[3 * k] & in[3 * k + 1]) | (in[3 * k] & in[3 * k + 2]) |
                                     (in[3 * k + 1] & in[3 * k + 2])) << 1;
        end
        for (genvar k = 0; k < NR; k++) begin : g_pass
            assign nxt[2 * G3 + k] = in[3 * G3 + k];
        end
        csa_tree #(.N(NN), .W(W)) u_next (.in(nxt), .s(s), .c(c));
    end
endmodule
