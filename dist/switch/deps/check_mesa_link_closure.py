#!/usr/bin/env python3
"""Report Mesa SDK symbols that no available Switch library defines.

Collects undefined symbols from the Mesa archives Cemu links and subtracts every
symbol defined by portlibs, libnx and the devkitA64 runtime. Whatever remains is
a genuinely missing dependency (for example libelf's elf_* API).
"""
import glob, os, subprocess, sys

dkp = os.environ.get("DEVKITPRO", "/opt/devkitpro")
sdk = sys.argv[1] if len(sys.argv) > 1 else f"{dkp}/portlibs/switch"
nm = f"{dkp}/devkitA64/bin/aarch64-none-elf-nm"
mesa = ["libvulkan.a", "libEGL.a", "libGL.a", "libGLESv2.a", "libglapi.a",
        "libnouveau_horizon.a", "libmesa_util.a", "libxmlconfig.a"]

def syms(path):
    out = subprocess.run([nm, "-g", path], capture_output=True, text=True).stdout
    d, u = set(), set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in ("U", "w", "v"):
            (u if parts[0] == "U" else d).add(parts[1])
        elif len(parts) == 3:
            d.add(parts[2])
    return d, u

providers = set(glob.glob(f"{sdk}/lib/*.a")) | set(glob.glob(f"{dkp}/portlibs/switch/lib/*.a"))
providers |= {f"{dkp}/libnx/lib/libnx.a"}
providers |= set(glob.glob(f"{dkp}/devkitA64/aarch64-none-elf/lib/pic/*.a"))
providers |= set(glob.glob(f"{dkp}/devkitA64/aarch64-none-elf/lib/*.a"))
providers |= set(glob.glob(f"{dkp}/devkitA64/lib/gcc/aarch64-none-elf/*/pic/*.a"))
providers |= set(glob.glob(f"{dkp}/devkitA64/lib/gcc/aarch64-none-elf/*/*.a"))

defined, where = set(), {}
for p in sorted(providers):
    d, _ = syms(p)
    defined |= d
    for s in d:
        where.setdefault(s, os.path.basename(p))

missing = {}
for name in mesa:
    path = f"{sdk}/lib/{name}"
    if not os.path.exists(path):
        print(f"(absent) {name}")
        continue
    _, u = syms(path)
    m = sorted(u - defined)
    missing[name] = m
    print(f"== {name}: {len(u)} undefined, {len(m)} unresolved")
    for s in m:
        print("   ", s)

for probe in ("elf_begin", "elf_version", "gelf_getshdr", "nouveau_bo_new",
              "nouveau_pushbuf_kick", "nouveau_device_new", "XML_ParserCreate"):
    print(f"provider[{probe}] = {where.get(probe, '-')}")
sys.exit(1 if any(missing.values()) else 0)
