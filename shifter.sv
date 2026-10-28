// barrel shifter: arithmetic right shift, data_out = data_in >>> shift_amt
// the datapath uses two of these: x >> i and y >> i
// built as SHIFT_W layers: layer k shifts by 2^k when shift_amt[k] = 1,
// so together the layers cover every shift from 0 to 2^SHIFT_W - 1
// purely combinational: no clock, no reset
module shifter #(
    parameter WIDTH   = 8,               // bits in data_in and data_out
    parameter SHIFT_W = $clog2(WIDTH)    // bits in shift_amt
)(
    input  logic signed [WIDTH - 1 : 0]   data_in,
    input  logic        [SHIFT_W - 1 : 0] shift_amt,
    output logic signed [WIDTH - 1 : 0]   data_out
);

// layer[0] is the input, layer[k + 1] is the value after layer k
logic signed [WIDTH - 1 : 0] layer [0 : SHIFT_W];

assign layer[0] = data_in;

for (genvar k = 0; k < SHIFT_W; k++) begin : g_layer
    // shift by 2^k or pass straight through: one row of 2:1 muxes
    assign layer[k + 1] = shift_amt[k] ? (layer[k] >>> (2 ** k)) : layer[k];
end

assign data_out = layer[SHIFT_W];

endmodule
