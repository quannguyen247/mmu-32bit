# MMU64 — RISC-V Sv39 Memory Management Unit

A synthesizable **64-bit MMU** implementing the **RISC-V Sv39** virtual memory scheme for a single-core **RV64** processor.

## Features

- **Sv39 Translation**: 3-level page table walk (VPN[2] → VPN[1] → VPN[0])
- **TLB**: 16-entry fully-associative Translation Lookaside Buffer with round-robin replacement
- **Superpage Support**: 4 KiB, 2 MiB (megapage), and 1 GiB (gigapage) pages
- **Permission Checking**: Full R/W/X, U/S-mode, `mstatus.SUM`, `mstatus.MXR` support
- **Fault Generation**: Page-fault on invalid PTE, permission violation, misaligned superpage, or bad VA
- **SFENCE.VMA**: TLB flush support
- **M-mode / Bare bypass**: Automatic translation bypass when `satp.MODE = Bare` or privilege = M

## Directory Structure

```
mmu-32bit/
├── .gitignore
├── LICENSE
├── README.md
└── Implementation/
    ├── constraint/
    │   └── mmu64.xdc
    ├── rtl/
    │   ├── modules/
    │   │   ├── mmu64_top.v
    │   │   ├── mmu64_walker.v
    │   │   ├── mmu64_tlb.v
    │   │   ├── mmu64_perm_check.v
    │   │   └── mmu64_pte_decode.v
    │   └── utils/
    │       └── mmu64_defs.vh
    ├── testbench/
    │   ├── tb_mmu64_top.sv
    │   └── tb_mmu64_walker.sv
    └── MMU64.xpr
```

## Simulation

```bash
# ModelSim
vlog +incdir+Implementation/rtl/utils Implementation/rtl/modules/*.v Implementation/testbench/*.sv
vsim -c tb_mmu64_top -do "run -all; quit"
```

## License

Apache License 2.0 — Copyright 2026 Nguyen Dong Quan
