`timescale 1ns / 1ps

// ============================================================
//  tb_mmu64_walker — Unit test cho 3-level page table walker
//  Test cases:
//    1. 4KiB page (3-level walk)
//    2. 2MiB megapage (2-level, leaf tai level 1)
//    3. 1GiB gigapage (1-level, leaf tai level 2)
//    4. Invalid PTE (V=0) → fault
//    5. Permission fault (store vao read-only page)
//    6. Misaligned megapage → fault
//    7. Reserved encoding (W=1, R=0) → fault
// ============================================================
module tb_mmu64_walker;

    // ---- Signals ----
    logic        clk, rst_n;
    logic        walk_req;
    logic [26:0] vpn;
    logic [1:0]  access_type, priv_mode;
    logic [43:0] satp_ppn;
    logic        mstatus_sum, mstatus_mxr;

    logic        walk_done, walk_fault;
    logic [43:0] walk_ppn;
    logic [7:0]  walk_flags;
    logic [1:0]  walk_page_size;

    logic        mem_req;
    logic [55:0] mem_addr;
    logic [63:0] mem_rdata;
    logic        mem_valid;

    // ---- DUT ----
    mmu64_walker u_dut(
        .clk(clk), .rst_n(rst_n),
        .walk_req(walk_req), .vpn(vpn),
        .access_type(access_type), .priv_mode(priv_mode),
        .satp_ppn(satp_ppn),
        .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
        .walk_done(walk_done), .walk_fault(walk_fault),
        .walk_ppn(walk_ppn), .walk_flags(walk_flags),
        .walk_page_size(walk_page_size),
        .mem_req(mem_req), .mem_addr(mem_addr),
        .mem_rdata(mem_rdata), .mem_valid(mem_valid)
    );

    // ---- Clock: 200MHz (5ns period) ----
    initial begin clk = 0; forever #2.5 clk = ~clk; end

    // ---- Memory model (64-bit word addressed, 1-cycle latency) ----
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

    // ---- Counters ----
    integer pass_count, fail_count, test_num;

    // ---- Captured results ----
    logic        cap_done, cap_fault;
    logic [43:0] cap_ppn;
    logic [1:0]  cap_pgsz;
    logic        timed_out;

    // ---- Task: chay 1 test case ----
    task automatic run_walk(
        input string    name,
        input [26:0]    t_vpn,
        input [1:0]     t_acc,
        input [1:0]     t_priv,
        input logic     expect_done,
        input [43:0]    expect_ppn,
        input [1:0]     expect_pgsz
    );
    begin
        test_num = test_num + 1;
        timed_out = 0;

        @(posedge clk); #0.1;
        vpn = t_vpn;
        access_type = t_acc;
        priv_mode = t_priv;
        walk_req = 1'b1;
        @(posedge clk); #0.1;
        walk_req = 1'b0;

        // Cho walk_done hoac walk_fault xuat hien tren canh len clock
        fork : wait_walk
            begin
                forever begin
                    @(posedge clk); #0.1;
                    if (walk_done || walk_fault) begin
                        cap_done  = walk_done;
                        cap_fault = walk_fault;
                        cap_ppn   = walk_ppn;
                        cap_pgsz  = walk_page_size;
                        disable wait_walk;
                    end
                end
            end
            begin
                repeat(200) @(posedge clk);
                timed_out = 1;
                disable wait_walk;
            end
        join

        if (timed_out) begin
            $display("[FAIL] Test %0d: %s — TIMEOUT", test_num, name);
            fail_count = fail_count + 1;
        end else if (expect_done) begin
            if (cap_done && !cap_fault && cap_ppn == expect_ppn && cap_pgsz == expect_pgsz) begin
                $display("[PASS] Test %0d: %s — PPN=0x%011h, PageSize=%0d", test_num, name, cap_ppn, cap_pgsz);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %s — done=%b fault=%b PPN=0x%011h(exp 0x%011h) pgsz=%0d(exp %0d)",
                    test_num, name, cap_done, cap_fault, cap_ppn, expect_ppn, cap_pgsz, expect_pgsz);
                fail_count = fail_count + 1;
            end
        end else begin
            if (cap_fault && !cap_done) begin
                $display("[PASS] Test %0d: %s — Fault detected (expected)", test_num, name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %s — Expected fault but got done=%b fault=%b",
                    test_num, name, cap_done, cap_fault);
                fail_count = fail_count + 1;
            end
        end

        repeat(3) @(posedge clk);
    end
    endtask

    // ---- Memory setup constants ----
    localparam ROOT_W = 13'h200;   // PPN=0x001 -> PA=0x1000
    localparam L1_W   = 13'h400;   // PPN=0x002 -> PA=0x2000
    localparam L0_W   = 13'h600;   // PPN=0x003 -> PA=0x3000

    integer k;
    initial begin
        for (k = 0; k < MEM_WORDS; k = k + 1) mem[k] = 64'h0;

        // Root PT (Level 2)
        mem[ROOT_W + 0] = make_pte(44'h002, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L1
        mem[ROOT_W + 1] = make_pte(44'h00000040000, 1, 1, 1, 1, 0, 1, 1, 1);  // gigapage
        mem[ROOT_W + 2] = 64'h0;                                               // invalid

        // L1 PT (Level 1)
        mem[L1_W + 0]   = make_pte(44'h003, 0, 0, 0, 0, 0, 0, 0, 1);          // pointer -> L0
        mem[L1_W + 1]   = make_pte(44'h00000000400, 1, 1, 1, 1, 0, 1, 1, 1);  // megapage
        mem[L1_W + 2]   = make_pte(44'h00000000401, 1, 1, 1, 1, 0, 1, 1, 1);  // misaligned megapage
        mem[L1_W + 3]   = make_pte(44'h00000000500, 0, 1, 0, 1, 0, 1, 1, 1);  // reserved (W=1,R=0)

        // L0 PT (Level 0)
        mem[L0_W + 0]   = make_pte(44'h00000000800, 1, 1, 1, 1, 0, 1, 1, 1);  // 4KiB RWXU AD
        mem[L0_W + 1]   = make_pte(44'h00000000801, 1, 0, 0, 1, 0, 1, 0, 1);  // 4KiB R-only U
        mem[L0_W + 2]   = 64'h0;                                               // invalid
        mem[L0_W + 3]   = make_pte(44'h00000000803, 1, 1, 1, 0, 0, 1, 1, 1);  // 4KiB RWX S-only
    end

    // ---- Main test sequence ----
    initial begin
        rst_n = 0; walk_req = 0; vpn = 0;
        access_type = 2'b00; priv_mode = 2'b01;
        satp_ppn = 44'h001;
        mstatus_sum = 0; mstatus_mxr = 0;
        pass_count = 0; fail_count = 0; test_num = 0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);

        // Test 1: 4KiB page (U-mode load, U-page)
        run_walk("4KiB normal page",
            {9'd0, 9'd0, 9'd0}, 2'b00, 2'b00, 1, 44'h00000000800, 2'd0);

        // Test 2: 2MiB megapage (U-mode load, U-page)
        run_walk("2MiB megapage",
            {9'd0, 9'd1, 9'd0}, 2'b00, 2'b00, 1, 44'h00000000400, 2'd1);

        // Test 3: 1GiB gigapage (U-mode load, U-page)
        run_walk("1GiB gigapage",
            {9'd1, 9'd0, 9'd0}, 2'b00, 2'b00, 1, 44'h00000040000, 2'd2);

        // Test 4: Invalid PTE (V=0)
        run_walk("Invalid PTE (V=0)",
            {9'd0, 9'd0, 9'd2}, 2'b00, 2'b01, 0, 44'h0, 2'd0);

        // Test 5: Store to read-only page
        run_walk("Store to read-only page",
            {9'd0, 9'd0, 9'd1}, 2'b01, 2'b00, 0, 44'h0, 2'd0);

        // Test 6: Misaligned megapage
        run_walk("Misaligned megapage",
            {9'd0, 9'd2, 9'd0}, 2'b00, 2'b01, 0, 44'h0, 2'd0);

        // Test 7: Reserved encoding (W=1, R=0)
        run_walk("Reserved PTE encoding (W=1 R=0)",
            {9'd0, 9'd3, 9'd0}, 2'b00, 2'b01, 0, 44'h0, 2'd0);

        $display("");
        $display("============================================");
        $display("  WALKER TEST SUMMARY: %0d PASSED, %0d FAILED (total %0d)",
            pass_count, fail_count, pass_count + fail_count);
        $display("============================================");
        $display("");

        #50;
        $finish;
    end

endmodule
