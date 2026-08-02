"""Scan kernel ELFs for stack-frame budget violations. Companion to
stackframes.sh, which owns the policy story.

Usage: stackframes.py <budget-bytes> <debt-file> <elf> [elf ...]

A frame's reservation is its largest `sub $N, %rsp`. Names are normalized
(anonymous-type serials and generic-instantiation arguments vary between
builds) so the debt list survives recompilation.

Debt file format: `<normalized-name> <ceiling-bytes>` per line, `#` comments.
Exit is nonzero on: a violator not on the list, a listed violator over its
ceiling, or a stale entry that violates in NO scanned image (fixed — delete
its line).
"""

import re
import subprocess
import sys

budget, debt_path = int(sys.argv[1]), sys.argv[2]
elfs = sys.argv[3:]


def normalize(name: str) -> str:
    name = re.sub(r"__anon_\d+", "__anon", name)
    return re.sub(r"\(.*\)", "(...)", name)


debt: dict[str, int] = {}
with open(debt_path) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, ceiling = line.rsplit(None, 1)
        debt[name] = int(ceiling)

failed = False
seen_violators: set[str] = set()
for elf in elfs:
    frames: dict[str, int] = {}
    fn = ""
    out = subprocess.run(["objdump", "-d", elf], capture_output=True, text=True, check=True)
    for line in out.stdout.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:", line)
        if m:
            fn = normalize(m.group(1))
            continue
        m = re.search(r"sub +\$(0x[0-9a-f]+),%rsp", line)
        if m:
            n = int(m.group(1), 16)
            if n > frames.get(fn, 0):
                frames[fn] = n

    for name, n in sorted(frames.items(), key=lambda kv: -kv[1]):
        if n <= budget:
            break
        seen_violators.add(name)
        ceiling = debt.get(name)
        if ceiling is None:
            print(f"  ✗ {elf}: NEW over-budget frame {n} > {budget} bytes: {name}")
            failed = True
        elif n > ceiling:
            print(f"  ✗ {elf}: debt-listed frame GREW to {n} > ceiling {ceiling}: {name}")
            failed = True

for name in sorted(set(debt) - seen_violators):
    print(f"  ✗ stale debt entry (over budget in no image) — delete it: {name}")
    failed = True

sys.exit(1 if failed else 0)
