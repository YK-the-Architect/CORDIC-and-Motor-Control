//One register rank of the pipelined engine, or a plain wire when REG = 0.
//All ranks share one enable (adv): when the pipeline stalls, every rank holds.
//EN = 1: data loads only for a real operation (adv && v_d), so bubbles do not toggle it.
//EN = 0: data loads every clock (no stall support, smallest and fastest).
module pipe_cut #(
    parameter int W   = 8,
    parameter bit REG = 1,
    parameter bit EN  = 1
)(
    input  logic clk, rst, adv,
    input  logic v_d,
    input  logic [W - 1 : 0] d,
    output logic v_q,
    output logic [W - 1 : 0] q
);
    if (REG) begin : g_reg
        always_ff @(posedge clk) begin
            if (rst)      v_q <= 1'b0;
            else if (adv) v_q <= v_d;
        end
        //data needs no reset: it is only read together with its valid bit
        if (EN) begin : g_en
            always_ff @(posedge clk) if (adv && v_d) q <= d;
        end else begin : g_free
            always_ff @(posedge clk) q <= d;
        end
    end else begin : g_wire
        assign v_q = v_d;
        assign q   = d;
    end
endmodule
