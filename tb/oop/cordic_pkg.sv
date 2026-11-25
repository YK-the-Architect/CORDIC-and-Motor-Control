`timescale 1ns/1ps
// tb/oop/cordic_pkg.sv : class-based testbench for the pipelined CORDIC engine (cordic_pipe).
//
//   cordic_txn   one operation: constrained-random mode and inputs, plus the results
//   cordic_ref   reference model, bit-exact (the same integer steps as python/cordic_model.py)
//   generator    makes transactions (in range, corners, full range) and sends them to the driver
//   driver       drives in_valid / inputs, with random gaps; holds an operation until it is taken
//   sink         drives out_ready at random (stalls), sometimes for a long stretch
//   monitor      sees every operation taken at the input and every result taken at the output
//   scoreboard   checks each result bit for bit against the model, in order, with its tag, and
//                against real math (2 LSB) for in-range operations; checks a stalled result holds
//   coverage     bins for modes x kinds, quadrants, overflow per mode, and handshake events
//   env          builds and connects them, runs, reports
// The same classes run in VCS and Verilator (Verilator needs z3 for randomize()).
package cordic_pkg;

  localparam int W = 16, N = 16;
  localparam int G = $clog2(N) + 1, IW = W + 2 + G, F = W + 2;
  localparam int MAXV = (1 << (W - 1)) - 1, MINV = -(1 << (W - 1));
  localparam int ONE = 1 << (W - 2);                   // 1.0 in Q2.(W-2)
  localparam int LIM = (7 * ONE) / 10;                 // 0.7
  localparam int ZL = ((1 << (W - 1)) * 99) / 100;     // 0.99 in Q1.(W-1)
  localparam int HALF9 = (45 * ONE) / 100;             // 0.45
  localparam real PI = 3.14159265358979323846;

  typedef enum {IN_RANGE, CORNER, FULL_RANGE} kind_e;

  // ------------------------------------------------------------------ transaction
  class cordic_txn;
    rand kind_e kind;
    rand bit cl, rv;                       // mode: cl 1 = linear, rv 1 = vectoring
    rand int x, y, z;
    int unsigned id;
    bit [3:0] tag;
    // results
    int xo, yo, zo;
    bit ovf;

    constraint c_kind { kind dist {IN_RANGE := 60, CORNER := 15, FULL_RANGE := 25}; }
    // ranges are written as comparisons: Verilator 5.049 gets 'inside {[-a:a]}' with a negative
    // bound wrong (reports it unsatisfiable); VCS takes either form
    constraint c_full { x >= MINV; x <= MAXV; y >= MINV; y <= MAXV; z >= MINV; z <= MAXV; }
    // in range: nothing saturates, so results can be checked against real math (2 LSB)
    constraint c_in_range {
      kind == IN_RANGE -> {
        x >= -LIM; x <= LIM; y >= -LIM; y <= LIM;
        (!cl && rv) -> (x <= -ONE / 4 || x >= ONE / 4);            // vectoring: |v| >= 0.25
        (cl && !rv) -> (z >= -ZL && z <= ZL);                      // multiply: |z| <= 0.99
        (cl && rv)  -> (x >= ONE / 2 && x <= ONE &&                 // divide: x in [0.5, 1] and
                        y >= -HALF9 && y <= HALF9 &&                // |y| <= 0.45, so |y / x| <= 0.9,
                        z >= -ZL / 10 && z <= ZL / 10);             // and z + y / x stays in range
      }
    }
    constraint c_corner {
      kind == CORNER -> {
        x inside {0, 1, -1, ONE / 2, -ONE / 2, ONE, -ONE, MAXV, MINV, MINV + 1};
        y inside {0, 1, -1, ONE / 2, -ONE / 2, ONE, -ONE, MAXV, MINV, MINV + 1};
        z inside {0, 1, -1, 1 << (W - 2), -(1 << (W - 2)), (1 << (W - 2)) - 1, -(1 << (W - 2)) - 1,
                  1 << (W - 3), MAXV, MINV};
      }
    }

    function string name();
      return cl ? (rv ? "divide" : "multiply") : (rv ? "vectoring" : "rotation");
    endfunction

    function string convert2string();
      return $sformatf("#%0d %s %s in (%0d, %0d, %0d) out (%0d, %0d, %0d, ovf %0d) tag %0d", id, name(),
                       kind.name(), x, y, z, xo, yo, zo, ovf, tag);
    endfunction
  endclass

  // ------------------------------------------------------------------ reference model
  class cordic_ref;
    longint atan_tbl[N];
    longint c_k, one_l;

    function new();
      longint t;
      int ab;
      ab = W + G;
      c_k = longint'(0.6072529 * (2.0 ** F));
      for (int i = 0; i < N; i++) begin
        t = longint'($atan(2.0 ** (-i)) / (2.0 * PI) * (2.0 ** 48));              // as rtl/atan_rom.sv
        atan_tbl[i] = (t + (longint'(1) << (48 - ab - 1))) >>> (48 - ab);
      end
      one_l = longint'(1) << (W - 1 + G);
    endfunction

    static function longint sx(longint v, int n);             // n-bit two's complement wrap
      v = v & ((longint'(1) << n) - 1);
      return v[n - 1] ? v - (longint'(1) << n) : v;
    endfunction

    static function longint round_even(longint v, int s);     // banker's rounding, s bits
      longint q, g, below;
      if (s == 0) return v;
      q = v >>> s;
      g = (v >>> (s - 1)) & 1;
      below = v & ((longint'(1) << (s - 1)) - 1);
      return q + (g & (longint'(below != 0) | (q & 1)));
    endfunction

    static function longint add_sub(longint a, longint b, bit sub, ref bit ovf);
      longint r;
      r = sub ? a - b : a + b;
      if (r < -(longint'(1) << (IW - 1)) || r >= (longint'(1) << (IW - 1))) ovf = 1;
      return sx(r, IW);
    endfunction

    static function longint clamp(longint v);
      return v > MAXV ? MAXV : (v < MINV ? MINV : v);
    endfunction

    function void run(cordic_txn t);
      longint x, y, z, xn, yn, zn, ys, ang, xr, yr, zr;
      bit fold, neg, zhold, ovf, sigma;
      longint xi, yi, zi;
      xi = t.x; yi = t.y; zi = t.z;
      if (t.cl) fold = 0;
      else if (t.rv) fold = xi < 0;
      else fold = ((zi >>> (W - 1)) ^ (zi >>> (W - 2))) & 1;
      neg = fold || (t.cl && t.rv && xi < 0);
      x = xi <<< G; y = yi <<< G;
      if (neg) begin x = -x; y = -y; end
      z = (fold ? sx(zi ^ (longint'(1) << (W - 1)), W) : zi) <<< G;
      zhold = !t.cl && t.rv && xi == 0 && yi == 0;
      ovf = t.cl && t.rv && ((yi < 0 ? -yi : yi) >= (xi < 0 ? -xi : xi));
      for (int i = t.cl ? 1 : 0; i < N; i++) begin
        sigma = t.rv ? (y < 0) : (z >= 0);
        ys = t.cl ? 0 : (y >>> i);
        ang = t.cl ? (one_l >>> i) : atan_tbl[i];
        xn = add_sub(x, ys, sigma, ovf);
        yn = add_sub(y, x >>> i, !sigma, ovf);
        zn = add_sub(z, ang, sigma, ovf);
        x = xn; y = yn;
        if (!zhold) z = zn;
      end
      if (t.cl) begin xr = round_even(x, G); yr = round_even(y, G); end
      else begin xr = round_even(x * c_k, F + G); yr = round_even(y * c_k, F + G); end
      zr = round_even(z, G);
      if (clamp(xr) != xr || clamp(yr) != yr) ovf = 1;
      t.xo = int'(clamp(xr)); t.yo = int'(clamp(yr));
      if (t.cl) begin
        if (clamp(zr) != zr) ovf = 1;
        t.zo = int'(clamp(zr));
      end else t.zo = int'(sx(zr, W));
      t.ovf = ovf;
    endfunction
  endclass

  // ------------------------------------------------------------------ coverage (plain bins; Verilator does not collect covergroups)
  class coverage;
    int unsigned hits[string];
    string names[$];

    function new();
      string m[4] = '{"rotation", "vectoring", "multiply", "divide"};
      foreach (m[i]) begin
        add({m[i], " x IN_RANGE"}); add({m[i], " x CORNER"}); add({m[i], " x FULL_RANGE"});
        add({m[i], ": ovf seen"});
      end
      for (int q = 0; q < 4; q++) add($sformatf("rotation: angle in quadrant %0d", q + 1));
      for (int q = 0; q < 4; q++) add($sformatf("vectoring: vector in quadrant %0d", q + 1));
      add("handshake: result held by a stall"); add("handshake: in_ready low (stall reached the input)");
      add("handshake: bubble (no operation offered)"); add("handshake: 16 operations taken back to back");
    endfunction

    function void add(string n); hits[n] = 0; names.push_back(n); endfunction
    function void hit(string n); if (hits.exists(n)) hits[n]++; endfunction

    function void sample(cordic_txn t);
      int q;
      hit({t.name(), " x ", t.kind.name()});
      if (t.ovf) hit({t.name(), ": ovf seen"});
      if (!t.cl && !t.rv) begin
        q = (t.z >= 0) ? ((t.z < (1 << (W - 2))) ? 1 : 2) : ((t.z < -(1 << (W - 2))) ? 3 : 4);
        hit($sformatf("rotation: angle in quadrant %0d", q));
      end
      if (!t.cl && t.rv && (t.x != 0 || t.y != 0)) begin
        q = (t.y >= 0) ? ((t.x > 0) ? 1 : 2) : ((t.x < 0) ? 3 : 4);
        hit($sformatf("vectoring: vector in quadrant %0d", q));
      end
    endfunction

    function int report();
      int n_hit = 0;
      foreach (names[i]) begin
        if (hits[names[i]] > 0) n_hit++;
        else $display("  coverage hole: %s", names[i]);
      end
      $display("  coverage: %0d of %0d bins hit", n_hit, names.size());
      return n_hit == names.size();
    endfunction
  endclass

  // ------------------------------------------------------------------ generator
  class generator;
    mailbox #(cordic_txn) to_drv;
    int unsigned count;
    int unsigned show = 0;           // print the first few (+SHOW=<n>)
    function new(mailbox #(cordic_txn) m, int unsigned n); to_drv = m; count = n; void'($value$plusargs("SHOW=%d", show)); endfunction
    task run();
      for (int unsigned k = 0; k < count; k++) begin
        cordic_txn t = new();
        kind_e kd;
        bit c, r;
        int w;
        // the operation and the kind first (uniform modes; kinds 60/15/25 as c_kind says), then
        // the solver picks the inputs under them. Solving everything at once lets a solver flip
        // the mode to satisfy the range constraints, which starves some mode x kind bins.
        c = $urandom_range(1); r = $urandom_range(1); w = $urandom_range(99);
        kd = (w < 60) ? IN_RANGE : (w < 75) ? CORNER : FULL_RANGE;
        if (!t.randomize() with { kind == kd; cl == c; rv == r; }) $fatal(1, "randomize failed");
        t.id = k;
        if (k < show) $display("  generated %s", t.convert2string());
        to_drv.put(t);
      end
    endtask
  endclass

  // ------------------------------------------------------------------ driver (input side)
  class driver;
    virtual cordic_if vif;
    mailbox #(cordic_txn) from_gen;
    cordic_txn offered[$];           // what it has put on the inputs, oldest first (the monitor pops)
    int p_valid;                     // percent of clocks an operation is offered
    function new(virtual cordic_if v, mailbox #(cordic_txn) m, int p); vif = v; from_gen = m; p_valid = p; endfunction
    task run(int unsigned count);
      cordic_txn t;
      for (int unsigned k = 0; k < count; k++) begin
        from_gen.get(t);
        while ($urandom_range(99) >= p_valid) begin       // a gap (bubble) before this one
          @(negedge vif.clk); vif.in_valid = 0;
        end
        @(negedge vif.clk);
        vif.in_valid = 1; vif.mode_cl = t.cl; vif.mode_rv = t.rv;
        vif.x_in = W'(t.x); vif.y_in = W'(t.y); vif.z_in = W'(t.z); vif.in_tag = 4'(t.id);
        t.tag = 4'(t.id);
        offered.push_back(t);
        @(posedge vif.clk);
        while (!vif.in_ready) @(posedge vif.clk);         // held until taken (valid stays up)
      end
      @(negedge vif.clk); vif.in_valid = 0;
    endtask
  endclass

  // ------------------------------------------------------------------ sink (output side)
  class sink;
    virtual cordic_if vif;
    int p_ready;
    function new(virtual cordic_if v, int p); vif = v; p_ready = p; endfunction
    task run();
      forever begin
        @(negedge vif.clk);
        if ($urandom_range(999) < 3) begin                 // now and then a long stall
          vif.out_ready = 0;
          repeat ($urandom_range(40, 10)) @(negedge vif.clk);
        end
        vif.out_ready = ($urandom_range(99) < p_ready);
      end
    endtask
  endclass

  // ------------------------------------------------------------------ scoreboard
  class scoreboard;
    cordic_ref model = new();
    coverage cov;
    cordic_txn expected[$];
    int unsigned n_ok = 0, n_bad = 0, n_acc_bad = 0, n_acc = 0;
    real worst_acc = 0.0;
    function new(coverage c); cov = c; endfunction

    function void taken(cordic_txn t);                     // an operation went in
      model.run(t);
      expected.push_back(t);
    endfunction

    function void result(int xo, int yo, int zo, bit ovf, bit [3:0] tag);   // a result came out
      cordic_txn e;
      if (expected.size() == 0) begin
        $display("FAIL result with no operation outstanding");
        n_bad++;
        return;
      end
      e = expected.pop_front();
      if (xo != e.xo || yo != e.yo || zo != e.zo || ovf != e.ovf || tag != e.tag) begin
        if (n_bad < 5) $display("FAIL got (%0d, %0d, %0d, ovf %0d, tag %0d), model %s", xo, yo, zo, ovf, tag,
                                e.convert2string());
        n_bad++;
      end else n_ok++;
      cov.sample(e);
      if (e.kind == IN_RANGE) accuracy(e);
    endfunction

    // error against real math, in LSBs (for in-range operations, so nothing saturates)
    function real error_lsb(cordic_txn t);
      real x0, y0, z0, q, a, e1, e2;
      q = real'(ONE);
      x0 = t.x / q;
      y0 = t.y / q;
      if (!t.cl && !t.rv) begin                                 // rotation
        z0 = t.z * 2.0 * PI / (2.0 ** W);
        e1 = abs1(t.xo - (x0 * $cos(z0) - y0 * $sin(z0)) * q);
        e2 = abs1(t.yo - (x0 * $sin(z0) + y0 * $cos(z0)) * q);
        return max2(e1, e2);
      end
      if (!t.cl && t.rv) begin                                  // vectoring
        a = t.zo - (t.z + $atan2(y0, x0) / (2.0 * PI) * (2.0 ** W));
        while (a >= 2.0 ** (W - 1)) a = a - 2.0 ** W;
        while (a < -(2.0 ** (W - 1))) a = a + 2.0 ** W;
        e1 = abs1(t.xo - $sqrt(x0 * x0 + y0 * y0) * q);
        return max2(e1, abs1(a));
      end
      if (!t.rv) return abs1(t.yo - (y0 + x0 * (t.z / (2.0 ** (W - 1)))) * q);   // multiply
      return abs1(t.zo - (t.z / (2.0 ** (W - 1)) + y0 / x0) * (2.0 ** (W - 1)));  // divide
    endfunction

    function void accuracy(cordic_txn t);                  // against real math, 2 LSB
      real er;
      er = error_lsb(t);
      n_acc++;
      worst_acc = max2(worst_acc, er);
      if (er > 2.0) begin
        if (n_acc_bad < 5) $display("FAIL accuracy %0.2f LSB: %s", er, t.convert2string());
        n_acc_bad++;
      end
    endfunction

    static function real abs1(real v); return v < 0 ? -v : v; endfunction
    static function real max2(real a, real b); return a > b ? a : b; endfunction
  endclass

  // ------------------------------------------------------------------ monitor
  class monitor;
    virtual cordic_if vif;
    scoreboard sb;
    coverage cov;
    driver drv;                               // to check the DUT took what the driver offered
    int unsigned n_in = 0, n_out = 0, hold_bad = 0, in_bad = 0, streak = 0;
    function new(virtual cordic_if v, scoreboard s, coverage c, driver d); vif = v; sb = s; cov = c; drv = d; endfunction

    task run();
      bit held = 0;
      logic [3*W:0] last;
      forever begin
        @(posedge vif.clk);
        if (vif.rst) continue;
        // input side: an operation is taken on in_valid && in_ready
        if (vif.in_valid && vif.in_ready) begin
          cordic_txn t = new();
          t.cl = vif.mode_cl; t.rv = vif.mode_rv;
          t.x = int'(vif.x_in); t.y = int'(vif.y_in); t.z = int'(vif.z_in);
          t.tag = vif.in_tag; t.id = n_in++;
          if (drv.offered.size() == 0) begin
            $display("FAIL an operation was taken that the driver did not offer");
            in_bad++;
          end else begin
            cordic_txn o = drv.offered.pop_front();
            if ({o.cl, o.rv, o.x, o.y, o.z, o.tag} != {t.cl, t.rv, t.x, t.y, t.z, t.tag}) begin
              if (in_bad < 5) $display("FAIL taken (%s) is not what was offered (%s)", t.convert2string(), o.convert2string());
              in_bad++;
            end
            t.kind = o.kind;
          end
          sb.taken(t);
          if (++streak == 16) cov.hit("handshake: 16 operations taken back to back");
        end else streak = 0;
        if (!vif.in_valid) cov.hit("handshake: bubble (no operation offered)");
        if (!vif.in_ready) cov.hit("handshake: in_ready low (stall reached the input)");
        // output side: a stalled result must hold (valid stays up, data unchanged)
        if (held && (!vif.out_valid || {vif.x_o, vif.y_o, vif.z_o, vif.ovf} != last)) begin
          if (hold_bad < 5) $display("FAIL a stalled result changed before it was taken");
          hold_bad++;
        end
        if (vif.out_valid && !vif.out_ready) cov.hit("handshake: result held by a stall");
        held = vif.out_valid && !vif.out_ready;
        last = {vif.x_o, vif.y_o, vif.z_o, vif.ovf};
        if (vif.out_valid && vif.out_ready) begin
          sb.result(int'(vif.x_o), int'(vif.y_o), int'(vif.z_o), vif.ovf, vif.out_tag);
          n_out++;
        end
      end
    endtask
  endclass

  // ------------------------------------------------------------------ environment
  class env;
    virtual cordic_if vif;
    mailbox #(cordic_txn) gen2drv = new();
    coverage cov = new();
    generator gen;
    driver drv;
    sink snk;
    scoreboard sb;
    monitor mon;
    int unsigned count;

    function new(virtual cordic_if v, int unsigned n, int p_valid, int p_ready);
      vif = v; count = n;
      gen = new(gen2drv, n);
      drv = new(v, gen2drv, p_valid);
      snk = new(v, p_ready);
      sb = new(cov);
      mon = new(v, sb, cov, drv);
    endfunction

    task run(output bit pass);
      fork
        gen.run();
        drv.run(count);
        snk.run();
        mon.run();
      join_none
      wait (mon.n_out == count);
      repeat (5) @(posedge vif.clk);
      $display("  %0d operations in, %0d results out; bit for bit vs the model: %0d match, %0d differ",
               mon.n_in, mon.n_out, sb.n_ok, sb.n_bad);
      $display("  accuracy vs real math (in-range operations): %0d checked, worst %0.2f LSB, %0d over 2 LSB",
               sb.n_acc, sb.worst_acc, sb.n_acc_bad);
      $display("  stalled results that changed: %0d; operations taken that differ from those offered: %0d",
               mon.hold_bad, mon.in_bad);
      pass = cov.report();
      pass = pass && sb.n_bad == 0 && sb.n_acc_bad == 0 && mon.hold_bad == 0 && mon.in_bad == 0 && sb.expected.size() == 0 &&
             mon.n_in == count;
    endtask
  endclass

endpackage
