`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_walker - 3-level Sv39 page-table walker
//  Optimized for low miss latency:
//    * Start from a single-cycle walk_req pulse.
//    * Process a PTE in the same cycle mem_valid is observed.
//    * Avoid a dedicated PTE register / CHECK state.
// ============================================================
module mmu64_walker(
    input wire                    clk,
    input wire                    rst_n,

    // --- Walk request ---
    input wire                    walk_req,
    input wire [`VPN_TOTAL_W-1:0] vpn,          // {VPN2, VPN1, VPN0}
    input wire [1:0]              access_type,
    input wire [1:0]              priv_mode,
    input wire [`PPN_WIDTH-1:0]   satp_ppn,
    input wire                    mstatus_sum,
    input wire                    mstatus_mxr,

    // --- Walk result ---
    output reg                    walk_done,
    output reg                    walk_fault,
    output reg [`PPN_WIDTH-1:0]   walk_ppn,
    output reg [7:0]              walk_flags,    // {D,A,G,U,X,W,R,V}
    output reg [1:0]              walk_page_size,// 0=4KiB, 1=2MiB, 2=1GiB

    // --- Memory interface (read PTE) ---
    output reg                    mem_req,
    output reg [`PA_WIDTH-1:0]    mem_addr,
    input wire [`PTE_WIDTH-1:0]   mem_rdata,
    input wire                    mem_valid
);

    // ---- FSM States (one-hot) ----
    localparam [2:0] ST_IDLE = 3'b001;
    localparam [2:0] ST_REQ  = 3'b010;
    localparam [2:0] ST_WAIT = 3'b100;

    (* fsm_encoding = "one_hot" *) reg [2:0] curr_state, next_state;
    reg [1:0] level;                    // 2, 1, 0

    // ---- Registered inputs ----
    reg [`VPN_TOTAL_W-1:0] vpn_reg;
    reg [1:0]              acc_reg;
    reg [1:0]              priv_reg;
    reg                    sum_reg, mxr_reg;

    // ---- Base PPN for current level ----
    reg [`PPN_WIDTH-1:0]   base_ppn;

    // ---- VPN fields ----
    wire [8:0] vpn2 = vpn_reg[26:18];
    wire [8:0] vpn1 = vpn_reg[17:9];
    wire [8:0] vpn0 = vpn_reg[8:0];

    // ---- VPN field for current level ----
    reg [8:0] vpn_field;
    always @(*) begin
        case (level)
            2'd2:    vpn_field = vpn2;
            2'd1:    vpn_field = vpn1;
            2'd0:    vpn_field = vpn0;
            default: vpn_field = 9'd0;
        endcase
    end

    // ---- Decode the returned PTE directly from mem_rdata ----
    wire [`PPN_WIDTH-1:0] pte_ppn       = mem_rdata[`PTE_PPN];
    wire [8:0]            pte_ppn1      = mem_rdata[`PTE_PPN1];
    wire [8:0]            pte_ppn0      = mem_rdata[`PTE_PPN0];
    wire                  pte_v         = mem_rdata[`PTE_V];
    wire                  pte_r         = mem_rdata[`PTE_R];
    wire                  pte_w         = mem_rdata[`PTE_W];
    wire                  pte_x         = mem_rdata[`PTE_X];
    wire                  pte_u         = mem_rdata[`PTE_U];
    wire                  pte_g         = mem_rdata[`PTE_G];
    wire                  pte_a         = mem_rdata[`PTE_A];
    wire                  pte_d         = mem_rdata[`PTE_D];
    wire [9:0]            pte_rsvd_bits = mem_rdata[`PTE_RSVD];

    wire pte_is_leaf    = pte_v && (pte_r || pte_x);
    wire pte_is_pointer = pte_v && !pte_r && !pte_w && !pte_x;

    // ---- Permission checker ----
    wire perm_fault;
    mmu64_perm_check u_perm(
        .access_type (acc_reg),
        .priv_mode   (priv_reg),
        .pte_r       (pte_r),
        .pte_w       (pte_w),
        .pte_x       (pte_x),
        .pte_u       (pte_u),
        .pte_a       (pte_a),
        .pte_d       (pte_d),
        .mstatus_sum (sum_reg),
        .mstatus_mxr (mxr_reg),
        .fault       (perm_fault)
    );

    // ---- Superpage alignment ----
    reg misaligned;
    always @(*) begin
        misaligned = 1'b0;
        case (level)
            2'd2:    misaligned = (pte_ppn1 != 9'd0) || (pte_ppn0 != 9'd0);
            2'd1:    misaligned = (pte_ppn0 != 9'd0);
            default: misaligned = 1'b0;
        endcase
    end

    // ---- Reserved PTE checks ----
    wire reserved_encoding = pte_w && !pte_r;   // W=1, R=0 is reserved
    wire rsvd_bits_set     = (pte_rsvd_bits != 10'd0);
    wire pte_format_fault  = !pte_v || reserved_encoding || rsvd_bits_set;

    // ---- Next-state logic ----
    always @(*) begin
        next_state = curr_state;
        case (curr_state)
            ST_IDLE: begin
                if (walk_req)
                    next_state = ST_REQ;
            end

            ST_REQ: begin
                next_state = ST_WAIT;
            end

            ST_WAIT: begin
                if (mem_valid) begin
                    if (!pte_format_fault && pte_is_pointer && (level != 2'd0))
                        next_state = ST_REQ;
                    else
                        next_state = ST_IDLE;
                end
            end

            default: begin
                next_state = ST_IDLE;
            end
        endcase
    end

    // ---- Sequential logic ----
    always @(posedge clk) begin
        if (!rst_n) begin
            curr_state      <= ST_IDLE;
            level           <= 2'd2;
            vpn_reg         <= {`VPN_TOTAL_W{1'b0}};
            acc_reg         <= 2'b00;
            priv_reg        <= 2'b00;
            sum_reg         <= 1'b0;
            mxr_reg         <= 1'b0;
            base_ppn        <= {`PPN_WIDTH{1'b0}};
            walk_done       <= 1'b0;
            walk_fault      <= 1'b0;
            walk_ppn        <= {`PPN_WIDTH{1'b0}};
            walk_flags      <= 8'h0;
            walk_page_size  <= 2'd0;
            mem_req         <= 1'b0;
            mem_addr        <= {`PA_WIDTH{1'b0}};
        end else begin
            curr_state <= next_state;

            walk_done  <= 1'b0;
            walk_fault <= 1'b0;
            mem_req    <= 1'b0;

            case (curr_state)
                ST_IDLE: begin
                    if (walk_req) begin
                        vpn_reg  <= vpn;
                        acc_reg  <= access_type;
                        priv_reg <= priv_mode;
                        sum_reg  <= mstatus_sum;
                        mxr_reg  <= mstatus_mxr;
                        base_ppn <= satp_ppn;
                        level    <= 2'd2;
                    end
                end

                ST_REQ: begin
                    mem_req  <= 1'b1;
                    mem_addr <= {base_ppn, vpn_field, 3'b000};
                end

                ST_WAIT: begin
                    if (mem_valid) begin
                        if (pte_format_fault) begin
                            walk_fault <= 1'b1;
                        end else if (pte_is_leaf) begin
                            if (misaligned || perm_fault) begin
                                walk_fault <= 1'b1;
                            end else begin
                                walk_done      <= 1'b1;
                                walk_ppn       <= pte_ppn;
                                walk_flags     <= {pte_d, pte_a, pte_g, pte_u,
                                                   pte_x, pte_w, pte_r, pte_v};
                                walk_page_size <= (level == 2'd2) ? 2'd2 :
                                                  (level == 2'd1) ? 2'd1 : 2'd0;
                            end
                        end else if (pte_is_pointer && (level != 2'd0)) begin
                            base_ppn <= pte_ppn;
                            level    <= level - 2'd1;
                        end else begin
                            walk_fault <= 1'b1;
                        end
                    end
                end

                default: begin
                    curr_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
