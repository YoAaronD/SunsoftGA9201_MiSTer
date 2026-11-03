#!/usr/bin/env python3
"""Make the Analogue Pocket .rom files from MAME ROM zips.

    python3 pocket/scripts/make_roms.py ROMDIR OUTDIR

ROMDIR holds shangha3j.zip (plus shangha3.zip if your set is split),
heberpop.zip and blocken.zip (MAME 0.289 sets). For every game whose ROMs are
found, OUTDIR gets <set>.rom: exactly the byte stream the MiSTer MRA sends
(releases/*.mra), which the Pocket core loads from Assets/ga9201/common/.
Every ROM part is CRC-checked. The .rom files hold ROM data: never share them.
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GAMES = [("Shanghai III (Japan).mra", "shangha3j"),
         ("Hebereke no Popoon (Japan).mra", "heberpop"),
         ("Blocken (Japan).mra", "blocken")]

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(1)
    romdir, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    made = 0
    for mra, setname in GAMES:
        out = os.path.join(outdir, setname + ".rom")
        r = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "mra_stream.py"),
                            os.path.join(ROOT, "releases", mra), romdir, out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"{setname}: skipped ({(r.stderr or r.stdout).strip().splitlines()[-1]})")
            continue
        if "BAD" in r.stdout or "mismatch" in r.stdout.lower():
            print(r.stdout); print(f"{setname}: CRC problem, check your ROM set"); continue
        print(f"{setname}: wrote {out} ({os.path.getsize(out)} bytes)")
        made += 1
    sys.exit(0 if made else 1)

if __name__ == "__main__":
    main()
