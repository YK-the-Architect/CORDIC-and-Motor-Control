//barrel shifter: arithmetic right shift, data_out = data_in >>> shift_amt
module shifter #(parameter WIDTH = 8, parameter SHIFT_W = $clog2(WIDTH))(
    input  logic signed [WIDTH - 1 : 0]   data_in,
    input  logic        [SHIFT_W - 1 : 0] shift_amt,
    output logic signed [WIDTH - 1 : 0]   data_out
);

//layer k shifts by 2^k when shift_amt[k] = 1
logic signed [WIDTH - 1 : 0] layer [0 : SHIFT_W];

assign layer[0] = data_in;

for (genvar k = 0; k < SHIFT_W; k++) begin : g_layer
    assign layer[k + 1] = shift_amt[k] ? (layer[k] >>> (2 ** k)) : layer[k];
end

assign data_out = layer[SHIFT_W];

endmodule