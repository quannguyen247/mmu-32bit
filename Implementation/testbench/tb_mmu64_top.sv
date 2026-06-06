`timescale 1ns / 1ps

// ============================================================
//  tb_mmu64_top — Full integration test cho MMU64 (Sv39)
//  Test cases:
//    1. TLB miss -> walk -> PA output (4KiB)
//    2. TLB hit (truy cap lai cung page)
//    3. ASID isolation for same VPN
//    4. 2MiB megapage translation
//    5. 1GiB gigapage translation
//    6. SFENCE.VMA -> flush -> TLB miss lai
//    7. M-mode bypass (PA = VA)
//    8. Bare mode bypass
//    9. Invalid VA (sign extension sai) -> fault
//   10. Permission fault (U-mode, S-page)
//   11. Permission fault (store, read-only page)
//   12. Read-only load fills TLB
//   13. Permission fault on TLB-hit store
// ============================================================
module tb_mmu64_top;

    // ---- Signals ----
    logic        clk, rst_n;
    logic [63:0] va;
    logic [1:0]  access_type, priv_mode;
    logic        req, ready;
    logic [63:0] satp;
    logic        mstatus_sum, mstatus_mxr;
    logic [55:0] pa;
    logic        pa_valid, page_fault;
    logic        sfence_vma;
    logic        mem_req;
    logic [55:0] mem_addr;
    logic [63:0] mem_rdata;
    logic        mem_valid;

    // ---- DUT ----
    mmu64_top #(
        .TLB_ENTRIES(16)
    ) u_dut(
        .clk(clk), .rst_n(rst_n),
        .va(va), .access_type(access_type), .priv_mode(priv_mode),
        .req(req), .ready(ready),
        .satp(satp), .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
        .pa(pa), .pa_valid(pa_valid), .page_fault(page_fault),
        .sfence_vma(sfence_vma),
        .mem_req(mem_req), .mem_addr(mem_addr),
        .mem_rdata(mem_rdata), .mem_valid(mem_valid)
    );

    // ---- Clock: 200MHz ----
    initial begin clk = 0; forever #2.5 clk = ~clk; end

    // ---- Memory model ----
    localparam MEM_WORDS = 8192;
    logic [63:0] mem [0:MEM_WORDS-1];

    always @(posedge clk) begin
        mem_valid <= 1'b0;
        if (mem_req) begin
            mem_rdata <= mem[mem_addr[15:3]];
            mem_valid <= 1'b1;
        end
    end

    // ---- Helper: tao PTE ----
    function automatic [63:0] make_pte(
        input [43:0] ppn,
        input logic r, w, x, u, g, a, d, v
    );
        make_pte = {10'b0, ppn, 2'b00, d, a, g, u, x, w, r, v};
    endfunction

    // ---- Test counters ----
    integer pass_count, fail_count, test_num;

    // ---- Captured results ----
    logic        cap_pa_valid, cap_fault;
    logic [55:0] cap_pa;
    logic        timed_out;

    // ---- Memory setup ----
    localparam ROOT_W = 13'h200;
    localparam L1_W   = 13'h400;
    localparam L0_W   = 13'h600;
    localparam ROOT1_W = 13'h800;
    localparam L1_1_W  = 13'hA00;
    localparam L0_1_W  = 13'hC00;

    integer k;
    initial begin
        for (k = 0; k < MEM_WORDS; k = k + 1) mem[k] = 64'h0;

        // Root PT (Level 2)
        mem[ROOT_W + 0] = make_pte(44'h002, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L1
        mem[ROOT_W + 1] = make_pte(44'h00000040000, 1, 1, 1, 1, 0, 1, 1, 1);  // gigapage
        // L1 PT
        mem[L1_W + 0]   = make_pte(44'h003, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L0
        mem[L1_W + 1]   = make_pte(44'h00000000400, 1, 1, 1, 1, 0, 1, 1, 1);  // megapage
        // L0 PT
        mem[L0_W + 0]   = make_pte(44'h00000000800, 1, 1, 1, 1, 0, 1, 1, 1);  // 4KiB RWXU AD
        mem[L0_W + 1]   = make_pte(44'h00000000801, 1, 0, 0, 1, 0, 1, 0, 1);  // 4KiB R-only U
        mem[L0_W + 3]   = make_pte(44'h00000000803, 1, 1, 1, 0, 0, 1, 1, 1);  // 4KiB RWX S-only

        // Alternate address space for ASID isolation test
        mem[ROOT1_W + 0] = make_pte(44'h005, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L1_1
        mem[L1_1_W + 0]  = make_pte(44'h006, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L0_1
        mem[L0_1_W + 0]  = make_pte(44'h00000000900, 1, 1, 1, 1, 0, 1, 1, 1);  // same VPN -> different PPN
    end

    // ---- Task: gui 1 request va kiem tra ----
    task automatic do_translate(
        input string    name,
        input [63:0]    t_va,
        input [1:0]     t_acc,
        input [1:0]     t_priv,
        input [63:0]    t_satp,
        input logic     expect_valid,
        input [55:0]    expect_pa
    );
    begin
        test_num = test_num + 1;
        timed_out = 0;
        cap_pa_valid = 0;
        cap_fault = 0;

        // Cho ready
        while (!ready) @(posedge clk);

        // Assert req — ket qua co the xuat hien ngay posedge tiep theo
        @(posedge clk); #0.1;
        va          = t_va;
        access_type = t_acc;
        priv_mode   = t_priv;
        satp        = t_satp;
        req         = 1'b1;

        // Bat dau polling tu posedge tiep theo (khi FSM xu ly req)
        // Dong thoi deassert req sau 1 cycle
        fork : wait_result
            begin
                forever begin
                    @(posedge clk); #0.1;
                    req = 1'b0;    // Deassert sau 1 cycle
                    if (pa_valid || page_fault) begin
                        cap_pa_valid = pa_valid;
                        cap_fault    = page_fault;
                        cap_pa       = pa;
                        disable wait_result;
                    end
                end
            end
            begin
                repeat(300) @(posedge clk);
                req = 1'b0;
                timed_out = 1;
                disable wait_result;
            end
        join

        if (timed_out) begin
            $display("[FAIL] Test %0d: %s — TIMEOUT", test_num, name);
            fail_count = fail_count + 1;
        end else if (expect_valid) begin
            if (cap_pa_valid && !cap_fault && cap_pa == expect_pa) begin
                $display("[PASS] Test %0d: %s — PA=0x%014h", test_num, name, cap_pa);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %s — pa_valid=%b fault=%b PA=0x%014h (exp 0x%014h)",
                    test_num, name, cap_pa_valid, cap_fault, cap_pa, expect_pa);
                fail_count = fail_count + 1;
            end
        end else begin
            if (cap_fault && !cap_pa_valid) begin
                $display("[PASS] Test %0d: %s — Page fault (expected)", test_num, name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %s — Expected fault, got pa_valid=%b fault=%b",
                    test_num, name, cap_pa_valid, cap_fault);
                fail_count = fail_count + 1;
            end
        end

        repeat(3) @(posedge clk);
    end
    endtask

    // ---- SATP values ----
    localparam [63:0] SATP_SV39       = {4'd8, 16'd0, 44'h001};
    localparam [63:0] SATP_SV39_ASID1 = {4'd8, 16'd1, 44'h004};
    localparam [63:0] SATP_BARE       = 64'h0;

    // ---- Main test ----
    initial begin
        rst_n = 0; req = 0; va = 0; sfence_vma = 0;
        access_type = 2'b00; priv_mode = 2'b01;
        satp = SATP_SV39;
        mstatus_sum = 0; mstatus_mxr = 0;
        pass_count = 0; fail_count = 0; test_num = 0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);

        // ============================================================
        //  Test 1: TLB miss -> walk -> 4KiB page
        //  VA = 0x0000_0000_0000_0ABC
        //  vpn2=0, vpn1=0, vpn0=0, offset=0xABC
        //  PPN=0x800 -> PA = {0x800, 0xABC} = 0x00_0000_0080_0ABC
        // ============================================================
        do_translate("TLB miss -> 4KiB page",
            64'h0000_0000_0000_0ABC, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_0080_0ABC);

        // ============================================================
        //  Test 2: TLB hit (same page, different offset)
        //  VA = 0x0000_0000_0000_0123
        //  PA = 0x00_0000_0080_0123
        // ============================================================
        do_translate("TLB hit (cached)",
            64'h0000_0000_0000_0123, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_0080_0123);

        // Same VPN under a different ASID/root page table must not reuse ASID0 entry.
        do_translate("ASID1 same VPN -> different PA",
            64'h0000_0000_0000_0ABC, 2'b00, 2'b00, SATP_SV39_ASID1,
            1, 56'h00_0000_0090_0ABC);

        // ============================================================
        //  Test 3: 2MiB megapage
        //  VA = 0x0000_0000_0020_0456 -> vpn2=0, vpn1=1, vpn0=0, offset=0x456
        //  PPN=0x400, megapage -> PA = {ppn[43:9], va[20:0]}
        //  ppn[43:9] = 0x2, va[20:0] = 0x000456
        //  PA = 0x00_0000_0040_0456
        // ============================================================
        do_translate("2MiB megapage",
            64'h0000_0000_0020_0456, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_0040_0456);

        // ============================================================
        //  Test 4: 1GiB gigapage
        //  VA = 0x0000_0000_4012_3789 -> vpn2=1
        //  PPN=0x00000040000, gigapage -> PA = {ppn[43:18], va[29:0]}
        //  ppn[43:18] = 0x1, va[29:0] = 0x0012_3789
        //  PA = 0x00_0000_4012_3789
        // ============================================================
        do_translate("1GiB gigapage",
            64'h0000_0000_4012_3789, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_4012_3789);

        // ============================================================
        //  Test 5: SFENCE.VMA -> flush TLB -> TLB miss (re-walk)
        // ============================================================
        @(posedge clk); #0.1;
        sfence_vma = 1'b1;
        @(posedge clk); #0.1;
        sfence_vma = 1'b0;
        repeat(3) @(posedge clk);

        do_translate("After SFENCE -> re-walk",
            64'h0000_0000_0000_0ABC, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_0080_0ABC);

        // ============================================================
        //  Test 6: M-mode bypass -> PA = VA[55:0]
        // ============================================================
        do_translate("M-mode bypass",
            64'h0000_0000_DEAD_BEEF, 2'b00, 2'b11, SATP_SV39,
            1, 56'h00_0000_DEAD_BEEF);

        // ============================================================
        //  Test 7: Bare mode bypass -> PA = VA[55:0]
        // ============================================================
        do_translate("Bare mode bypass",
            64'h0000_0000_CAFE_1234, 2'b00, 2'b01, SATP_BARE,
            1, 56'h00_0000_CAFE_1234);

        // ============================================================
        //  Test 8: Invalid VA (sign extension fail) -> fault
        //  VA[63:39] != {25{VA[38]}}
        // ============================================================
        do_translate("Invalid VA (bad sign extension)",
            64'h0000_0080_0000_0000, 2'b00, 2'b01, SATP_SV39,
            0, 56'h0);

        // ============================================================
        //  Test 9: U-mode accessing S-only page -> fault
        //  vpn0=3 -> S-page (U=0), priv=U-mode
        //  VA = 0x0000_0000_0000_3100
        // ============================================================
        do_translate("U-mode access S-page -> fault",
            64'h0000_0000_0000_3100, 2'b00, 2'b00, SATP_SV39,
            0, 56'h0);

        // ============================================================
        //  Test 10: Store to read-only page -> fault
        //  vpn0=1 -> R-only page, access=STORE
        //  VA = 0x0000_0000_0000_1200
        // ============================================================
        do_translate("Store to read-only page -> fault",
            64'h0000_0000_0000_1200, 2'b01, 2'b00, SATP_SV39,
            0, 56'h0);

        // Fill a read-only mapping, then ensure a store faults on TLB hit.
        do_translate("Load read-only page -> fill TLB",
            64'h0000_0000_0000_1200, 2'b00, 2'b00, SATP_SV39,
            1, 56'h00_0000_0080_1200);

        do_translate("TLB hit store to read-only page -> fault",
            64'h0000_0000_0000_1200, 2'b01, 2'b00, SATP_SV39,
            0, 56'h0);

        // ---- Summary ----
        $display("");
        $display("============================================");
        $display("  MMU64 TOP TEST SUMMARY: %0d PASSED, %0d FAILED (total %0d)",
            pass_count, fail_count, pass_count + fail_count);
        $display("============================================");
        $display("");

        #100;
        $finish;
    end

endmodule
