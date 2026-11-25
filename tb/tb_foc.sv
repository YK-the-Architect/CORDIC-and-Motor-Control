`timescale 1ns/1ps
// tb_foc.sv : field-oriented control of a permanent-magnet motor (PMSM) with the CORDIC engines
// in the loop.
//
// Every 50 us control step the controller does three CORDIC operations:
//   1. Park          (i_d, i_q) = (i_alpha, i_beta) rotated by -theta                (rotation)
//   2. Voltage limit |v| and angle phi of the PI outputs (v_d, v_q)                  (vectoring)
//   3. Inverse Park  (v_alpha, v_beta) = (min(|v|, V_max), 0) rotated by phi + theta (rotation)
// Step 3 does the limit and the inverse Park in one rotation: the vector keeps its angle and only
// its length is clamped.
//
// The iterative engine (cordic_ss) and the pipelined engine (cordic_pipe, 18 ranks) get every
// operation on the same clock, and their results must be identical. The same controller also runs
// with floating-point math on its own copy of the motor, to show what the 16-bit engine changes.
// The motor (dq model, RK4), the current sensor, the encoder and the PI controllers are real math
// here; the motor runs in model time (50 us per step), the engines on their own clock.
//
// Scenario: speed command 0 -> 3000 rpm at 5 ms, load torque 0.25 N m at 60 ms, reversal to
// -1000 rpm at 90 ms, end at 140 ms. The command ramps at 20,000 rad/s^2 (about 6.7 A). Near
// 3000 rpm the back-EMF takes most of the 13.9 V, so the voltage limit (step 2) comes into play.
// The speed loop adds the current the ramp's acceleration needs (J a / Kt), so it does not overshoot.
// Log: +CSV=<file> (default foc.csv), one row per step.
//
// PASS needs: both engines identical on every operation; every operation within 2 LSB of real
// math (when not saturated); speed within 0.5% of the command at the end of each phase; i_d within
// 0.2 A of 0 in steady state; the hardware loop within 1% (25 rpm) of the floating-point loop.
module tb_foc;
  parameter int  W = 16;
  parameter int  N = 16;
  parameter int  G = $clog2(N) + 1;                                  // guard bits
  parameter logic [N + 3 : 0] CUTS = (N == 16) ? 20'h5FFFF : '1;   // 18 ranks: syn/balance.py
  parameter real T_END = 0.14;

  localparam real PI    = 3.14159265358979323846;
  localparam real SQRT3 = 1.7320508075688772;
  localparam real QXY   = real'(1 << (W - 2));        // x, y: Q2.(W-2)
  localparam real TURN  = real'(1 << W);              // z: 2^W = 360 deg
  localparam real RPM   = 60.0 / (2.0 * PI);          // rad/s -> rpm

  // ---- motor (a small 24 V PMSM) and drive ----
  localparam real R_S = 0.2, L_D = 0.4e-3, L_Q = 0.4e-3, PSI = 0.01;   // ohm, H, H, Wb
  localparam real J_M = 2.0e-5, B_M = 1.0e-5, POLES = 4.0;            // kg m^2, N m s, pole pairs
  localparam real VDC = 24.0, V_MAX = VDC / SQRT3, I_MAX = 10.0;      // V, V (linear PWM), A
  localparam real I_BASE = 10.0, V_BASE = 20.0;                        // 1.0 = 10 A, 1.0 = 20 V
  localparam real TS = 50.0e-6;                                        // control period, 20 kHz
  localparam int  SUB = 10;                                            // RK4 steps per period
  // ---- controller: current loops 1 kHz (PI zero on R/L), speed loop 100 Hz ----
  localparam real KT   = 1.5 * POLES * PSI;                            // 0.06 N m / A
  localparam real KP_I = L_D * 2.0 * PI * 1000.0, KI_I = R_S * 2.0 * PI * 1000.0;
  localparam real KP_W = J_M * 2.0 * PI * 100.0 / KT, KI_W = KP_W * 2.0 * PI * 100.0 / 4.0;
  localparam real RAMP = 20000.0;                                      // rad/s^2, speed command

  // ---- the two engines, same inputs ----
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic mode_cl = 0, mode_rv = 0, start = 0, in_valid = 0;
  logic signed [W-1:0] x_in = 0, y_in = 0, z_in = 0;
  logic s_valid, s_ovf, p_ready, p_valid, p_ovf;
  logic signed [W-1:0] s_x, s_y, s_z, p_x, p_y, p_z;
  logic [3:0] tag = 0, p_tag;

  cordic_ss #(.WIDTH(W), .ITER(N), .G(G)) u_ss (.clk, .rst, .x_in, .y_in, .z_in, .start, .mode_cl,
      .mode_rv, .out_valid(s_valid), .x_corr(s_x), .y_corr(s_y), .z(s_z), .ovf(s_ovf));
  cordic_pipe #(.WIDTH(W), .ITER(N), .G(G), .CUTS(CUTS)) u_pipe (.clk, .rst, .in_valid, .in_ready(p_ready),
      .mode_cl, .mode_rv, .x_in, .y_in, .z_in, .in_tag(tag), .out_valid(p_valid), .out_ready(1'b1),
      .x_corr(p_x), .y_corr(p_y), .z(p_z), .ovf(p_ovf), .out_tag(p_tag));

  int n_ops = 0, n_diff = 0, lat_ss = 0, lat_pipe = 0;

  // one operation on both engines; returns cordic_ss's result (cordic_pipe's must be the same)
  task automatic cordic(input bit cl, input bit rv, input int xi, input int yi, input int zi,
                        output int xo, output int yo, output int zo, output bit of);
    bit sd, pd, so, po;
    int ls, lp, sx, sy, sz, px, py, pz;
    @(negedge clk);
    if (!p_ready) $fatal(1, "cordic_pipe not ready");
    mode_cl = cl; mode_rv = rv; x_in = W'(xi); y_in = W'(yi); z_in = W'(zi);
    tag = tag + 1; start = 1; in_valid = 1;
    sd = 0; pd = 0; ls = 0; lp = 0;
    while (!(sd && pd)) begin
      @(negedge clk);
      start = 0; in_valid = 0;
      ls += int'(!sd); lp += int'(!pd);
      if (!sd && s_valid) begin sd = 1; sx = s_x; sy = s_y; sz = s_z; so = s_ovf; end
      if (!pd && p_valid && p_tag == tag) begin pd = 1; px = p_x; py = p_y; pz = p_z; po = p_ovf; end
      if (ls > 4 * N + 40) $fatal(1, "no result");
    end
    n_ops++;
    lat_ss = ls; lat_pipe = lp;
    if ({sx, sy, sz, so} != {px, py, pz, po}) begin
      if (n_diff < 5) $display("  engines differ on op %0d: cordic_ss (%0d, %0d, %0d, %0d), cordic_pipe (%0d, %0d, %0d, %0d)",
                               n_ops, sx, sy, sz, so, px, py, pz, po);
      n_diff++;
    end
    xo = sx; yo = sy; zo = sz; of = so;
  endtask

  // ---- motor model ----
  typedef struct { real id, iq, wm, thm; } motor_t;     // A, A, rad/s (mechanical), rad

  function automatic motor_t deriv(motor_t s, real va, real vb, real tl);
    motor_t d;
    real te, we, c, sn, vd, vq;
    te = POLES * s.thm; we = POLES * s.wm;
    c = $cos(te); sn = $sin(te);
    vd =  va * c + vb * sn;
    vq = -va * sn + vb * c;
    d.id  = (vd - R_S * s.id + we * L_Q * s.iq) / L_D;
    d.iq  = (vq - R_S * s.iq - we * (L_D * s.id + PSI)) / L_Q;
    d.wm  = (1.5 * POLES * (PSI * s.iq + (L_D - L_Q) * s.id * s.iq) - B_M * s.wm - tl) / J_M;
    d.thm = s.wm;
    return d;
  endfunction

  function automatic motor_t axpy(motor_t s, motor_t d, real h);
    motor_t r;
    r.id = s.id + h * d.id; r.iq = s.iq + h * d.iq; r.wm = s.wm + h * d.wm; r.thm = s.thm + h * d.thm;
    return r;
  endfunction

  function automatic motor_t rk4(motor_t s, real va, real vb, real tl, real h);
    motor_t k1, k2, k3, k4, r;
    k1 = deriv(s, va, vb, tl);
    k2 = deriv(axpy(s, k1, h / 2), va, vb, tl);
    k3 = deriv(axpy(s, k2, h / 2), va, vb, tl);
    k4 = deriv(axpy(s, k3, h), va, vb, tl);
    r.id  = s.id  + h / 6 * (k1.id  + 2 * k2.id  + 2 * k3.id  + k4.id);
    r.iq  = s.iq  + h / 6 * (k1.iq  + 2 * k2.iq  + 2 * k3.iq  + k4.iq);
    r.wm  = s.wm  + h / 6 * (k1.wm  + 2 * k2.wm  + 2 * k3.wm  + k4.wm);
    r.thm = s.thm + h / 6 * (k1.thm + 2 * k2.thm + 2 * k3.thm + k4.thm);
    return r;
  endfunction

  // phase currents a and b (c = -a - b) of a motor state
  function automatic void phase(motor_t s, output real ia, output real ib);
    real te, al, be;
    te = POLES * s.thm;
    al = s.id * $cos(te) - s.iq * $sin(te);
    be = s.id * $sin(te) + s.iq * $cos(te);
    ia = al;
    ib = -0.5 * al + 0.5 * SQRT3 * be;
  endfunction

  // ---- fixed-point helpers ----
  function automatic real fabs(real v); return v < 0 ? -v : v; endfunction
  function automatic real clampr(real v, real lim); return v > lim ? lim : (v < -lim ? -lim : v); endfunction
  function automatic int q(real v);              // real -> Q2.(W-2) code, rounded, clamped
    real s; int c;
    s = v * QXY;
    c = $rtoi(s + (s >= 0 ? 0.5 : -0.5));
    if (c >  (1 << (W - 1)) - 1) c =  (1 << (W - 1)) - 1;
    if (c < -(1 << (W - 1)))     c = -(1 << (W - 1));
    return c;
  endfunction
  function automatic int ang(real rad);          // radians -> binary angle code (the encoder)
    real t; int c;
    t = rad / (2.0 * PI);
    t = t - $floor(t);
    c = $rtoi(t * TURN + 0.5) & ((1 << W) - 1);
    return c >= (1 << (W - 1)) ? c - (1 << W) : c;
  endfunction
  function automatic int wrapc(int c);           // a code sum back to W bits (angles wrap)
    c = c & ((1 << W) - 1);
    return c >= (1 << (W - 1)) ? c - (1 << W) : c;
  endfunction
  function automatic real angerr(real d);        // angle error in LSBs, wrapped to +-half a turn
    while (d >=  TURN / 2) d -= TURN;
    while (d <  -TURN / 2) d += TURN;
    return d;
  endfunction

  // worst error of each operation against real math on the same (quantized) inputs, in LSBs
  real e_park = 0, e_vmag = 0, e_vang = 0, e_ipark = 0;
  task automatic worst(inout real w, input real e); if (fabs(e) > w) w = fabs(e); endtask

  initial begin
    motor_t mh, mf;                     // motor run by the hardware controller, by the float one
    real t, w_ref, tl, ia, ib, ial, ibe, id, iq, ew, iqr_u, iq_ref, we, ed, eq, vd, vq, va, vb;
    real ii_d = 0, ii_q = 0, ii_w = 0;  // hardware controller integrators
    real f_ii_d = 0, f_ii_q = 0, f_ii_w = 0, fia, fib, fal, fbe, fth, fid, fiq, few, fiqr_u, fiq_ref;
    real fwe, fed, feq, fvd, fvq, fmag, fphi, fm, fva, fvb;
    real x0, y0, th0, rpm_err, max_dw = 0, max_diq = 0, worst_id = 0, w_cmd, w_ramp = 0, iq_ff;
    int th, idc, iqc, magc, phic, vac, vbc, mc, zz, yy, vmax_c, nstep, fd, ok, n_lim = 0;
    bit of1, of2, of3, lim, flim;
    string csv = "foc.csv";
    real chk_t[3], chk_w[3];

    void'($value$plusargs("CSV=%s", csv));
    fd = $fopen(csv, "w");
    $fdisplay(fd, "t_ms,w_ref_rpm,rpm_hw,rpm_float,iq_ref_a,id_hw_a,iq_hw_a,id_float_a,iq_float_a,ia_a,ib_a,ic_a,v_alpha_v,v_beta_v,v_mag_v,limited,theta_e_deg,load_nm,iq_meas_a,id_meas_a");
    mh = '{0.0, 0.0, 0.0, 0.0}; mf = mh;
    vmax_c = q(V_MAX / V_BASE);
    nstep = $rtoi(T_END / TS + 0.5);
    chk_t = '{59.5e-3, 89.5e-3, 139.5e-3};       // the end of each phase
    chk_w = '{3000.0, 3000.0, -1000.0};
    ok = 1;
    repeat (3) @(negedge clk);
    rst = 0;

    for (int k = 0; k < nstep; k++) begin
      t = k * TS;
      w_cmd = (t < 5.0e-3) ? 0.0 : (t < 90.0e-3) ? 3000.0 / RPM : -1000.0 / RPM;
      iq_ff = J_M * clampr(w_cmd - w_ramp, RAMP * TS) / TS / KT;   // current for the ramp's acceleration
      w_ramp += clampr(w_cmd - w_ramp, RAMP * TS);
      w_ref = w_ramp;
      tl = (t >= 60.0e-3) ? 0.25 : 0.0;

      // ================= hardware controller (the CORDIC engines) =================
      phase(mh, ia, ib);                          // current sensor
      ial = ia; ibe = (ia + 2.0 * ib) / SQRT3;    // Clarke
      th = ang(POLES * mh.thm);                   // encoder, electrical angle
      // 1. Park: rotate by -theta
      cordic(0, 0, q(ial / I_BASE), q(ibe / I_BASE), wrapc(-th), idc, iqc, zz, of1);
      x0 = q(ial / I_BASE) / QXY; y0 = q(ibe / I_BASE) / QXY; th0 = -wrapc(-th) * 2.0 * PI / TURN;
      if (!of1) begin
        worst(e_park, idc - ( x0 * $cos(th0) + y0 * $sin(th0)) * QXY);
        worst(e_park, iqc - (-x0 * $sin(th0) + y0 * $cos(th0)) * QXY);
      end
      id = idc / QXY * I_BASE; iq = iqc / QXY * I_BASE;
      // speed loop (PI plus the ramp's acceleration current, conditional integration at the limit)
      ew = w_ref - mh.wm;
      iqr_u = KP_W * ew + ii_w + iq_ff;
      iq_ref = clampr(iqr_u, I_MAX);
      if (iq_ref == iqr_u || ew * iqr_u < 0) ii_w += KI_W * TS * ew;
      // current loops with decoupling
      we = POLES * mh.wm;
      ed = 0.0 - id; eq = iq_ref - iq;
      vd = KP_I * ed + ii_d - we * L_Q * iq;
      vq = KP_I * eq + ii_q + we * (L_D * id + PSI);
      // 2. vectoring: |v| and its angle
      cordic(0, 1, q(vd / V_BASE), q(vq / V_BASE), 0, magc, yy, phic, of2);
      x0 = q(vd / V_BASE) / QXY; y0 = q(vq / V_BASE) / QXY;
      if (!of2 && $sqrt(x0 * x0 + y0 * y0) >= 0.05) begin
        worst(e_vmag, magc - $sqrt(x0 * x0 + y0 * y0) * QXY);
        worst(e_vang, angerr(phic - $atan2(y0, x0) / (2.0 * PI) * TURN));
      end
      // 3. limit the length, then rotate by phi + theta (inverse Park)
      lim = magc > vmax_c;
      mc = lim ? vmax_c : magc;
      cordic(0, 0, mc, 0, wrapc(phic + th), vac, vbc, zz, of3);
      th0 = wrapc(phic + th) * 2.0 * PI / TURN;
      if (!of3) begin
        worst(e_ipark, vac - mc * $cos(th0));
        worst(e_ipark, vbc - mc * $sin(th0));
      end
      va = vac / QXY * V_BASE; vb = vbc / QXY * V_BASE;
      if (!lim) begin ii_d += KI_I * TS * ed; ii_q += KI_I * TS * eq; end
      n_lim += int'(lim);

      // ================= the same controller in floating point =================
      phase(mf, fia, fib);
      fal = fia; fbe = (fia + 2.0 * fib) / SQRT3;
      fth = POLES * mf.thm;
      fid =  fal * $cos(fth) + fbe * $sin(fth);
      fiq = -fal * $sin(fth) + fbe * $cos(fth);
      few = w_ref - mf.wm;
      fiqr_u = KP_W * few + f_ii_w + iq_ff;
      fiq_ref = clampr(fiqr_u, I_MAX);
      if (fiq_ref == fiqr_u || few * fiqr_u < 0) f_ii_w += KI_W * TS * few;
      fwe = POLES * mf.wm;
      fed = 0.0 - fid; feq = fiq_ref - fiq;
      fvd = KP_I * fed + f_ii_d - fwe * L_Q * fiq;
      fvq = KP_I * feq + f_ii_q + fwe * (L_D * fid + PSI);
      fmag = $sqrt(fvd * fvd + fvq * fvq);
      fphi = $atan2(fvq, fvd);
      flim = fmag > V_MAX;
      fm = flim ? V_MAX : fmag;
      fva = fm * $cos(fphi + fth); fvb = fm * $sin(fphi + fth);
      if (!flim) begin f_ii_d += KI_I * TS * fed; f_ii_q += KI_I * TS * feq; end

      // ================= log, checks =================
      $fdisplay(fd, "%0.4f,%0.1f,%0.3f,%0.3f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0.4f,%0d,%0.3f,%0.3f,%0.4f,%0.4f",
                t * 1e3, w_ref * RPM, mh.wm * RPM, mf.wm * RPM, iq_ref, mh.id, mh.iq, mf.id, mf.iq,
                ia, ib, -ia - ib, va, vb, mc / QXY * V_BASE, lim,
                (POLES * mh.thm - 2.0 * PI * $floor(POLES * mh.thm / (2.0 * PI))) * 180.0 / PI, tl, iq, id);
      if (fabs(mh.wm - mf.wm) * RPM > max_dw) max_dw = fabs(mh.wm - mf.wm) * RPM;
      if (fabs(mh.iq - mf.iq) > max_diq) max_diq = fabs(mh.iq - mf.iq);
      if ((t > 40.0e-3 && t < 60.0e-3) || (t > 75.0e-3 && t < 90.0e-3) || t > 125.0e-3)
        if (fabs(mh.id) > worst_id) worst_id = fabs(mh.id);
      foreach (chk_t[c])
        if (k == $rtoi(chk_t[c] / TS + 0.5)) begin
          rpm_err = mh.wm * RPM - chk_w[c];
          $display("  t = %5.1f ms: speed %8.2f rpm (command %6.0f), i_d %6.3f A, i_q %6.3f A  %s",
                   t * 1e3, mh.wm * RPM, chk_w[c], mh.id, mh.iq,
                   fabs(rpm_err) <= 0.005 * fabs(chk_w[c]) ? "PASS" : "FAIL");
          if (fabs(rpm_err) > 0.005 * fabs(chk_w[c])) ok = 0;
        end

      // ================= both motors run for one control period =================
      for (int s = 0; s < SUB; s++) begin
        mh = rk4(mh, va, vb, tl, TS / SUB);
        mf = rk4(mf, fva, fvb, tl, TS / SUB);
      end
    end
    $fclose(fd);

    $display("  %0d control steps, %0d CORDIC operations on each engine, voltage limit active in %0d steps",
             nstep, n_ops, n_lim);
    $display("  clocks per operation: cordic_ss %0d, cordic_pipe %0d (3 per step: %0d and %0d clocks)",
             lat_ss, lat_pipe, 3 * lat_ss, 3 * lat_pipe);
    $display("  %s both engines identical on every operation (%0d different)", n_diff == 0 ? "PASS" : "FAIL", n_diff);
    $display("  %s worst error against real math: Park %0.2f, |v| %0.2f, angle %0.2f, inverse Park %0.2f LSB",
             (e_park <= 2.0 && e_vmag <= 2.0 && e_vang <= 2.0 && e_ipark <= 2.0) ? "PASS" : "FAIL",
             e_park, e_vmag, e_vang, e_ipark);
    $display("  %s i_d in steady state within %0.3f A of 0", worst_id <= 0.2 ? "PASS" : "FAIL", worst_id);
    $display("  %s hardware loop vs floating-point loop: speed within %0.2f rpm, i_q within %0.3f A",
             max_dw <= 25.0 ? "PASS" : "FAIL", max_dw, max_diq);
    if (n_diff != 0 || e_park > 2.0 || e_vmag > 2.0 || e_vang > 2.0 || e_ipark > 2.0 || worst_id > 0.2 ||
        max_dw > 25.0) ok = 0;
    $display("DONE: %s, log in %s", ok ? "PASS" : "FAIL", csv);
    $finish;
  end
endmodule
