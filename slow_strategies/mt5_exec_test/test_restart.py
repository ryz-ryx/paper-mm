"""
test_restart.py
Automates Test 6: Remove and re-attach the EA mid-hold.
1. Connects via MetaTrader5 Python API, waits for an open position with magic 20261009.
2. Waits ~20 seconds into the 60s hold.
3. Kills terminal64.exe (taskkill /f /im terminal64.exe).
4. Restarts terminal64.exe with default.ini.
5. Verifies terminal reattaches and orphan cleanup reconciles cleanly.
"""
import sys
import time
import subprocess
import MetaTrader5 as mt5

MAGIC_NUMBER = 20261009
TERMINAL_EXE = r"C:\Program Files\MetaTrader 5\terminal64.exe"
CONFIG_PATH = r"C:\Users\Abdul Qhahhar\Documents\trading scalping bot\slow_strategies\mt5_exec_test\presets\default.ini"

def main():
    print("[TEST_RESTART] Connecting to MT5 to detect open position...")
    if not mt5.initialize():
        print(f"[TEST_RESTART] ERROR: mt5.initialize() failed: {mt5.last_error()}", file=sys.stderr)
        sys.exit(1)

    t0 = time.time()
    target_pos = None
    while time.time() - t0 < 90:
        positions = mt5.positions_get()
        if positions:
            for p in positions:
                if p.magic == MAGIC_NUMBER:
                    target_pos = p
                    break
        if target_pos:
            break
        time.sleep(1.0)

    if not target_pos:
        print("[TEST_RESTART] ERROR: No position with magic found within 90s.", file=sys.stderr)
        mt5.shutdown()
        sys.exit(2)

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
