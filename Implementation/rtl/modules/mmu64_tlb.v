`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_tlb — Fully-Associative TLB (Sv39)
//  - ENTRIES entry, ho tro 4KiB / 2MiB / 1GiB pages
//  - Lookup: combinational (1-cycle hit)
//  - Write: synchronous (fill sau page-table walk)
//  - Flush: dong bo (SFENCE.VMA)
//  - Thay the: round-robin, uu tien entry invalid
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

    // ---- TLB entry storage ----
    reg                    entry_valid [0:ENTRIES-1];
    reg [`VPN_TOTAL_W-1:0] entry_vpn   [0:ENTRIES-1];
    reg [`PPN_WIDTH-1:0]   entry_ppn   [0:ENTRIES-1];
    reg [7:0]              entry_flags [0:ENTRIES-1];
    reg [1:0]              entry_pgsz  [0:ENTRIES-1];
    reg [15:0]             entry_asid  [0:ENTRIES-1];

    // ---- Round-robin counter ----
    reg [`TLB_IDX_W-1:0] rr_ctr;

    // ---- Lookup logic (combinational) ----
    reg [ENTRIES-1:0] match;
    integer i;
    reg [`TLB_IDX_W-1:0] replace_idx;

    always @(*) begin
        lookup_hit       = 1'b0;
        lookup_ppn       = {`PPN_WIDTH{1'b0}};
        lookup_flags     = 8'h0;
        lookup_page_size = 2'b00;

        for (i = 0; i < ENTRIES; i = i + 1) begin
            match[i] = 1'b0;
            if (lookup_req && entry_valid[i]) begin
                // So khop neu la trang Global (G=1) hoac ASID khop voi lookup_asid
                if (entry_flags[i][`PTE_G] || (entry_asid[i] == lookup_asid)) begin
                    case (entry_pgsz[i])
                        2'd0: // 4KiB — so khop toan bo 27-bit VPN
                            match[i] = (entry_vpn[i] == lookup_vpn);
                        2'd1: // 2MiB — so khop VPN[2] va VPN[1] (18 bit cao)
                            match[i] = (entry_vpn[i][26:9] == lookup_vpn[26:9]);
                        2'd2: // 1GiB — so khop VPN[2] (9 bit cao)
                            match[i] = (entry_vpn[i][26:18] == lookup_vpn[26:18]);
                        default: match[i] = 1'b0;
                    endcase
                end
            end
        end

        // Priority encoder: chon match dau tien (index thap nhat)
        for (i = ENTRIES - 1; i >= 0; i = i - 1) begin
            if (match[i]) begin
                lookup_hit       = 1'b1;
                lookup_ppn       = entry_ppn[i];
                lookup_flags     = entry_flags[i];
                lookup_page_size = entry_pgsz[i];
            end
        end
    end

    // ---- Tinh vi tri thay the ----
    always @(*) begin
        replace_idx = rr_ctr;
        // Uu tien entry invalid
        for (i = ENTRIES - 1; i >= 0; i = i - 1) begin
            if (!entry_valid[i])
                replace_idx = i[`TLB_IDX_W-1:0];
        end
    end

    // ---- Sequential: write & flush ----
    integer j;
    always @(posedge clk) begin
        if (!rst_n || flush) begin
            for (j = 0; j < ENTRIES; j = j + 1)
                entry_valid[j] <= 1'b0;
            rr_ctr <= {`TLB_IDX_W{1'b0}};
        end else if (write_en) begin
            entry_valid[replace_idx] <= 1'b1;
            entry_vpn[replace_idx]   <= write_vpn;
            entry_ppn[replace_idx]   <= write_ppn;
            entry_flags[replace_idx] <= write_flags;
            entry_pgsz[replace_idx]  <= write_page_size;
            entry_asid[replace_idx]  <= write_asid;
            rr_ctr                   <= rr_ctr + 1'b1;
        end
    end

endmodule
