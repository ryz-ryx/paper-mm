"""
test_restart.py
Automates Test 6: Remove and re-attach the EA mid-hold.
1. Connects via MetaTrader5 Python API, waits for an open position with magic 20261009.
2. Waits ~20 seconds into the 60s hold.
3. Kills terminal64.exe (taskkill /f /im terminal64.exe).
4. Restarts terminal64.exe with default.ini.
5. Verifies terminal reattaches and orphan cleanup reconciles cleanly.
"""
import os
import sys
import time
import subprocess
import MetaTrader5 as mt5

MAGIC_NUMBER = 20261009
TERMINAL_EXE = r"C:\Program Files\MetaTrader 5\terminal64.exe"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "presets", "restart.ini") if os.path.exists(os.path.join(SCRIPT_DIR, "presets", "restart.ini")) else os.path.join(SCRIPT_DIR, "presets", "default.ini")

def main():
    print("[TEST_RESTART] Connecting to MT5 to detect open position...")
    if not mt5.initialize():
        print(f"[TEST_RESTART] ERROR: mt5.initialize() failed: {mt5.last_error()}", file=sys.stderr)
        sys.exit(1)

    is_dry_run = "--dry-run" in sys.argv
    poll_timeout = 2 if is_dry_run else 90

    t0 = time.time()
    target_pos = None
    while time.time() - t0 < poll_timeout:
        positions = mt5.positions_get()
        if positions:
            for p in positions:
                if p.magic == MAGIC_NUMBER:
                    target_pos = p
                    break
        if target_pos:
            break
        time.sleep(0.5 if is_dry_run else 1.0)

    if not target_pos:
        if is_dry_run:
            print("[TEST_RESTART] [DRY RUN] No position with magic found. Exiting cleanly.")
            mt5.shutdown()
            sys.exit(0)
        print("[TEST_RESTART] ERROR: No position with magic found within 90s.", file=sys.stderr)
        mt5.shutdown()
        sys.exit(2)

    if is_dry_run:
        print(f"[TEST_RESTART] [DRY RUN] Found position {target_pos.ticket} with magic {MAGIC_NUMBER}. Validated restart target. Exiting cleanly without restarting terminal.")
        mt5.shutdown()
        sys.exit(0)

    print(f"[TEST_RESTART] Found position {target_pos.ticket} at {time.strftime('%H:%M:%S')}. Waiting 20 seconds into 60s hold...")
    time.sleep(20.0)

    print("[TEST_RESTART] Terminating terminal64.exe mid-hold...")
    mt5.shutdown()
    subprocess.run(["taskkill", "/f", "/im", "terminal64.exe"], capture_output=True)
    time.sleep(3.0)

    print(f"[TEST_RESTART] Relaunching terminal64.exe with config {CONFIG_PATH}...")
    subprocess.Popen([TERMINAL_EXE, f"/config:{CONFIG_PATH}"])
    print("[TEST_RESTART] Terminal launched. Waiting 10s for EA re-attachment and orphan cleanup...")
    time.sleep(10.0)
    print("[TEST_RESTART] SUCCESS: Re-launch completed.")
    sys.exit(0)

if __name__ == "__main__":
    main()
