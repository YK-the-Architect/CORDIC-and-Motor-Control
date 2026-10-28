//multiplexer
module cordic_mux #(
    parameter int WIDTH = 16
) (
    input  logic signed [WIDTH-1:0] in_ext,    // x_in / y_in / z_in
    input  logic signed [WIDTH-1:0] in_next,   // x_next / y_next / z_next
    input  logic                    sel_init,  // init from control unit
    output logic signed [WIDTH-1:0] mux_out    // to register data input
);

    always_comb begin
        mux_out = sel_init ? in_ext : in_next;
    end

endmodule

