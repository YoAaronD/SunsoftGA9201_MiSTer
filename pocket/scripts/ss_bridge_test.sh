#!/usr/bin/env bash
# Unit test of the save-state bridge (pocket/sim/ss_bridge_tb.cpp); takes ~10 s.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="${SIM_OBJ:-$ROOT/sim/obj_ss_bridge}"
verilator --cc --exe --build -O1 -Wno-fatal -Wno-WIDTH --top-module pocket_ss_bridge \
    "$ROOT/pocket/rtl/pocket_ss_bridge.sv" "$ROOT/pocket/rtl/pocket_afifo.sv" \
    "$ROOT/pocket/sim/ss_bridge_tb.cpp" --Mdir "$OBJ" > "$OBJ.build.log" 2>&1 || { tail -20 "$OBJ.build.log"; exit 1; }
"$OBJ/Vpocket_ss_bridge"
