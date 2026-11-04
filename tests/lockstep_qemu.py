#!/usr/bin/env python3
"""Compare QEMU's execution log with Spike's commit log, instruction by instruction.

Usage: lockstep_qemu.py <qemu.log> <spike.log> [--tohost ADDR] [--start-pc ADDR]

The QEMU log is the output of its `execlog` TCG plugin (run with
`-d plugin,int`, the plugin watching the 31 general registers). The Spike log
is `spike --log-commits` with the core repo's libxbrvdsp.so loaded. Both are
reduced to one record per retired instruction:

    (pc, encoding, register write)

and compared in order. Where this differs from the core repo's lockstep.py,
which compares Spike with the RTL:

* The plugin logs a register only when its value changes, Spike logs every
  write. So QEMU's registers are kept as a shadow, and a Spike write of a
  value the register already holds is a match. A change QEMU makes that Spike
  does not log is a mismatch.
* The plugin logs an instruction as it starts, so one that traps is logged
  too; Spike (like the RTL's retire trace) does not log it. The `-d int` line
  QEMU prints for a synchronous exception names the instruction (epc), and
  that record is dropped.
* The run ends at the test's store to `tohost` (QEMU goes on for a few
  instructions of the `j .` that follows it, until its main loop sees the
  shutdown request, and Spike until its host interface sees the store), so
  both logs are cut at that store, which must be there if --tohost is given.
* Stores are compared by instruction, not by data (the plugin logs the
  address, not the data).

Exits 0 if the two match for the whole of QEMU's run; otherwise prints the
first mismatch with context and exits 1. A summary line gives the number of
instructions and, for the custom ones, how many of each were compared.
"""
import re
import sys
from collections import Counter, deque

ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "fp", "s1", "a0", "a1", "a2", "a3", "a4",
       "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
       "t3", "t4", "t5", "t6"]
REG_NUM = {n: i for i, n in enumerate(ABI)}
REG_NUM["s0"] = 8

QLINE = re.compile(r'^\d+, 0x([0-9a-f]+), 0x([0-9a-f]+), "[^"]*"(.*)$')
QCHG = re.compile(r',\s*([a-z0-9]+) -> 0x([0-9a-f]+)')
QTRAP = re.compile(r'riscv_cpu_do_interrupt: hart:\d+, async:0, cause:\w+, epc:0x([0-9a-f]+)')
SLINE = re.compile(r"core\s+0:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
SREG = re.compile(r"\bx(\d+)\s+0x([0-9a-f]+)")
SMEM = re.compile(r"\bmem\s+0x([0-9a-f]+)")

# Custom encodings, for the coverage count: (name, mask, match)
CUSTOM = [
    ("mac", 0xFE007FFF, 0x0000000B), ("dmac", 0xFE007FFF, 0x0200000B), ("msu", 0xFE007FFF, 0x0400000B),
    ("mac.lp", 0xFE007FFF, 0x8000000B), ("dmac.lp", 0xFE007FFF, 0x8200000B),
    ("msu.lp", 0xFE007FFF, 0x8400000B),
    ("acc.set", 0xFFF07FFF, 0x0800000B), ("acc.seth", 0xFFF07FFF, 0x0A00000B),
    ("acc.rd", 0xFE0FF07F, 0x0000100B), ("acc.rdh", 0xFE0FF07F, 0x0000200B),
    ("acc.rdl", 0xFFFFF07F, 0x0000300B), ("acc.rdx", 0xFFFFF07F, 0x0200300B),
    ("sadd", 0xFE00707F, 0x0000400B), ("ssub", 0xFE00707F, 0x0200400B),
    ("radd16", 0xFE00707F, 0x0400400B), ("rsub16", 0xFE00707F, 0x0600400B),
    ("pk16", 0xFE00707F, 0x0800400B),
    ("gfmul4", 0xFE00707F, 0x0000500B), ("gf.cfg", 0xFFF07FFF, 0x0200500B), ("gf.rd", 0xFFFFF07F, 0x0400500B),
    ("mqmul2", 0xFE00707F, 0x0000600B), ("mqadd2", 0xFE00707F, 0x0200600B),
    ("mqsub2", 0xFE00707F, 0x0400600B), ("ctadd2", 0xFE00707F, 0x0600600B),
    ("ctsub2", 0xFE00707F, 0x0800600B), ("gsmul2", 0xFE00707F, 0x1200600B),
    ("mq.cfg", 0xFFF07FFF, 0x0A00600B), ("mq.zeta", 0xFFF07FFF, 0x0C00600B),
    ("mq.rd", 0xFFFFF07F, 0x0E00600B), ("mq.rdz", 0xFFFFF07F, 0x1000600B),
    ("ar.set", 0xFFF07E7F, 0x0000002B), ("ar.cfg", 0xFFF07E7F, 0x0200002B),
    ("ar.mode", 0xFFF07E7F, 0x0600002B),
    ("lh.a", 0xFFCFF07F, 0x0000102B), ("lw.a", 0xFFCFF07F, 0x0000202B), ("lhu.a", 0xFFCFF07F, 0x0000502B),
    ("ar.rd", 0xFFCFF07F, 0x0000302B), ("ar.rds", 0xFFCFF07F, 0x0040302B),
    ("ar.rdm", 0xFFCFF07F, 0x00C0302B),
    ("lp.setup", 0xFFF07FFF, 0x0000602B), ("lp.end", 0xFFFFFFFF, 0x0000702B),
    ("lp.set", 0xFFF07FFF, 0x0400002B), ("lp.sets", 0xFFF07FFF, 0x040000AB),
    ("lp.rd", 0xFFFFF07F, 0x0080302B), ("lp.rds", 0xFFFFF07F, 0x0090302B),
]


def custom_name(insn):
    if insn & 0x7F not in (0x0B, 0x2B):
        return None
    for name, mask, match in CUSTOM:
        if insn & mask == match:
            return name
    return "custom?"


def qemu_records(path, start_pc):
    """(pc, insn, {reg: value}, line) per executed, non-trapping instruction."""
    drop_epc = None
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        t = QTRAP.search(line)
        if t:
            drop_epc = int(t.group(1), 16) & 0xFFFFFFFF   # QEMU prints the pc sign-extended
            continue
        m = QLINE.match(line)
        if not m:
            continue
        pc, insn = int(m.group(1), 16), int(m.group(2), 16)
        if drop_epc is not None:
            drop_epc, was = None, drop_epc
            if pc == was:
                continue                                # the instruction that trapped
        if pc < start_pc:
            continue
        writes = {}
        for r in QCHG.finditer(m.group(3)):
            if r.group(1) in REG_NUM and REG_NUM[r.group(1)] != 0:
                writes[REG_NUM[r.group(1)]] = int(r.group(2), 16)
        yield pc, insn, writes, line


def spike_records(path, start_pc):
    for line in open(path, errors="replace"):
        m = SLINE.match(line.strip())
        if not m:
            continue
        pc, insn, rest = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
        if pc < start_pc:
            continue
        x = SREG.search(rest)
        reg = (int(x.group(1)), int(x.group(2), 16)) if x and x.group(1) != "0" else None
        mem = SMEM.search(rest)
        yield pc, insn, reg, int(mem.group(1), 16) if mem else None, line.rstrip()


def main():
    args = sys.argv[1:]
    tohost = start_pc = None
    start_pc = 0x80000000
    paths = []
    while args:
        a = args.pop(0)
        if a == "--tohost":
            tohost = int(args.pop(0), 16)
        elif a == "--start-pc":
            start_pc = int(args.pop(0), 16)
        else:
            paths.append(a)
    qpath, spath = paths
    shadow = [0] * 32
    recent = deque(maxlen=3)
    cover = Counter()
    n = 0
    last_s = None
    ended = False
    spike = spike_records(spath, start_pc)
    for q in qemu_records(qpath, start_pc):
        s = next(spike, None)
        if s is None:
            print(f"LENGTH MISMATCH: Spike's log ended after {n} instructions, QEMU's goes on")
            print(f"  QEMU  {q[3]}")
            return 1
        qpc, qinsn, qwrites, qline = q
        spc, sinsn, sreg, smem, sline = s
        problem = None
        if qpc != spc or qinsn != sinsn:
            problem = "pc or instruction"
        else:
            for r, v in qwrites.items():
                shadow[r] = v
            if sreg is not None:
                r, v = sreg
                if shadow[r] != v:
                    problem = f"x{r}: QEMU {shadow[r]:#010x}, Spike {v:#010x}"
                if set(qwrites) - {r}:
                    problem = problem or f"QEMU changed x{sorted(set(qwrites) - {r})} too"
            elif qwrites:
                problem = f"QEMU wrote x{sorted(qwrites)}, Spike wrote no register"
        if problem:
            print(f"MISMATCH at instruction {n} ({problem}):")
            for ok in recent:
                print(f"   ok   {ok}")
            print(f"  QEMU  {qline}")
            print(f"  Spike {sline}")
            return 1
        recent.append(qline)
        name = custom_name(qinsn)
        if name:
            cover[name] += 1
        n += 1
        last_s = s
        if tohost is not None and smem == tohost:
            ended = True                      # the test's store to tohost: the run is over
            break
    if n == 0:
        print("NO INSTRUCTIONS in the QEMU log")
        return 1
    if tohost is not None and not ended:
        print(f"END MISMATCH: QEMU's log ended without the store to tohost ({tohost:#x}); "
              f"the first {n} instructions match")
        return 1
    rest = sum(1 for _ in spike)
    ncustom = sum(cover.values())
    print(f"MATCH {n} instructions ({ncustom} custom: " +
          ", ".join(f"{k} {v}" for k, v in sorted(cover.items())) + f"; Spike ran {rest} more after the store)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
