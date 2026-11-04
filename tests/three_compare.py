#!/usr/bin/env python3
"""three_compare.py - compare one ELF's runs on QEMU, Spike and the RTL (step Q3).

Usage: three_compare.py <builddir> [--md FILE] [--core DIR] [--selftest] [name ...]

tests/run_three.sh builds each program once and runs it on the platforms; this reads what the runs left in
<builddir> (per program <name>: .meta, .qemu.rc, .qemu.uart, .qemu.trace, .qemu.trace.rc, .spike.rc,
.spike.trace, .rtl.out, .rtl.uart, .rtl.trace) and checks that the platforms agree on

  * the verdict (the value stored to tohost): PASS, FAIL:<test case>, TRAP (the env's 1337), TIMEOUT;
  * the UART output, for the platforms that have a UART (QEMU and the RTL; Spike has none);
  * the commit log, for each pair that can log it: QEMU against Spike (QEMU's execlog plugin against
    Spike's --log-commits, tests/lockstep_qemu.py), the RTL against Spike (the core repo's lockstep.py)
    and the RTL against QEMU (tests/lockstep_qemu.py, reading the RTL's retire trace, which has Spike's
    format).

It prints one line per program, writes <builddir>/results.txt and, with --md, a Markdown table. Any
disagreement, and any program that does not pass, makes the exit status 1. Cycle counts differ by design
and are reported for the RTL only.

--selftest checks the checker: it corrupts a copy of one program's results in four ways (a verdict, a UART
byte, a register value in the RTL trace, a register value in the Spike log) and expects each to be caught.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
QL = os.path.join(HERE, "lockstep_qemu.py")


def read(path, default=""):
    try:
        return open(path, errors="replace").read()
    except OSError:
        return default


def verdict_rc(path):
    """QEMU and Spike exit status (the value stored to tohost >> 1, low 8 bits)."""
    t = read(path).strip()
    if not t:
        return None
    rc = int(t)
    return "PASS" if rc == 0 else "TIMEOUT" if rc == 124 else "TRAP" if rc == 57 else f"FAIL:{rc}"


def verdict_rtl(path):
    """The RTL testbench's RESULT line: (verdict, cycles, retired)."""
    m = re.search(r"RESULT (PASS|FAIL|TIMEOUT)\s+(\d+) cycles (\d+) retired(.*)", read(path))
    if not m:
        return "ERROR", None, None
    kind, cyc, ret, rest = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
    if kind == "FAIL":
        t = re.search(r"test case (\d+)", rest)
        kind = f"FAIL:{int(t.group(1)) & 255}" if t else "TRAP"
    return kind, cyc, ret


def run_cmp(args):
    """Run a comparer; return (ok, last line)."""
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    return p.returncode == 0, "\n".join(lines[-8:])


def evaluate(b, name, core):
    meta = dict(l.strip().split("=", 1) for l in read(f"{b}/{name}.meta").splitlines() if "=" in l)
    spike = meta.get("spike") == "1"
    trace = meta.get("trace") == "1"
    tohost = meta["tohost"]
    ignore = []
    for pc in meta.get("ignore", "").split():
        ignore += ["--ignore-pc", pc]
    r = {"name": name, "src": meta.get("src", ""), "problems": [], "insns": None, "cycles": None}

    verdicts = {}
    verdicts["qemu"] = verdict_rc(f"{b}/{name}.qemu.rc")
    if trace:
        verdicts["qemu(traced)"] = verdict_rc(f"{b}/{name}.qemu.trace.rc")
    if spike:
        verdicts["spike"] = verdict_rc(f"{b}/{name}.spike.rc")
    v, cycles, retired = verdict_rtl(f"{b}/{name}.rtl.out")
    verdicts["rtl"] = v
    r["cycles"], r["retired"] = cycles, retired
    r["platforms"] = "QEMU, RTL" + (", Spike" if spike else "")
    r["verdict"] = verdicts["rtl"]
    if len(set(verdicts.values())) != 1 or None in verdicts.values():
        r["problems"].append("verdicts differ: " + ", ".join(f"{k} {v}" for k, v in verdicts.items()))
    elif v != "PASS":
        r["problems"].append(f"all platforms agree, but the verdict is {v}")

    uq, ur = read(f"{b}/{name}.qemu.uart"), read(f"{b}/{name}.rtl.uart")
    r["uart"] = uq
    if uq != ur:
        r["problems"].append(f"UART output differs: QEMU {uq!r}, RTL {ur!r}")

    r["pairs"] = {}
    counts = []

    def pair(key, args):
        ok, last = run_cmp(args)
        r["pairs"][key] = "match" if ok else "MISMATCH"
        m = re.match(r"MATCH (\d+) instructions", last)
        if ok and m:
            counts.append(int(m.group(1)))
        if not ok:
            r["problems"].append(f"commit log {key}: " + last.replace("\n", " | "))

    if trace:
        pair("RTL=QEMU", [sys.executable, QL, f"{b}/{name}.qemu.trace", f"{b}/{name}.rtl.trace",
                          "--tohost", tohost] + ignore)
    if spike:
        pair("QEMU=Spike", [sys.executable, QL, f"{b}/{name}.qemu.trace", f"{b}/{name}.spike.trace",
                            "--tohost", tohost])
        pair("RTL=Spike", [sys.executable, f"{core}/tests/isa/lockstep.py", f"{b}/{name}.rtl.trace",
                           f"{b}/{name}.spike.trace"])
    if len(set(counts)) > 1:
        r["problems"].append(f"instruction counts differ between pairs: {counts}")
    r["insns"] = counts[0] if counts else None
    r["status"] = "PASS" if not r["problems"] else "MISMATCH" if any(
        "differ" in p or "commit log" in p for p in r["problems"]) else "FAIL"
    return r


def line(r):
    pairs = " ".join(f"{k} {v}" for k, v in r["pairs"].items()) or "no commit log (see design note)"
    ins = f"{r['insns']} instructions compared" if r["insns"] else f"{r['retired']} retired on the RTL, not compared"
    return (f"{r['status']:<8} {r['name']:<16} {r['platforms']:<16} {ins:<42} "
            f"RTL {r['cycles']} cycles  [{pairs}]")


def table(rs):
    out = ["| Program | Source | Platforms | Verdict | UART | Commit logs compared | Instructions compared | RTL cycles |",
           "|---|---|---|---|---|---|---|---|"]
    for r in rs:
        pairs = ", ".join(f"{k} {'ok' if v == 'match' else v}" for k, v in r["pairs"].items()) or "none (timing)"
        uart = "`" + r["uart"].strip().replace("\n", "\\n")[:30] + "`" if r["uart"] else "-"
        out.append(f"| `{r['name']}` | {r['src']} | {r['platforms']} | {r['status'] if r['status'] != 'PASS' else 'PASS'} | "
                   f"{uart} | {pairs} | {r['insns'] if r['insns'] else '-'} | {r['cycles']} |")
    return "\n".join(out)


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def selftest(b, core, names):
    """Corrupt copies of one program's results and expect the check to catch each."""
    def flip_reg(path, frac):
        lines = read(path).splitlines(keepends=True)
        idx = [i for i, l in enumerate(lines) if re.search(r"\bx\d+\s+0x[0-9a-f]{8}", l)]
        i = idx[int(len(idx) * frac)]
        m = list(re.finditer(r"(\bx\d+\s+0x[0-9a-f]{7})([0-9a-f])", lines[i]))[-1]
        d = "0" if m.group(2) != "0" else "1"
        lines[i] = lines[i][:m.start(2)] + d + lines[i][m.end(2):]
        open(path, "w").write("".join(lines))

    cases = [("verdict (QEMU exit status)", "dsp_mac", lambda t, n: open(f"{t}/{n}.qemu.rc", "w").write("3\n")),
             ("UART byte", "uart_hello", lambda t, n: write(f"{t}/{n}.rtl.uart", read(f"{t}/{n}.rtl.uart").replace("B", "C", 1))),
             ("register value in the RTL trace", "dsp_mac", lambda t, n: flip_reg(f"{t}/{n}.rtl.trace", 0.6)),
             ("register value in the Spike log", "dsp_mac", lambda t, n: flip_reg(f"{t}/{n}.spike.trace", 0.4))]
    bad = 0
    for what, name, corrupt in cases:
        if names and name not in names:
            continue
        t = tempfile.mkdtemp(prefix="three-selftest-")
        try:
            for f in os.listdir(b):
                if f.startswith(name + "."):
                    shutil.copy(f"{b}/{f}", t)
            corrupt(t, name)
            r = evaluate(t, name, core)
            caught = r["status"] != "PASS"
            print(f"selftest: corrupted {what} of {name}: {'caught' if caught else 'NOT CAUGHT'}"
                  + (f" ({r['problems'][0][:90]})" if caught else ""))
            bad += not caught
        finally:
            shutil.rmtree(t)
    return bad


def main():
    args = sys.argv[1:]
    b = args.pop(0)
    md = None
    core = os.environ.get("CORE_REPO", os.path.join(HERE, "..", "..", "RISCV_RV32IMC_5stage"))
    do_self = False
    names = []
    while args:
        a = args.pop(0)
        if a == "--md":
            md = args.pop(0)
        elif a == "--core":
            core = args.pop(0)
        elif a == "--selftest":
            do_self = True
        else:
            names.append(a)
    if do_self:
        return 1 if selftest(b, core, names) else 0
    if not names:
        names = [l.split()[0] for l in read(f"{b}/programs.txt").splitlines() if l.strip()]
    rs = [evaluate(b, n, core) for n in names]
    out = []
    for r in rs:
        out.append(line(r))
        for p in r["problems"]:
            out.append("    " + p)
    npass = sum(r["status"] == "PASS" for r in rs)
    traces = sum(1 for r in rs if r["insns"])
    out.append(f"{npass} / {len(rs)} programs agree and pass on every platform they run on "
               f"({traces} with commit logs compared, {sum(r['insns'] or 0 for r in rs)} instructions)")
    text = "\n".join(out)
    print(text)
    open(f"{b}/results.txt", "w").write(text + "\n")
    if md:
        open(md, "w").write(table(rs) + "\n")
    return 0 if npass == len(rs) else 1


if __name__ == "__main__":
    sys.exit(main())
