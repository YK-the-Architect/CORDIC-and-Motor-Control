//control unit for single cycle implementation
module control #(
    parameter WIDTH = 8,
    parameter ITER = 8,
    //1: one extra clock (HOLD) after the last iteration. The lanes then stay still for 2 clocks
    //before out_valid, so the output stage can be timed as a 2-clock multicycle path
    //(syn/cordic_ss_mcp.sdc). Same results, one clock more latency. 0: as before.
    parameter bit OUT_WAIT = 0
)(
    input logic clk, rst,
    input logic y_msb, z_msb,
    input logic mode_cl, mode_rv, start,
    output logic init, en, sigma, m,
    output logic [$clog2(ITER) - 1 : 0] i,
    output logic out_valid, scale_en,
    //1 on a clock where a start is taken: in IDLE, and in the out_valid clock (back to back).
    //A start while ready = 0 (EXE, HOLD) is ignored.
    output logic ready
    );
    typedef enum logic [1:0] { 
        IDLE = 0,
        EXE = 1,
        DONE = 2,
        HOLD = 3    //only with OUT_WAIT = 1
    } state_t;
    typedef enum logic {CIRCULAR = 0, LINEAR = 1} cl_mode_t;
    typedef enum logic {ROTATION = 0, VECTORING = 1} rv_mode_t;
    cl_mode_t mode_cl_reg, next_mode_cl_reg;
    rv_mode_t mode_rv_reg, next_mode_rv_reg;
    state_t state, next_state;
    logic [$clog2(ITER) - 1 : 0] next_i;
    always_ff @(posedge clk) begin
        if(rst) begin
            state <= IDLE;
            i<='0; //i was never reset, it started as X
            mode_cl_reg <= CIRCULAR;
            mode_rv_reg <= ROTATION;
        end
        else begin
            state <= next_state;
            i <= next_i;
            mode_cl_reg <= next_mode_cl_reg;
            mode_rv_reg <= next_mode_rv_reg;
        end
    end

    always_comb begin
        //default cases for registers
        next_state = state; 
        next_i = i;
        next_mode_cl_reg = mode_cl_reg;
        next_mode_rv_reg = mode_rv_reg;
        init = 0;
        en = 0;
        sigma = 0;
        m = 0;
        out_valid = 0; //out_valid needed to default too to avoid latch
        scale_en = 0;
        ready = 0;
        case (state)
            IDLE : begin
                ready = 1;
                if(start) begin
                    next_state = EXE;
                    next_mode_cl_reg = mode_cl ? LINEAR : CIRCULAR;
                    next_mode_rv_reg = mode_rv ? VECTORING : ROTATION;
                    next_i = mode_cl ? 1 : 0;
                    init = 1;
                    en = 1;
                end                
            end
            
            EXE : begin //counter was never moving forward
                en = 1;
                m = (mode_cl_reg == CIRCULAR);
                if (mode_rv_reg == ROTATION) sigma = ~z_msb;
                else                         sigma = y_msb;
                next_i = i + 1;
                if (i == ITER - 1) next_state = OUT_WAIT ? HOLD : DONE;
            end

            HOLD : next_state = DONE;   //lanes hold (en = 0) while the output stage settles; start is ignored, as in EXE

            DONE : begin
                if(mode_cl_reg == CIRCULAR) scale_en = 1;
                out_valid = 1;
                ready = 1;
                //RTL change 7: a start in the out_valid clock begins the next operation
                //right away (back to back) instead of being dropped
                if(start) begin
                    next_state = EXE;
                    next_mode_cl_reg = mode_cl ? LINEAR : CIRCULAR;
                    next_mode_rv_reg = mode_rv ? VECTORING : ROTATION;
                    next_i = mode_cl ? 1 : 0;
                    init = 1;
                    en = 1;
                end
                else next_state = IDLE;
            end
        endcase
    end


endmodule
