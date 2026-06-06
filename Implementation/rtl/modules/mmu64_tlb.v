`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_tlb - Fully-associative TLB (Sv39)
//  Split into small entry cells so Vivado does not place all TLB
//  primitives in one large cellview during rebuilt hierarchy.
// ============================================================
module mmu64_tlb #(
    parameter ENTRIES = `TLB_ENTRIES
)(
    input wire                    clk,
    input wire                    rst_n,

    // --- Lookup (combinational) ---
    input wire [`VPN_TOTAL_W-1:0] lookup_vpn,       // {VPN2, VPN1, VPN0}
    input wire                    lookup_req,
    input wire [15:0]             lookup_asid,
    output reg                    lookup_hit,
    output reg [`PPN_WIDTH-1:0]   lookup_ppn,
    output reg [7:0]              lookup_flags,      // {D,A,G,U,X,W,R,V}
    output reg [1:0]              lookup_page_size,  // 0=4KiB, 1=2MiB, 2=1GiB

    // --- Write (synchronous) ---
    input wire                    write_en,
    input wire [`VPN_TOTAL_W-1:0] write_vpn,
    input wire [`PPN_WIDTH-1:0]   write_ppn,
    input wire [7:0]              write_flags,
    input wire [1:0]              write_page_size,
    input wire [15:0]             write_asid,

    // --- Flush ---
    input wire                    flush
);

    wire [ENTRIES-1:0] entry_valid;
    wire [ENTRIES-1:0] match;
    wire [ENTRIES*`PPN_WIDTH-1:0] entry_ppn_flat;
    wire [ENTRIES*8-1:0]          entry_flags_flat;
    wire [ENTRIES*2-1:0]          entry_pgsz_flat;

    reg [`TLB_IDX_W-1:0] rr_ctr;
    reg [`TLB_IDX_W-1:0] replace_idx;

    genvar g;
    generate
        for (g = 0; g < ENTRIES; g = g + 1) begin : g_entry
            mmu64_tlb_entry u_entry (
                .clk             (clk),
                .rst_n           (rst_n),
                .flush           (flush),
                .lookup_req      (lookup_req),
                .lookup_vpn      (lookup_vpn),
                .lookup_asid     (lookup_asid),
                .match           (match[g]),
                .entry_valid     (entry_valid[g]),
                .entry_ppn       (entry_ppn_flat[g*`PPN_WIDTH +: `PPN_WIDTH]),
                .entry_flags     (entry_flags_flat[g*8 +: 8]),
                .entry_page_size (entry_pgsz_flat[g*2 +: 2]),
                .write_en        (write_en && (replace_idx == g)),
                .write_vpn       (write_vpn),
                .write_ppn       (write_ppn),
                .write_flags     (write_flags),
                .write_page_size (write_page_size),
                .write_asid      (write_asid)
            );
        end
    endgenerate

    integer i;
    always @(*) begin
        lookup_hit       = 1'b0;
        lookup_ppn       = {`PPN_WIDTH{1'b0}};
        lookup_flags     = 8'h0;
        lookup_page_size = 2'b00;

        // Priority encoder: low index wins, matching previous behavior.
        for (i = ENTRIES - 1; i >= 0; i = i - 1) begin
            if (match[i]) begin
                lookup_hit       = 1'b1;
                lookup_ppn       = entry_ppn_flat[i*`PPN_WIDTH +: `PPN_WIDTH];
                lookup_flags     = entry_flags_flat[i*8 +: 8];
                lookup_page_size = entry_pgsz_flat[i*2 +: 2];
            end
        end
    end

    always @(*) begin
        replace_idx = rr_ctr;
        for (i = ENTRIES - 1; i >= 0; i = i - 1) begin
            if (!entry_valid[i])
                replace_idx = i[`TLB_IDX_W-1:0];
        end
    end

    always @(posedge clk) begin
        if (!rst_n || flush)
            rr_ctr <= {`TLB_IDX_W{1'b0}};
        else if (write_en)
            rr_ctr <= rr_ctr + 1'b1;
    end

endmodule

module mmu64_tlb_entry(
    input wire                    clk,
    input wire                    rst_n,
    input wire                    flush,

    input wire                    lookup_req,
    input wire [`VPN_TOTAL_W-1:0] lookup_vpn,
    input wire [15:0]             lookup_asid,
    output wire                   match,
    output wire                   entry_valid,
    output wire [`PPN_WIDTH-1:0]  entry_ppn,
    output wire [7:0]             entry_flags,
    output wire [1:0]             entry_page_size,

    input wire                    write_en,
    input wire [`VPN_TOTAL_W-1:0] write_vpn,
    input wire [`PPN_WIDTH-1:0]   write_ppn,
    input wire [7:0]              write_flags,
    input wire [1:0]              write_page_size,
    input wire [15:0]             write_asid
);

    reg                    valid_q;
    reg [`VPN_TOTAL_W-1:0] vpn_q;
    reg [`PPN_WIDTH-1:0]   ppn_q;
    reg [7:0]              flags_q;
    reg [1:0]              pgsz_q;
    reg [15:0]             asid_q;

    assign entry_valid     = valid_q;
    assign entry_ppn       = ppn_q;
    assign entry_flags     = flags_q;
    assign entry_page_size = pgsz_q;

    reg vpn_match;
    always @(*) begin
        case (pgsz_q)
            2'd0:    vpn_match = (vpn_q == lookup_vpn);
            2'd1:    vpn_match = (vpn_q[26:9] == lookup_vpn[26:9]);
            2'd2:    vpn_match = (vpn_q[26:18] == lookup_vpn[26:18]);
            default: vpn_match = 1'b0;
        endcase
    end

    wire asid_match = flags_q[`PTE_G] || (asid_q == lookup_asid);
    assign match = lookup_req && valid_q && asid_match && vpn_match;

    always @(posedge clk) begin
        if (!rst_n || flush) begin
            valid_q <= 1'b0;
        end else if (write_en) begin
            valid_q <= 1'b1;
            vpn_q   <= write_vpn;
            ppn_q   <= write_ppn;
            flags_q <= write_flags;
            pgsz_q  <= write_page_size;
            asid_q  <= write_asid;
        end
    end

endmodule
