`timescale 1ps/1ps
module temp_tb();
    parameter WIDTH = 16;
    parameter ITER = 16;


    
    logic clk, rst;
    logic signed [WIDTH - 1 : 0]x_in, y_in, z_in;
    logic start;
    logic mode_cl, mode_rv;
    logic out_valid;
    logic signed [WIDTH - 1 : 0] x, y, z;

    cordic_ss#(.WIDTH(WIDTH), .ITER(ITER))dut(.*);

    initial clk = 0;
    initial forever #10 clk = ~clk;
    initial begin
        rst <= 0;
        repeat(5) @(posedge clk);
        rst <= 1;
        repeat(5) @(posedge clk);
        rst <= 0;
        repeat(5) @(posedge clk);
        for(int i = 0; i < 10; i++) begin
            x_in <= 10 - i;
            y_in <= i;
            z_in <= $urandom();
            start <= 1'b1;
            mode_cl <= $urandom();
            mode_rv <= $urandom();
            do @(posedge clk); while (!out_valid);
            $display("x_in:%h y_in:%h z_in:%h mode_cl:%h mode_rv:%h x_out:%h y_out:%h z_out:%h", x_in, y_in, z_in, mode_cl, mode_rv, x, y, z);
        end
        $finish();
    end

endmodule
