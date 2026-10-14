"""
external_close.py
Simulates an external manual / third-party close of the probe position.
Connects via MetaTrader5 Python API, finds the position matching the EA's
magic number (default: 20261009), and executes an immediate market close.
"""
import sys
import time
import MetaTrader5 as mt5

MAGIC_NUMBER = 20261009
# ExecTest retries 120 s after every entry skip (ExecTest.mq5:2499). On ICMarketsEU-Demo only ~20% of attempts
# pass the zero_spread / stale_tick gates (ExecTest.mq5:1502-1511), so budget ~10 attempts: 5 s + 10 x 120 s + margin.
TIMEOUT_SEC = 1300

def main():
    print(f"[EXTERNAL_CLOSE] Initializing MT5 connection...")
    if not mt5.initialize():
        print(f"[EXTERNAL_CLOSE] ERROR: mt5.initialize() failed: {mt5.last_error()}", file=sys.stderr)
        sys.exit(1)

    is_dry_run = "--dry-run" in sys.argv
    poll_timeout = 2 if is_dry_run else TIMEOUT_SEC

    print(f"[EXTERNAL_CLOSE] Polling for position with magic {MAGIC_NUMBER} (up to {poll_timeout}s)...")
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
            print(f"[EXTERNAL_CLOSE] [DRY RUN] No position with magic {MAGIC_NUMBER} found (as expected). Exiting cleanly.")
            mt5.shutdown()
            sys.exit(0)
        print(f"[EXTERNAL_CLOSE] ERROR: No position with magic {MAGIC_NUMBER} found within {TIMEOUT_SEC}s.", file=sys.stderr)
        mt5.shutdown()
        sys.exit(2)

    ticket = target_pos.ticket
    symbol = target_pos.symbol
    vol = target_pos.volume
    pos_type = target_pos.type # 0 = BUY, 1 = SELL

    print(f"[EXTERNAL_CLOSE] Found open position: Ticket {ticket}, Symbol {symbol}, Type {pos_type}, Vol {vol}")

    # Prepare close order
    tick = mt5.symbol_info_tick(symbol)
    if not tick:
        print(f"[EXTERNAL_CLOSE] ERROR: Cannot fetch tick for {symbol}", file=sys.stderr)
        mt5.shutdown()
        sys.exit(3)

    close_type = mt5.ORDER_TYPE_SELL if pos_type == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_BUY
    price = tick.bid if close_type == mt5.ORDER_TYPE_SELL else tick.ask

    # Determine valid filling mode per symbol
    sym_info = mt5.symbol_info(symbol)
    f_mode = getattr(sym_info, 'filling_mode', 0) if sym_info else 0
    if f_mode & 1:
        filling_type = mt5.ORDER_FILLING_FOK
    elif f_mode & 2:
        filling_type = mt5.ORDER_FILLING_IOC
    else:
        filling_type = mt5.ORDER_FILLING_RETURN

    req = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": vol,
        "type": close_type,
        "position": ticket,
        "price": price,
        "deviation": 20,
        "magic": 99999999, # distinct magic indicating external manual intervention
        "comment": "smoke2_external_close",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": filling_type
    }

    if is_dry_run:
        check_res = mt5.order_check(req)
        print(f"[EXTERNAL_CLOSE] [DRY RUN] order_check retcode: {check_res.retcode if check_res else 'None'}, comment: {check_res.comment if check_res else ''}")
        print(f"[EXTERNAL_CLOSE] [DRY RUN] Position {ticket} validated for external close. Exiting cleanly without executing.")
        mt5.shutdown()
        sys.exit(0)

    res = mt5.order_send(req)
    if res.retcode == mt5.TRADE_RETCODE_DONE:
        print(f"[EXTERNAL_CLOSE] SUCCESS: Position {ticket} closed externally. Deal ticket: {res.deal}, Price: {res.price}")
        mt5.shutdown()
        sys.exit(0)
    else:
        print(f"[EXTERNAL_CLOSE] ERROR: Close order rejected: retcode={res.retcode}, comment={res.comment}", file=sys.stderr)
        mt5.shutdown()
        sys.exit(4)

if __name__ == "__main__":
    main()
