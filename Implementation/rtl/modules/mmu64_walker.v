`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_walker — 3-Level Page Table Walker (Sv39)
//  FSM di qua 3 cap: Level 2 → Level 1 → Level 0
//  Ho tro gigapage (1GiB), megapage (2MiB), 4KiB page
//  Kiem tra: V, W^R reserved, misaligned superpage, permission
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

    // --- Memory interface (doc PTE) ---
    output reg                    mem_req,
    output reg [`PA_WIDTH-1:0]    mem_addr,
    input wire [`PTE_WIDTH-1:0]   mem_rdata,
    input wire                    mem_valid
);

    // ---- FSM States (one-hot) ----
    localparam [3:0] ST_IDLE  = 4'b0001;
    localparam [3:0] ST_REQ   = 4'b0010;
    localparam [3:0] ST_WAIT  = 4'b0100;
    localparam [3:0] ST_CHECK = 4'b1000;

    reg [3:0] curr_state, next_state;
    reg [1:0] level;                    // 2, 1, 0

    // ---- Registered inputs ----
    reg [`VPN_TOTAL_W-1:0] vpn_reg;
    reg [1:0]              acc_reg;
    reg [1:0]              priv_reg;
    reg [`PPN_WIDTH-1:0]   satp_ppn_reg;
    reg                    sum_reg, mxr_reg;

    // ---- PTE register ----
    reg [`PTE_WIDTH-1:0]   pte_reg;

    // ---- Base PPN cho moi level ----
    reg [`PPN_WIDTH-1:0]   base_ppn;

    // ---- VPN fields ----
    wire [8:0] vpn2 = vpn_reg[26:18];
    wire [8:0] vpn1 = vpn_reg[17:9];
    wire [8:0] vpn0 = vpn_reg[8:0];

    // ---- VPN field cho level hien tai ----
    reg [8:0] vpn_field;
    always @(*) begin
        case (level)
            2'd2:    vpn_field = vpn2;
            2'd1:    vpn_field = vpn1;
            2'd0:    vpn_field = vpn0;
            default: vpn_field = 9'd0;
        endcase
    end

    // ---- PTE Decoder ----
    wire [`PPN_WIDTH-1:0] pte_ppn;
    wire [25:0]           pte_ppn2;
    wire [8:0]            pte_ppn1, pte_ppn0;
    wire pte_v, pte_r, pte_w, pte_x, pte_u, pte_g, pte_a, pte_d;
    wire pte_is_leaf, pte_is_pointer;

    mmu64_pte_decode u_decode(
        .pte_in     (pte_reg),
        .ppn        (pte_ppn),
        .ppn2       (pte_ppn2),
        .ppn1       (pte_ppn1),
        .ppn0       (pte_ppn0),
        .valid      (pte_v),
        .readable   (pte_r),
        .writable   (pte_w),
        .executable (pte_x),
        .user_mode  (pte_u),
        .global_flag(pte_g),
        .accessed   (pte_a),
        .dirty      (pte_d),
        .is_leaf    (pte_is_leaf),
        .is_pointer (pte_is_pointer)
    );

    // ---- Permission Checker ----
    wire perm_fault;

    mmu64_perm_check u_perm(
        .access_type(acc_reg),
        .priv_mode  (priv_reg),
        .pte_r      (pte_r),
        .pte_w      (pte_w),
        .pte_x      (pte_x),
        .pte_u      (pte_u),
        .pte_a      (pte_a),
        .pte_d      (pte_d),
        .mstatus_sum(sum_reg),
        .mstatus_mxr(mxr_reg),
        .fault      (perm_fault)
    );

    // ---- Kiem tra misaligned superpage ----
    reg misaligned;
    always @(*) begin
        misaligned = 1'b0;
        case (level)
            2'd2: // Gigapage: PPN[1] va PPN[0] phai = 0
                if (pte_ppn1 != 9'd0 || pte_ppn0 != 9'd0)
                    misaligned = 1'b1;
            2'd1: // Megapage: PPN[0] phai = 0
                if (pte_ppn0 != 9'd0)
                    misaligned = 1'b1;
            default: ; // 4KiB: khong can kiem tra
        endcase
    end

    // ---- Kiem tra reserved PTE bits ----
    wire reserved_encoding = pte_w && !pte_r;   // W=1, R=0 la reserved
    wire rsvd_bits_set     = (pte_reg[`PTE_RSVD] != 10'd0);

    // ---- Next-state logic (combinational) ----
    always @(*) begin
        next_state = curr_state;
        case (curr_state)
            ST_IDLE:  if (walk_req) next_state = ST_REQ;
            ST_REQ:   next_state = ST_WAIT;
            ST_WAIT:  if (mem_valid) next_state = ST_CHECK;
            ST_CHECK: begin
                if (!pte_v || reserved_encoding || rsvd_bits_set) begin
                    next_state = ST_IDLE; // → fault
                end else if (pte_is_leaf) begin
                    next_state = ST_IDLE; // → done hoac fault
                end else begin
                    // Pointer: con level nao khong?
                    if (level == 2'd0)
                        next_state = ST_IDLE; // → fault (level 0 khong co pointer)
                    else
                        next_state = ST_REQ;  // → di xuong level tiep
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // ---- Sequential logic ----
    always @(posedge clk) begin
        if (!rst_n) begin
            curr_state      <= ST_IDLE;
            level           <= 2'd2;
            pte_reg         <= {`PTE_WIDTH{1'b0}};
            vpn_reg         <= {`VPN_TOTAL_W{1'b0}};
            acc_reg         <= 2'b00;
            priv_reg        <= 2'b00;
            satp_ppn_reg    <= {`PPN_WIDTH{1'b0}};
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

            // Default: xoa pulse
            walk_done  <= 1'b0;
            walk_fault <= 1'b0;
            mem_req    <= 1'b0;

            case (curr_state)
                // ---- IDLE: nhan yeu cau walk ----
                ST_IDLE: begin
                    if (walk_req) begin
                        vpn_reg      <= vpn;
                        acc_reg      <= access_type;
                        priv_reg     <= priv_mode;
                        satp_ppn_reg <= satp_ppn;
                        sum_reg      <= mstatus_sum;
                        mxr_reg      <= mstatus_mxr;
                        base_ppn     <= satp_ppn;
                        level        <= 2'd2;
                    end
                end

                // ---- REQ: tinh dia chi PTE va gui yeu cau doc ----
                ST_REQ: begin
                    mem_req  <= 1'b1;
                    mem_addr <= {base_ppn, vpn_field, 3'b000};
                end

                // ---- WAIT: cho du lieu tu bo nho ----
                ST_WAIT: begin
                    if (mem_valid)
                        pte_reg <= mem_rdata;
                end

                // ---- CHECK: phan tich PTE ----
                ST_CHECK: begin
                    if (!pte_v || reserved_encoding || rsvd_bits_set) begin
                        // PTE invalid hoac reserved encoding
                        walk_fault <= 1'b1;
                    end else if (pte_is_leaf) begin
                        // Leaf PTE — kiem tra alignment va permission
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
                    end else begin
                        // Pointer PTE
                        if (level == 2'd0) begin
                            walk_fault <= 1'b1;
                        end else begin
                            base_ppn <= pte_ppn;
                            level    <= level - 2'd1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
