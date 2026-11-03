#!/usr/bin/env python3
"""run_machine.py - tests of -M brv32p that need the host to take part.

  firmware  the SoC firmware (core repo firmware/gen_firmware.py) loaded at 0:
            UART output, GPIO pattern, registers, and the ECALL restart
  timer     tests/machine/timer.S   (ends through tohost)
  uart      tests/machine/uart.S    (the host feeds the serial line)
  gpio      tests/machine/gpio.S    (the host drives and reads the pins by QMP)

Usage: tests/run_machine.py [test ...]
Env:   QEMU, CORE_REPO, CROSS as for tests/run_isa.sh
Output: tests/build/machine/results.txt; exit status 0 if all passed.
"""
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
QEMU = os.environ.get("QEMU", os.path.join(ROOT, "build/qemu/qemu-system-riscv32"))
CORE = os.environ.get("CORE_REPO", os.path.join(ROOT, "..", "RISCV_RV32IMC_5stage"))
CROSS = os.environ.get("CROSS", "riscv64-unknown-elf-")
OUT = os.path.join(ROOT, "tests", "build", "machine")
os.makedirs(OUT, exist_ok=True)


class Qemu:
    """A running -M brv32p: serial on its stdio pipes, QMP on a socket."""

    def __init__(self, extra, icount=True):
        self.sock_path = tempfile.mktemp(prefix="brv32p-qmp-", suffix=".sock")
        cmd = [QEMU, "-M", "brv32p", "-display", "none", "-monitor", "none",
               "-serial", "stdio", "-no-reboot",
               "-qmp", "unix:%s,server=on,wait=off" % self.sock_path]
        if icount:
            cmd += ["-icount", "shift=3"]
        self.proc = subprocess.Popen(cmd + extra, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.out = b""
        self.qmp_sock = None
        for _ in range(100):
            try:
                s = socket.socket(socket.AF_UNIX)
                s.connect(self.sock_path)
                self.qmp_sock = s
                break
            except OSError:
                time.sleep(0.05)
        if self.qmp_sock:
            self.qmp_file = self.qmp_sock.makefile("rw")
            self.qmp_file.readline()                 # greeting
            self.qmp("qmp_capabilities")

    def qmp(self, execute, **arguments):
        self.qmp_file.write(json.dumps({"execute": execute, "arguments": arguments}) + "\n")
        self.qmp_file.flush()
        while True:
            reply = json.loads(self.qmp_file.readline())
            if "return" in reply:
                return reply["return"]
            if "error" in reply:
                raise RuntimeError(reply["error"])

    def pump(self, timeout=0.05):
        r, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if r:
            data = os.read(self.proc.stdout.fileno(), 65536)
            self.out += data

    def wait_for(self, token, timeout=20):
        """Wait until the serial output contains token (bytes); return what came before it."""
        end = time.time() + timeout
        while time.time() < end:
            self.pump()
            i = self.out.find(token)
            if i >= 0:
                before, self.out = self.out[:i], self.out[i + len(token):]
                return before
            if self.proc.poll() is not None:
                break
        raise TimeoutError("no %r in the serial output %r" % (token, self.out))

    def send(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def wait_exit(self, timeout=20):
        try:
            rc = self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return None
        self.pump(0)
        return rc

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass


def build(src, name):
    """Assemble a tests/machine/*.S with the core repo's test env."""
    elf = os.path.join(OUT, name + ".elf")
    tests = os.path.join(CORE, "tests", "isa")
    macros = os.environ.get("RISCV_TESTS", os.path.join(tests, "riscv-tests")) + "/isa/macros/scalar"
    subprocess.run([CROSS + "gcc", "-march=rv32imc_zicsr_zifencei", "-mabi=ilp32", "-static",
                    "-mcmodel=medany", "-nostdlib", "-nostartfiles",
                    "-I", os.path.join(tests, "env"), "-I", macros,
                    "-T", os.path.join(tests, "env", "link.ld"), src, "-o", elf], check=True)
    return elf


def test_timer():
    q = Qemu(["-kernel", build(os.path.join(HERE, "machine", "timer.S"), "timer")])
    try:
        rc = q.wait_exit(60)
    finally:
        q.close()
    assert rc == 0, "exit status %r (a test case number, or None for a timeout)" % rc


def test_uart():
    q = Qemu(["-kernel", build(os.path.join(HERE, "machine", "uart.S"), "uart")])
    try:
        q.wait_for(b"ut>")
        q.send(b"a")
        q.wait_for(b">")
        q.send(b"b")
        q.wait_for(b">")
        q.send(b"cde")
        q.wait_for(b"ok")
        rc = q.wait_exit()
    finally:
        q.close()
    assert rc == 0, "exit status %r" % rc


def test_gpio():
    q = Qemu(["-kernel", build(os.path.join(HERE, "machine", "gpio.S"), "gpio")])
    path = "/machine/gpio"
    try:
        q.wait_for(b">")
        # a rising edge on pin 1, whose interrupt is not enabled: no interrupt
        q.qmp("qom-set", path=path, property="gpio-in", value=2)
        time.sleep(0.2)
        assert b"a" not in q.out, "an interrupt for a pin that is not enabled"
        q.qmp("qom-set", path=path, property="gpio-in", value=3)       # pin 0 rises
        q.wait_for(b"a")
        q.qmp("qom-set", path=path, property="gpio-in", value=2)       # pin 0 falls: nothing
        q.qmp("qom-set", path=path, property="gpio-in", value=3)       # and rises again
        q.wait_for(b"b")
        out = q.qmp("qom-get", path=path, property="gpio-out")
        assert out == 0x3c, "gpio-out is %#x, expected 0x3c" % out
        rc = q.wait_exit()
    finally:
        q.close()
    assert rc == 0, "exit status %r" % rc


def test_firmware():
    # Regenerate the hex file from the generator in a scratch directory (the
    # core repo is not written to), and check that it is the committed one
    tmp = tempfile.mkdtemp()
    shutil.copy(os.path.join(CORE, "firmware", "gen_firmware.py"), tmp)
    subprocess.run([sys.executable, os.path.join(tmp, "gen_firmware.py")],
                   check=True, stdout=subprocess.DEVNULL)
    words = [int(w, 16) for w in open(os.path.join(tmp, "firmware.hex")).read().split()]
    committed = [int(w, 16) for w in open(os.path.join(CORE, "firmware", "firmware.hex")).read().split()]
    assert words == committed, "firmware.hex in the core repo is not what gen_firmware.py makes"
    binfile = os.path.join(OUT, "firmware.bin")
    with open(binfile, "wb") as f:
        for w in words:
            f.write(w.to_bytes(4, "little"))
    q = Qemu(["-device", "loader,file=%s,addr=0x0" % binfile])
    try:
        # The program sends 'H' and ends with ECALL, mtvec = 0: it restarts.
        # Wait for three passes
        q.wait_for(b"HHH")
        q.qmp("stop")
        regs = q.qmp("human-monitor-command", **{"command-line": "info registers"})
        gpio = q.qmp("qom-get", path="/machine/gpio", property="gpio-out")
    finally:
        q.close()
    got = {int(m.group(1)): int(m.group(2), 16)
           for m in re.finditer(r"\bx(\d+)/\w+\s+([0-9a-f]{8})\b", regs)}
    want = {1: 42, 2: 10, 3: 52, 4: 32, 5: 52, 6: 0x55, 7: 0xaa, 8: 160, 9: 40, 10: 0x4000,
            11: 52, 12: 0x55, 18: 1, 19: 1, 24: 52, 25: 53, 26: 0}
    for r, v in want.items():
        assert got.get(r) == v, "x%d is %s, expected %#x\n%s" % (r, got.get(r), v, regs)
    assert gpio == 52, "gpio-out is %#x, expected 0x34 (52)" % gpio    # data_out 52 & dir 0xff
    m = re.search(r"mcause\s+([0-9a-f]+)", regs)
    assert m and int(m.group(1), 16) == 11, "mcause is not 11 (ECALL from M-mode)\n" + regs
    m = re.search(r"mepc\s+([0-9a-f]+)", regs)
    assert m and int(m.group(1), 16) == 0xb4, "mepc is not 0xb4 (the ECALL)\n" + regs


TESTS = {"firmware": test_firmware, "timer": test_timer, "uart": test_uart, "gpio": test_gpio}


def main():
    names = sys.argv[1:] or list(TESTS)
    fails = 0
    with open(os.path.join(OUT, "results.txt"), "w") as res:
        for n in names:
            try:
                TESTS[n]()
                line = "machine/%-10s PASS" % n
            except Exception as e:                    # noqa: BLE001 - report any failure
                fails += 1
                line = "machine/%-10s FAIL %s" % (n, str(e).splitlines()[0] if str(e) else type(e).__name__)
            print(line)
            res.write(line + "\n")
        total = "%d / %d passed" % (len(names) - fails, len(names))
        print(total)
        res.write(total + "\n")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
