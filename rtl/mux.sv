//multiplexer, 2 to 1: mux_out = sel1 when sel = 1, else sel0.
//The datapath uses one per lane to load a new operation (sel = init) and one to pick
//atan(2^-i) or 2^-i for the z lane (sel = m: circular or linear mode).
module cordic_mux #(
    parameter int WIDTH = 16
) (
    input  logic signed [WIDTH-1:0] sel1,    // x_in / y_in / z_in
    input  logic signed [WIDTH-1:0] sel0,   // x_next / y_next / z_next
    input  logic                    sel,  // init from control unit
    output logic signed [WIDTH-1:0] mux_out    // to register data input
);

    always_comb begin
        mux_out = sel ? sel1 : sel0;
    end

endmodule

