`timescale 1ns/1ps
// tb/oop/cordic_if.sv : the pins of cordic_pipe, for the class-based testbench (cordic_pkg.sv).
interface cordic_if #(parameter int W = 16) (input logic clk);
  logic rst;
  logic in_valid, in_ready, mode_cl, mode_rv;
  logic signed [W-1:0] x_in, y_in, z_in;
  logic [3:0] in_tag;
  logic out_valid, out_ready;
  logic signed [W-1:0] x_o, y_o, z_o;
  logic ovf;
  logic [3:0] out_tag;
endinterface
