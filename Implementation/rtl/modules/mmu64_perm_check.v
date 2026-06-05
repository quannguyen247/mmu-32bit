`timescale 1ns / 1ps
`include "mmu64_defs.vh"

// ============================================================
//  mmu64_perm_check — Kiem tra quyen truy cap PTE (Sv39)
//  Combinational: tra ve fault = 1 khi vi pham quyen
//  Tham chieu: RISC-V Privileged Spec v1.12, Section 4.3.2
// ============================================================
module mmu64_perm_check(
    input wire [1:0] access_type,   // ACC_LOAD / ACC_STORE / ACC_EXEC
    input wire [1:0] priv_mode,     // PRIV_U / PRIV_S / PRIV_M
    input wire       pte_r,
    input wire       pte_w,
    input wire       pte_x,
    input wire       pte_u,
    input wire       pte_a,
    input wire       pte_d,
    input wire       mstatus_sum,   // Supervisor User Memory access
    input wire       mstatus_mxr,   // Make eXecutable Readable
    output wire      fault
);

    reg perm_fail;

    always @(*) begin
        perm_fail = 1'b0;

        // --- A bit phai duoc set ---
        if (!pte_a)
            perm_fail = 1'b1;

        // --- D bit phai duoc set cho Store ---
        if (access_type == `ACC_STORE && !pte_d)
            perm_fail = 1'b1;

        // --- Kiem tra quyen theo privilege mode ---
        case (priv_mode)
            `PRIV_U: begin
                // U-mode: PTE.U phai = 1
                if (!pte_u)
                    perm_fail = 1'b1;
            end
            `PRIV_S: begin
                // S-mode: khong duoc truy cap trang U tru khi SUM = 1
                if (pte_u && !mstatus_sum)
                    perm_fail = 1'b1;
                // S-mode: khong bao gio duoc execute trang U
                if (pte_u && access_type == `ACC_EXEC)
                    perm_fail = 1'b1;
            end
            default: ; // M-mode: khong kiem tra (bypass o tang tren)
        endcase

        // --- Kiem tra quyen theo loai truy cap ---
        case (access_type)
            `ACC_LOAD: begin
                // Can R=1, hoac (MXR=1 va X=1)
                if (!pte_r && !(mstatus_mxr && pte_x))
                    perm_fail = 1'b1;
            end
            `ACC_STORE: begin
                // Can W=1
                if (!pte_w)
                    perm_fail = 1'b1;
            end
            `ACC_EXEC: begin
                // Can X=1
                if (!pte_x)
                    perm_fail = 1'b1;
            end
            default: perm_fail = 1'b1;
        endcase
    end

    assign fault = perm_fail;

endmodule
