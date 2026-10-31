//synchronous register
module sync_reg #(parameter WIDTH = 8)(
    input logic clk, rst, en,
    input logic [WIDTH - 1 : 0] data_in,
    output logic [WIDTH - 1 :0] data_out
);

always_ff @ (posedge clk) begin
    if(rst) data_out <= 0;
    else if (en) data_out <= data_in;
end
endmodule