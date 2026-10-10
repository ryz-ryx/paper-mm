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
TIMEOUT_SEC = 90

def main():
    print(f"[EXTERNAL_CLOSE] Initializing MT5 connection...")
    if not mt5.initialize():
        print(f"[EXTERNAL_CLOSE] ERROR: mt5.initialize() failed: {mt5.last_error()}", file=sys.stderr)
        sys.exit(1)

    print(f"[EXTERNAL_CLOSE] Polling for position with magic {MAGIC_NUMBER} (up to {TIMEOUT_SEC}s)...")
    t0 = time.time()
    target_pos = None

    while time.time() - t0 < TIMEOUT_SEC:
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
        "type_filling": mt5.ORDER_FILLING_FOK
    }

    res = mt5.order_send(req)
    if res.retcode != mt5.TRADE_RETCODE_DONE:
        # Fallback to IOC if FOK rejected
        req["type_filling"] = mt5.ORDER_FILLING_IOC
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
