import os
import sys
import time
import signal
import subprocess
import tempfile
import shutil

test_script = """import os, sys, time, signal, asyncio
sys.path.insert(0, '/mnt/c/Users/Abdul Qhahhar/Documents/trading scalping bot/paper_mm2')
sys.path.insert(0, '/mnt/c/Users/Abdul Qhahhar/AppData/Roaming/Python/Python314/site-packages')
from bot import PaperMM2Bot

async def fake_ws_1():
    while True:
        await asyncio.sleep(0.1)

async def fake_ws_2():
    while True:
        await asyncio.sleep(0.1)

bot = PaperMM2Bot(sys.argv[1])
bot.run_binance_ws = fake_ws_1
bot.run_hyperliquid_ws = fake_ws_2

def fake_screen():
    print("Universe screened (mocked).")
bot.screen_universe_if_needed = fake_screen

# Pre-buffer quotes to test flush
bot.engine.quotes_buffer.append([1, int(time.time()*1000), 'A', 'binance', 'BTCUSDT', 'PLACE', 'BUY', 60000.0, 0.001, 3.0, 0.5, 0.0, 1.0, 0.0, float('nan')])
bot.engine.quotes_buffer.append([2, int(time.time()*1000), 'B', 'hyperliquid', 'ETH', 'PLACE', 'BUY', 3000.0, 0.01, 2.0, float('nan'), 0.0, 1.0, 0.0, 0.65])

def sigterm_handler(sig, frame):
    print(f"Runner received signal {sig}, shutting down...")
    bot.shutdown()
    sys.exit(0)

signal.signal(signal.SIGTERM, sigterm_handler)
signal.signal(signal.SIGINT, sigterm_handler)

print("Starting bot.run_main()...", flush=True)
try:
    asyncio.run(bot.run_main())
except BaseException as e:
    print(f"run_main exited with {e}")
finally:
    bot.shutdown()
sys.exit(0)
"""

tmp_dir = tempfile.mkdtemp(prefix="wsl_sigterm_test_")
runner_path = os.path.join(tmp_dir, "run_test.py")
with open(runner_path, "w") as f:
    f.write(test_script)

start_t = time.time()
env = dict(os.environ, PYTHONPATH="/mnt/c/Users/Abdul Qhahhar/Documents/trading scalping bot/paper_mm2:/mnt/c/Users/Abdul Qhahhar/AppData/Roaming/Python/Python314/site-packages")
proc = subprocess.Popen(["python3", runner_path, tmp_dir], env=env)
time.sleep(2)
print("Sending SIGTERM to pid:", proc.pid)
proc.send_signal(signal.SIGTERM)
ret = proc.wait(timeout=10)
elapsed = time.time() - start_t
print(f"Process exited in {elapsed:.2f} s with returncode: {ret}")

quotes_dir = os.path.join(tmp_dir, "data", "quotes")
files = os.listdir(quotes_dir) if os.path.exists(quotes_dir) else []
print("Quotes dir files:", files)
shutil.rmtree(tmp_dir, ignore_errors=True)
assert ret == 0, f"Expected exit code 0, got {ret}"
assert len(files) > 0, "Expected flushed quotes.csv.gz file"
print("ASSERT PASS: Linux SIGTERM test passed cleanly with exit 0 and quotes flushed within 10 s!")
