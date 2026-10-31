module atan_rom #(
  parameter int WIDTH   = 16,
  parameter int ITER = 16
)(
  output logic [WIDTH-1:0] atan_out [ITER]
);

  // ---- one constant: atan(2^-i) in binary angle units ----
  function automatic logic [WIDTH-1:0] atan_const(int i);
    real a;
    a = $atan(2.0 ** (-i));
    return WIDTH'($rtoi(a / (2.0 * 3.141592653589793) * (2.0 ** WIDTH) + 0.5));
  endfunction

  // ---- whole table, built at elaboration ----
  typedef logic [WIDTH-1:0] rom_t[ITER];

  function automatic rom_t build_rom();
    rom_t r;
    for (int i = 0; i < ITER; i++) r[i] = atan_const(i);
    return r;
  endfunction

  localparam rom_t ATAN_ROM = build_rom();


  // ---- outputs are just tied to the constants ----
  assign atan_out = ATAN_ROM;

endmodule