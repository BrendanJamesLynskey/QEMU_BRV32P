# Step Q3: one ELF on QEMU, Spike and the RTL

The table of the last green CI run (job `three-platforms`, pull request 4), from `tests/run_three.sh`. QEMU
`v11.1.3` plus the seven patches, Spike at `fb225a5`, the core repo at `bc75bf8`, riscv-tests at `3df703c`.
How the programs are built and what is compared is in [`design.md`](design.md) sections 11 and 12.

22 / 22 programs agree and pass on every platform they run on (18 with commit logs compared, 480005 instructions)

Each program is built once and the same ELF runs on each platform. "Commit logs compared" lists the pairs whose
logs matched instruction by instruction (pc, encoding, register written); "Instructions compared" is the count
for each pair (they are equal), which is QEMU's instruction count up to the store to `tohost`. The cycle count is
the RTL's; the model has no timing. `none (timing)` means the commit logs cannot be compared (see section 12);
those programs are compared on the verdict, and `uart_hello` also on the output. A verdict of PASS is the
`tohost` value 1 on all the platforms that run the program.

| Program | Source | Platforms | Verdict | UART | Commit logs compared | Instructions compared | RTL cycles |
|---|---|---|---|---|---|---|---|
| `csr_use` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 71 | 400 |
| `dsp_agu` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 69915 | 85822 |
| `dsp_irq` | core tests/directed | QEMU, RTL | PASS | - | none (timing) | - | 63876 |
| `dsp_loop` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 276 | 851 |
| `dsp_mac` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 2081 | 3525 |
| `fence_i_fill` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 35 | 264 |
| `fence_i_warm` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 29 | 219 |
| `gf` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 99 | 493 |
| `misaligned` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 134 | 594 |
| `mq` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 203 | 994 |
| `mul_use` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 86 | 449 |
| `periph_uncached` | core tests/directed | QEMU, RTL | PASS | - | none (timing) | - | 455 |
| `timer_irq` | core tests/directed | QEMU, RTL | PASS | - | none (timing) | - | 11505 |
| `zk` | core tests/directed | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 343 | 1443 |
| `rand_alu` | tests/gen_random.py | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 103574 | 224963 |
| `rand_gf` | tests/gen_random.py | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 26778 | 84488 |
| `rand_mq` | tests/gen_random.py | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 147700 | 360335 |
| `rand_agu` | tests/gen_random.py | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 3566 | 27132 |
| `rand_loop` | tests/gen_random.py | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 8411 | 23364 |
| `dsp_small` | core tests/bench kernels | QEMU, RTL, Spike | PASS | - | RTL=QEMU ok, QEMU=Spike ok, RTL=Spike ok | 116432 | 179159 |
| `firmware` | core firmware.hex | QEMU, RTL | PASS | `H` | RTL=QEMU ok | 272 | 601 |
| `uart_hello` | tests/three | QEMU, RTL | PASS | `BRV32P: one binary, three plat` | none (timing) | - | 4073 |

The UART column is what QEMU and the RTL both sent (`uart_hello`'s line is `BRV32P: one binary, three platforms`).

## SHA-256 of the ELFs

Built once in the CI job and uploaded with the logs (artifact `brv32p-three-platforms`). The hashes depend on
the pinned toolchain (`gcc-riscv64-unknown-elf` of Ubuntu 24.04), so a local build will differ.

| Program | SHA-256 |
|---|---|
| `csr_use` | `62a18d93dfcde5c9a2a05a2dc0b38f99d4436007b530cc4745c425b591391b91` |
| `dsp_agu` | `279b1cbc6905c3a255ae5f351001e6d3f1e735b203c639c0a678ca25bd258c4d` |
| `dsp_irq` | `92059b3a8fdc6c810ff7adfdf6f5226d114c7cafb7cbec062704f0d09530dc36` |
| `dsp_loop` | `2a305f2a0bf6a7ecb7d78db0098e141c1a0a0ef95aa87f43f8228a8fe043a4ac` |
| `dsp_mac` | `d30f47dc8b7a38c9a83a5b2ce6dbdf999588b026b53f3f99acb0925a0181237e` |
| `fence_i_fill` | `6eb29e6ebb72f6dc41f68733a0045c54943e8e2de7f16f2b53b39bd155aa5b04` |
| `fence_i_warm` | `2827ee3c85387da0349813836644ce81744f2a2a5d5dec7527115d512dc85645` |
| `gf` | `9f9413213b7f04ddf0787c1ed2bb19100ffdb38dd85c0080aa5fd6aed58a3f14` |
| `misaligned` | `316d4de04c6f40a95e3d7ff78f12746ece54652cf0adfad0c5d24538d2ce4faf` |
| `mq` | `c71cba0d3a9dde7ad032b01dd41e97ef03a7840934dcaa43909ccc3db30dce71` |
| `mul_use` | `86924076b31e3b3a199d28049604462535b02e508c26c7a1059fd3ad55458a32` |
| `periph_uncached` | `78ab28e88747ef1fe9cf4b016bf662a2f6e61d91b3948d3bc7283424ed84707c` |
| `timer_irq` | `6ad3120b2a5833112e9b12434edc1f4e773998cf7386acb8d4a7f400ae769c8f` |
| `zk` | `8c7efa7f6164e8d04e45eb9c55e7992ab2b66260f4ea3d2af7c9392de0bb084b` |
| `rand_alu` | `37d1341f3f0ef381a6f7fe048354f44bd580f60f82fe34ccd411e15de0db20fb` |
| `rand_gf` | `a1e33c71631ffa0058d071b16b3fbacdbd1d1fc5999251f57b8d2d31cd63f348` |
| `rand_mq` | `76eb8701f8197e22e711e7635388da3f31b2d85561b861393cb347e994910939` |
| `rand_agu` | `5f16ba76d718fea614bd3f26bc2482f96cd6c3f0e3701fda46e5d0298f6e904d` |
| `rand_loop` | `74489aad16bc6d35551c35a30afc4fee0520f2d730c1b9e52d9a00b31e7a2b24` |
| `dsp_small` | `eabe5094dd9927d8d2cae61349c68a2038833cb5af2412da78711bc8686f86ce` |
| `firmware` | `666f8a5c1f8ecac5574a2156094f10c21df7bb5b3efe8726cf5f3508c838154e` |
| `uart_hello` | `495cefa818f6314d8efd5afcad3118b73119c07f9e2f87d792e4070ec39a3c64` |
