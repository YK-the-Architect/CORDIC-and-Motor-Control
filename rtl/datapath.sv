module datapath #(
    parameter WIDTH = 8,
    parameter ITER = 8,
    parameter G = $clog2(ITER) + 1 )(   // guard bits below the LSB (RTL change 3), set by cordic_ss
    input logic clk, rst,
    //control unit inputs
    input logic init, en, sigma, m,
    input logic [$clog2(ITER) - 1 : 0] i,
    input logic signed [WIDTH - 1 : 0] x_in, y_in, z_in,
    //lanes leave at full internal width; the output stage rounds them back to WIDTH bits
    output logic signed [WIDTH + 2 + G - 1 : 0] x, y, z
    );
    //lane width (RTL change 3): WIDTH plus 2 headroom bits on top, so x and y can grow
    //by the CORDIC gain (1.647 * sqrt(2) at most) without overflowing, plus G guard bits
    //below, so the rounding error of N iterations stays below the output LSB
    localparam int IW = WIDTH + 2 + G;

    //wires between blocks
    logic signed [IW - 1 : 0] x_mux_2_reg, y_mux_2_reg, z_mux_2_reg;
    logic signed [IW - 1 : 0] x_as_2_mux, y_as_2_mux, z_as_2_mux;
    logic signed [IW - 1 : 0] xlane_shift, ylane_shift, ylane_shift_gated;
    logic signed [WIDTH - 1 : 0] x_in_folded, y_in_folded, z_in_folded;
    logic signed [IW - 1 : 0] x_in_lane, y_in_lane, z_in_lane;
    logic signed [IW - 1 : 0] z_angle_mux_2_as;
    logic signed [IW - 1 : 0] one_l_shift;
    logic [IW-1 : 0] atan_tbl[ITER]; // This outputs an array

    assign x_in_folded = ^z_in[WIDTH - 1 : WIDTH - 2] ? -x_in : x_in;
    assign y_in_folded = ^z_in[WIDTH - 1 : WIDTH - 2] ? -y_in : y_in;
    assign z_in_folded = ^z_in[WIDTH - 1 : WIDTH - 2] ? {~z_in[WIDTH - 1], z_in[WIDTH - 2 : 0]} : z_in;

    //inputs enter the lanes: sign-extended into the headroom bits, guard bits start at 0
    assign x_in_lane = IW'(x_in_folded) <<< G;
    assign y_in_lane = IW'(y_in_folded) <<< G;
    assign z_in_lane = IW'(z_in_folded) <<< G;

    //input muxes
    cordic_mux #(.WIDTH(IW)) x_mux(.sel0(x_as_2_mux), .sel1(x_in_lane), .sel(init), .mux_out(x_mux_2_reg));
    cordic_mux #(.WIDTH(IW)) y_mux(.sel0(y_as_2_mux), .sel1(y_in_lane), .sel(init), .mux_out(y_mux_2_reg));
    cordic_mux #(.WIDTH(IW)) z_mux(.sel0(z_as_2_mux), .sel1(z_in_lane), .sel(init), .mux_out(z_mux_2_reg));
    //z mux angle sel
    cordic_mux #(.WIDTH(IW)) z_angle_mux(.sel0(one_l_shift), .sel1($signed(atan_tbl[i])), .sel(m), .mux_out(z_angle_mux_2_as));

    //x y z registers
    sync_reg #(.WIDTH(IW)) x_reg(.clk(clk), .rst(rst), .en(en), .data_in(x_mux_2_reg), .data_out(x));
    sync_reg #(.WIDTH(IW)) y_reg(.clk(clk), .rst(rst), .en(en), .data_in(y_mux_2_reg), .data_out(y));
    sync_reg #(.WIDTH(IW)) z_reg(.clk(clk), .rst(rst), .en(en), .data_in(z_mux_2_reg), .data_out(z));

    //add sub
    add_sub #(.WIDTH(IW)) x_lane(.a(x), .b(ylane_shift_gated), .add_sub(sigma),  .sum_diff(x_as_2_mux), .overflow());
    add_sub #(.WIDTH(IW)) y_lane(.a(y), .b(xlane_shift), .add_sub(!sigma), .sum_diff(y_as_2_mux), .overflow());
    add_sub #(.WIDTH(IW)) z_lane(.a(z), .b(z_angle_mux_2_as), .add_sub(sigma),  .sum_diff(z_as_2_mux), .overflow());

    //shifters
    shifter #(.WIDTH(IW), .SHIFT_W($clog2(ITER))) x_lane_shift(.data_in(x), .shift_amt(i), .data_out(xlane_shift));
    shifter #(.WIDTH(IW), .SHIFT_W($clog2(ITER))) y_lane_shift(.data_in(y), .shift_amt(i), .data_out(ylane_shift));
    assign ylane_shift_gated = m ? ylane_shift : '0;

    //atan(2^-i) with the guard bits too: 2^(WIDTH + G) = 360 degrees inside the z lane
    atan_rom #(.WIDTH(IW), .ITER(ITER), .ANGLE_BITS(WIDTH + G)) u_atan_rom(.atan_out(atan_tbl));
    //2^-i for linear mode: 1.0 sits at bit WIDTH - 1 + G inside the z lane
    one_shifted #(.WIDTH(IW), .ITER(ITER), .FRAC(WIDTH - 1 + G)) u_one_shifted(.i(i), .one_l_shift(one_l_shift));
endmodule
