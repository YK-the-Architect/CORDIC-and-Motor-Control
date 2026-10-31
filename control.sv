//control unit for single cycle implementation
module control #(
    parameter WIDTH = 8,
    parameter ITER = 8
)(
    input logic clk, rst,
    input logic y_msb, z_msb,
    input logic mode_cl, mode_rv, start,
    output logic init, en, sigma, m,
    output logic [$clog2(ITER) - 1 : 0] i,
    output logic out_valid
    );
    typedef enum logic [1:0] { 
        IDLE = 0,
        EXE = 1,
        DONE = 2,
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
        case (state)
            IDLE : begin
                if(start) begin
                    next_state = EXE;
                    next_mode_cl_reg = mode_cl ? LINEAR : CIRCULAR;
                    next_mode_rv_reg = mode_rv ? VECTORING : ROTATION;
                    next_i = mode_cl ? 1 : 0;
                    init = 1;
                    en = 1;
                end                
            end
            
            EXE : begin
                if(i < ITER) begin
                    next_state = EXE;
                    en = 1;
                    if (mode_rv_reg == ROTATION) sigma = z_msb;
                    else if(mode_rv_reg == VECTORING) sigma = !y_msb;
                    if (mode_cl_reg == CIRCULAR) m = 1;
                    else if(mode_cl_reg == LINEAR) m = 0;
                end
                else next_state = DONE;
            end

            DONE : begin
                out_valid = 1;
                next_state = IDLE;
            end
        endcase
    end


endmodule