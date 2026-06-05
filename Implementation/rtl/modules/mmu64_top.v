`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_top — Top-level MMU (Sv39) cho RV64
//  - Ket noi: CPU ↔ TLB ↔ Walker ↔ Memory
//  - TLB hit: 1-cycle latency (registered output)
//  - TLB miss: page-table walk → TLB fill → PA output
//  - Bypass: M-mode hoac satp.MODE = Bare
//  - SFENCE.VMA: flush toan bo TLB
// ============================================================
module mmu64_top #(
    parameter TLB_ENTRIES = `TLB_ENTRIES
)(
    input wire                  clk,
    input wire                  rst_n,

    // --- CPU-side interface ---
    input wire [`VA_WIDTH-1:0]  va,
    input wire [1:0]            access_type,    // ACC_LOAD / ACC_STORE / ACC_EXEC
    input wire [1:0]            priv_mode,      // PRIV_U / PRIV_S / PRIV_M
    input wire                  req,            // Translation request
    output wire                 ready,          // San sang nhan request

    // --- CSR inputs ---
    input wire [63:0]           satp,
    input wire                  mstatus_sum,
    input wire                  mstatus_mxr,

    // --- Translation output ---
    output reg [`PA_WIDTH-1:0]  pa,
    output reg                  pa_valid,
    output reg                  page_fault,

    // --- SFENCE.VMA ---
    input wire                  sfence_vma,

    // --- Memory interface (cho page-table walk) ---
    output wire                 mem_req,
    output wire [`PA_WIDTH-1:0] mem_addr,
    input wire [`PTE_WIDTH-1:0] mem_rdata,
    input wire                  mem_valid
);

    // ---- FSM States ----
    localparam [1:0] ST_IDLE = 2'b00;
    localparam [1:0] ST_WALK = 2'b01;

    reg [1:0] state;

    // ---- SATP fields ----
    wire [3:0]              satp_mode = satp[`SATP_MODE];
    wire [`PPN_WIDTH-1:0]   satp_ppn  = satp[`SATP_PPN];

    // ---- Kiem tra translation co duoc bat khong ----
    wire translation_en = (satp_mode == `SATP_MODE_SV39) &&
                          (priv_mode != `PRIV_M);

    // ---- Kiem tra VA hop le (Sv39 sign extension) ----
    // VA[63:39] phai bang VA[38]
    wire va_valid = (va[63:39] == {25{va[38]}});

    // ---- VPN extraction ----
    wire [`VPN_TOTAL_W-1:0] va_vpn = {va[38:30], va[29:21], va[20:12]};

    // ---- Registered VA (giu khi walk) ----
    reg [`VA_WIDTH-1:0]  va_reg;
    reg [1:0]            acc_reg;
    reg [1:0]            priv_reg;

    wire [`VPN_TOTAL_W-1:0] va_reg_vpn = {va_reg[38:30], va_reg[29:21], va_reg[20:12]};

    // ============================================================
    //  TLB Instance
    // ============================================================
    wire                  tlb_hit;
    wire [`PPN_WIDTH-1:0] tlb_ppn;
    wire [7:0]            tlb_flags;
    wire [1:0]            tlb_pgsz;

    reg                   tlb_we;
    reg [`VPN_TOTAL_W-1:0] tlb_wr_vpn;
    reg [`PPN_WIDTH-1:0]   tlb_wr_ppn;
    reg [7:0]              tlb_wr_flags;
    reg [1:0]              tlb_wr_pgsz;

    mmu64_tlb #(
        .ENTRIES(TLB_ENTRIES)
    ) u_tlb (
        .clk            (clk),
        .rst_n          (rst_n),
        .lookup_vpn     (va_vpn),       // Dung VA truc tiep (combinational)
        .lookup_req     (req),
        .lookup_hit     (tlb_hit),
        .lookup_ppn     (tlb_ppn),
        .lookup_flags   (tlb_flags),
        .lookup_page_size(tlb_pgsz),
        .write_en       (tlb_we),
        .write_vpn      (tlb_wr_vpn),
        .write_ppn      (tlb_wr_ppn),
        .write_flags    (tlb_wr_flags),
        .write_page_size(tlb_wr_pgsz),
        .flush          (sfence_vma)
    );

    // ---- TLB hit: tinh PA tu PPN + VA offset ----
    reg [`PA_WIDTH-1:0] tlb_pa;
    always @(*) begin
        case (tlb_pgsz)
            2'd0: tlb_pa = {tlb_ppn, va[11:0]};                        // 4KiB
            2'd1: tlb_pa = {tlb_ppn[`PPN_WIDTH-1:9], va[20:0]};        // 2MiB
            2'd2: tlb_pa = {tlb_ppn[`PPN_WIDTH-1:18], va[29:0]};       // 1GiB
            default: tlb_pa = {tlb_ppn, va[11:0]};
        endcase
    end

    // ============================================================
    //  Walker Instance
    // ============================================================
    reg                   walk_start;
    wire                  walk_done;
    wire                  walk_fault;
    wire [`PPN_WIDTH-1:0] walk_ppn;
    wire [7:0]            walk_flags;
    wire [1:0]            walk_pgsz;

    mmu64_walker u_walker(
        .clk            (clk),
        .rst_n          (rst_n),
        .walk_req       (walk_start),
        .vpn            (va_reg_vpn),
        .access_type    (acc_reg),
        .priv_mode      (priv_reg),
        .satp_ppn       (satp_ppn),
        .mstatus_sum    (mstatus_sum),
        .mstatus_mxr    (mstatus_mxr),
        .walk_done      (walk_done),
        .walk_fault     (walk_fault),
        .walk_ppn       (walk_ppn),
        .walk_flags     (walk_flags),
        .walk_page_size (walk_pgsz),
        .mem_req        (mem_req),
        .mem_addr       (mem_addr),
        .mem_rdata      (mem_rdata),
        .mem_valid      (mem_valid)
    );

    // ---- Walk result: tinh PA tu walk PPN + registered VA offset ----
    reg [`PA_WIDTH-1:0] walk_pa;
    always @(*) begin
        case (walk_pgsz)
            2'd0: walk_pa = {walk_ppn, va_reg[11:0]};                          // 4KiB
            2'd1: walk_pa = {walk_ppn[`PPN_WIDTH-1:9], va_reg[20:0]};          // 2MiB
            2'd2: walk_pa = {walk_ppn[`PPN_WIDTH-1:18], va_reg[29:0]};         // 1GiB
            default: walk_pa = {walk_ppn, va_reg[11:0]};
        endcase
    end

    // ============================================================
    //  Main FSM
    // ============================================================
    assign ready = (state == ST_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            pa          <= {`PA_WIDTH{1'b0}};
            pa_valid    <= 1'b0;
            page_fault  <= 1'b0;
            walk_start  <= 1'b0;
            tlb_we      <= 1'b0;
            va_reg      <= {`VA_WIDTH{1'b0}};
            acc_reg     <= 2'b00;
            priv_reg    <= 2'b00;
            tlb_wr_vpn  <= {`VPN_TOTAL_W{1'b0}};
            tlb_wr_ppn  <= {`PPN_WIDTH{1'b0}};
            tlb_wr_flags<= 8'h0;
            tlb_wr_pgsz <= 2'd0;
        end else begin
            // Xoa pulse moi cycle
            pa_valid   <= 1'b0;
            page_fault <= 1'b0;
            walk_start <= 1'b0;
            tlb_we     <= 1'b0;

            case (state)
                // ================================================
                //  IDLE: cho request tu CPU
                // ================================================
                ST_IDLE: begin
                    if (req) begin
                        // Luu VA va access info
                        va_reg   <= va;
                        acc_reg  <= access_type;
                        priv_reg <= priv_mode;

                        if (!translation_en) begin
                            // Bypass: M-mode hoac Bare → PA = VA[55:0]
                            pa       <= va[`PA_WIDTH-1:0];
                            pa_valid <= 1'b1;
                        end else if (!va_valid) begin
                            // VA khong hop le (sign extension sai)
                            page_fault <= 1'b1;
                        end else if (tlb_hit) begin
                            // TLB hit → tra PA ngay
                            pa       <= tlb_pa;
                            pa_valid <= 1'b1;
                        end else begin
                            // TLB miss → bat dau walk
                            walk_start <= 1'b1;
                            state      <= ST_WALK;
                        end
                    end
                end

                // ================================================
                //  WALK: cho walker hoan thanh
                // ================================================
                ST_WALK: begin
                    if (walk_done) begin
                        // Walk thanh cong → fill TLB va output PA
                        tlb_we       <= 1'b1;
                        tlb_wr_vpn   <= va_reg_vpn;
                        tlb_wr_ppn   <= walk_ppn;
                        tlb_wr_flags <= walk_flags;
                        tlb_wr_pgsz  <= walk_pgsz;

                        pa       <= walk_pa;
                        pa_valid <= 1'b1;
                        state    <= ST_IDLE;
                    end else if (walk_fault) begin
                        // Walk that bai → page fault
                        page_fault <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
