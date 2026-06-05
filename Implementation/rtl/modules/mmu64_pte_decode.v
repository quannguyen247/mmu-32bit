`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_pte_decode — Combinational PTE field decoder
//  Trich xuat cac truong tu 64-bit PTE (Sv39)
// ============================================================
module mmu64_pte_decode(
    input wire [`PTE_WIDTH-1:0] pte_in,

    output wire [`PPN_WIDTH-1:0] ppn,       // PPN[43:0]
    output wire [25:0]           ppn2,      // PPN[2] — 26 bits
    output wire [8:0]            ppn1,      // PPN[1] — 9 bits
    output wire [8:0]            ppn0,      // PPN[0] — 9 bits
    output wire                  valid,
    output wire                  readable,
    output wire                  writable,
    output wire                  executable,
    output wire                  user_mode,
    output wire                  global_flag,
    output wire                  accessed,
    output wire                  dirty,
    output wire                  is_leaf,    // R=1 hoac X=1
    output wire                  is_pointer  // V=1, R=0, W=0, X=0
);

    // Trich xuat PPN
    assign ppn0 = pte_in[`PTE_PPN0];
    assign ppn1 = pte_in[`PTE_PPN1];
    assign ppn2 = pte_in[`PTE_PPN2];
    assign ppn  = pte_in[`PTE_PPN];

    // Trich xuat cac flag
    assign valid       = pte_in[`PTE_V];
    assign readable    = pte_in[`PTE_R];
    assign writable    = pte_in[`PTE_W];
    assign executable  = pte_in[`PTE_X];
    assign user_mode   = pte_in[`PTE_U];
    assign global_flag = pte_in[`PTE_G];
    assign accessed    = pte_in[`PTE_A];
    assign dirty       = pte_in[`PTE_D];

    // Leaf node: V=1 va (R=1 hoac X=1)
    assign is_leaf    = valid & (readable | executable);

    // Pointer node: V=1, R=0, W=0, X=0
    assign is_pointer = valid & ~readable & ~writable & ~executable;

endmodule
