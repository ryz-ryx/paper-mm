//+------------------------------------------------------------------+
//|                                                     ExecTest.mq5 |
//|                                  MT5 Execution Quality Benchmark |
//|                                                                  |
//| Port of slow_strategies/mt5_exec_test/exec_test.py to native MQL5|
//+------------------------------------------------------------------+
#property copyright "Execution Quality Benchmark"
#property link      ""
#property version   "1.01"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Input Parameters
input group "=== Strategy Parameters ==="
input double   InpVolume            = 0.01;      // Trade Volume (lots)
input ulong    InpDeviation         = 20;        // Slippage Deviation Points
input int      InpHoldSeconds       = 60;        // Hold duration per round-trip
input int      InpCycleIntervalMin  = 36;        // Cycle interval (minutes) between trades
input int      InpMaxOrdersPerDay   = 40;        // Maximum orders per day limit
input double   InpMaxDrawdownEUR    = 50.0;      // Equity drawdown stop (EUR)
input ulong    InpMagicNumber       = 20261009;  // Magic number
input int      InpPollIntervalMs    = 15;        // Polling interval in ms (10-20 ms)

//--- Global Variables Persistence Keys
#define GV_BASELINE_EQUITY    "EXECTEST_BASELINE_EQUITY"
#define GV_CIRCUIT_BREAKER    "EXECTEST_CIRCUIT_BREAKER"
#define GV_CONSEC_ERRORS      "EXECTEST_CONSEC_ERRORS"
#define GV_DAILY_ORDER_COUNT  "EXECTEST_DAILY_ORDER_COUNT"
#define GV_DAILY_DATE_UTC     "EXECTEST_DAILY_DATE_UTC"

//--- Global State
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbols[2];

string         g_activeSymbols[2] = {"EURUSD", "USDJPY"};
int            g_symbolIndex = 0;

double         g_initialEquity = 0.0;
int            g_consecutiveErrors = 0;
int            g_dailyOrderCount = 0;
datetime       g_currentDayUtc = 0;
bool           g_circuitBreakerTripped = false;

// Per-symbol tick tracking using local tick count
struct SymbolTickTracker
{
   long        last_tick_msc;
   ulong       local_first_seen_ms;
   MqlTick     last_tick;
};

SymbolTickTracker g_trackers[2];

// State Machine
enum ETestState
{
   STATE_CLEANUP_ORPHAN,
   STATE_IDLE,
   STATE_HOLDING,
   STATE_WAIT_EXIT_GATE,
   STATE_CYCLE_SLEEP,
   STATE_ABORTED
};

ETestState     g_state = STATE_IDLE;
string         g_currentSymbol = "";
ulong          g_currentPositionTicket = 0;
ulong          g_positionOpenLocalMs = 0;

// Cached entry metrics for round trip logging
MqlTick        g_entrySnapshotTick;
double         g_entryReqPrice = 0.0;
double         g_entryFillPrice = 0.0;
double         g_entryLatencyMs = 0.0;
double         g_entryMidAtFill = 0.0;
double         g_entryExecSlipPts = 0.0;
double         g_entryDriftPts = 0.0;
double         g_entrySpreadPts = 0.0;
double         g_entryMid = 0.0;
double         g_entrySnapAgeMs = 0.0;
string         g_entrySession = "";

// Exit gate variables
ulong          g_exitGateStartLocalMs = 0;
double         g_exitGateWaitedMs = 0.0;
bool           g_exitZeroSpread = false;

ulong          g_nextCycleLocalMs = 0;

// CSV Filenames in Common\Files
#define FILE_TRADES     "trades.csv"
#define FILE_ROUNDTRIPS "roundtrips.csv"
#define FILE_SKIPS      "skips.csv"

//+------------------------------------------------------------------+
//| Helper: Format current UTC time string                           |
//+------------------------------------------------------------------+
string FormatUtcTime(datetime dt, uint ms = 0)
{
   MqlDateTime mdt;
   TimeToStruct(dt, mdt);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02d.%03u",
                       mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min, mdt.sec, ms);
}

//+------------------------------------------------------------------+
//| Helper: Check if FX market is closed (Weekend Fri 21:00-Sun 21:00)|
//+------------------------------------------------------------------+
bool IsMarketClosed(datetime utc_dt)
{
   MqlDateTime mdt;
   TimeToStruct(utc_dt, mdt);
   int wd = mdt.day_of_week; // 0=Sun, 1=Mon, ..., 5=Fri, 6=Sat
   int h = mdt.hour;

   if(wd == 6) return true;                      // Saturday
   if(wd == 5 && h >= 21) return true;           // Friday post-close
   if(wd == 0 && h < 21) return true;            // Sunday pre-open
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Get current session string                               |
//+------------------------------------------------------------------+
string GetCurrentSession(datetime utc_dt)
{
   if(IsMarketClosed(utc_dt))
      return "Market closed";

   MqlDateTime mdt;
   TimeToStruct(utc_dt, mdt);
   int h = mdt.hour;

   if(h >= 0 && h < 8)
      return "Asia";
   else if(h >= 8 && h < 13)
      return "London";
   else if(h >= 13 && h < 21)
      return "New York";
   else
      return "Off-Peak";
}

//+------------------------------------------------------------------+
//| Helper: Convert profit currency to EUR                           |
//+------------------------------------------------------------------+
double GetFxToEur(string symbol)
{
   string profitCurr = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   if(profitCurr == "EUR") return 1.0;

   MqlTick tickEURUSD;
   double eurusd = 1.1195;
   if(SymbolInfoTick("EURUSD", tickEURUSD) && tickEURUSD.bid > 0)
      eurusd = tickEURUSD.bid;

   if(profitCurr == "USD")
   {
      return (eurusd > 0) ? (1.0 / eurusd) : 1.0;
   }
   else if(profitCurr == "JPY")
   {
      MqlTick tickUSDJPY;
      double usdjpy = 158.20;
      if(SymbolInfoTick("USDJPY", tickUSDJPY) && tickUSDJPY.bid > 0)
         usdjpy = tickUSDJPY.bid;

      double eurjpy = eurusd * usdjpy;
      return (eurjpy > 0) ? (1.0 / eurjpy) : 0.0056;
   }
   return 1.0;
}

//+------------------------------------------------------------------+
//| Helper: Update Symbol Tick Tracker                               |
//+------------------------------------------------------------------+
void UpdateSymbolTick(int idx)
{
   string sym = g_activeSymbols[idx];
   MqlTick currentTick;
   if(SymbolInfoTick(sym, currentTick))
   {
      if((long)currentTick.time_msc != g_trackers[idx].last_tick_msc)
      {
         g_trackers[idx].last_tick_msc = (long)currentTick.time_msc;
         g_trackers[idx].local_first_seen_ms = GetTickCount64();
      }
      g_trackers[idx].last_tick = currentTick;
   }
}

//+------------------------------------------------------------------+
//| Helper: Get Tick Age in ms for symbol                            |
//+------------------------------------------------------------------+
double GetTickAgeMs(int idx)
{
   if(g_trackers[idx].local_first_seen_ms == 0)
      return 999999.0;
   ulong now = GetTickCount64();
   return (double)(now - g_trackers[idx].local_first_seen_ms);
}

//+------------------------------------------------------------------+
//| Persistence: Load state from GlobalVariables                     |
//+------------------------------------------------------------------+
void LoadPersistentState()
{
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);

   // 1. Equity baseline
   if(GlobalVariableCheck(GV_BASELINE_EQUITY))
   {
      g_initialEquity = GlobalVariableGet(GV_BASELINE_EQUITY);
      PrintFormat("[PERSISTENCE] Loaded equity baseline: %.2f EUR", g_initialEquity);
   }
   else
   {
      g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GV_BASELINE_EQUITY, g_initialEquity);
      PrintFormat("[PERSISTENCE] Initialized equity baseline: %.2f EUR", g_initialEquity);
   }

   // 2. Circuit breaker
   if(GlobalVariableCheck(GV_CIRCUIT_BREAKER))
   {
      g_circuitBreakerTripped = (GlobalVariableGet(GV_CIRCUIT_BREAKER) > 0.5);
      if(g_circuitBreakerTripped)
         Print("[PERSISTENCE] WARNING: Circuit breaker is currently TRIPPED");
   }
   else
   {
      g_circuitBreakerTripped = false;
      GlobalVariableSet(GV_CIRCUIT_BREAKER, 0.0);
   }

   // 3. Consecutive errors
   if(GlobalVariableCheck(GV_CONSEC_ERRORS))
   {
      g_consecutiveErrors = (int)GlobalVariableGet(GV_CONSEC_ERRORS);
      PrintFormat("[PERSISTENCE] Loaded consecutive errors: %d", g_consecutiveErrors);
   }
   else
   {
      g_consecutiveErrors = 0;
      GlobalVariableSet(GV_CONSEC_ERRORS, 0.0);
   }

   // 4. Daily order count
   datetime savedDay = 0;
   if(GlobalVariableCheck(GV_DAILY_DATE_UTC))
      savedDay = (datetime)GlobalVariableGet(GV_DAILY_DATE_UTC);

   if(savedDay == todayStart && GlobalVariableCheck(GV_DAILY_ORDER_COUNT))
   {
      g_currentDayUtc = todayStart;
      g_dailyOrderCount = (int)GlobalVariableGet(GV_DAILY_ORDER_COUNT);
      PrintFormat("[PERSISTENCE] Loaded daily orders for today: %d", g_dailyOrderCount);
   }
   else
   {
      g_currentDayUtc = todayStart;
      g_dailyOrderCount = 0;
      GlobalVariableSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
      GlobalVariableSet(GV_DAILY_ORDER_COUNT, 0.0);
      Print("[PERSISTENCE] Initialized new daily order count for today: 0");
   }
}

//+------------------------------------------------------------------+
//| Persistence: Save state to GlobalVariables                       |
//+------------------------------------------------------------------+
void SavePersistentState()
{
   GlobalVariableSet(GV_BASELINE_EQUITY, g_initialEquity);
   GlobalVariableSet(GV_CIRCUIT_BREAKER, g_circuitBreakerTripped ? 1.0 : 0.0);
   GlobalVariableSet(GV_CONSEC_ERRORS, (double)g_consecutiveErrors);
   GlobalVariableSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
   GlobalVariableSet(GV_DAILY_ORDER_COUNT, (double)g_dailyOrderCount);
}

//+------------------------------------------------------------------+
//| Initialize CSV files in FILE_COMMON                              |
//+------------------------------------------------------------------+
void InitCsvFiles()
{
   // 1. trades.csv
   if(!FileIsExist(FILE_TRADES, FILE_COMMON))
   {
      int h = FileOpen(FILE_TRADES, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,side,volume,request_price,fill_price,bid_before,ask_before,spread_before,retcode,latency_ms,deviation,comment,tick_time_msc,tick_age_ms,poll_interval_ms,engine\r\n");
         FileClose(h);
      }
   }

   // 2. roundtrips.csv
   if(!FileIsExist(FILE_ROUNDTRIPS, FILE_COMMON))
   {
      int h = FileOpen(FILE_ROUNDTRIPS, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,volume,entry_request_price,entry_fill_price,exit_request_price,exit_fill_price,snapshot_age_ms,entry_slippage_pts,exit_slippage_pts,mid_at_fill,exit_mid_at_fill,entry_slippage_mid_fill_pts,exit_slippage_mid_fill_pts,spread_at_entry_pts,exit_spread_pts,mid_entry,mid_exit,mid_move_during_hold_pts,fill_to_fill_cost_eur,fill_to_fill_cost_bps,mid_adjusted_cost_eur,mid_adjusted_cost_bps,model_cost_eur,cost_ratio,model_cost_1sp_eur,cost_ratio_1sp,raw_pnl_eur,hold_seconds,pre_filter,exit_gate_waited_ms,exit_zero_spread,entry_exec_slip_pts,exit_exec_slip_pts,entry_drift_pts,exit_drift_pts,t_tick_server,t_send_local_corrected,send_gap_ms,age_uncorrected,engine\r\n");
         FileClose(h);
      }
   }

   // 3. skips.csv
   if(!FileIsExist(FILE_SKIPS, FILE_COMMON))
   {
      int h = FileOpen(FILE_SKIPS, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,reason,details,engine\r\n");
         FileClose(h);
      }
   }
}

//+------------------------------------------------------------------+
//| Logging: Skip                                                    |
//+------------------------------------------------------------------+
void LogSkip(string symbol, string reason, string details)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);

   int h = FileOpen(FILE_SKIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      string line = StringFormat("%s,%s,%s,%s,%s,mql5\r\n", tsStr, session, symbol, reason, details);
      FileWriteString(h, line);
      FileClose(h);
   }
   PrintFormat("[SKIP LOGGED] %s | %s | Reason: %s | %s", symbol, session, reason, details);
}

//+------------------------------------------------------------------+
//| Logging: Individual Trade                                        |
//+------------------------------------------------------------------+
void LogTrade(string symbol, string side, double volume, double req_price,
              double fill_price, double bid_b, double ask_b, double spread_b,
              uint retcode, double latency_ms, ulong deviation, string comment,
              long tick_time_msc, double tick_age_ms, int poll_interval_ms)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);

   int h = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      string line = StringFormat("%s,%s,%s,%s,%.2f,%f,%f,%f,%f,%f,%u,%.1f,%I64u,%s,%I64d,%.1f,%d,mql5\r\n",
                                 tsStr, session, symbol, side, volume, req_price, fill_price,
                                 bid_b, ask_b, spread_b, retcode, latency_ms, deviation, comment,
                                 tick_time_msc, tick_age_ms, poll_interval_ms);
      FileWriteString(h, line);
      FileClose(h);
   }
   g_dailyOrderCount++;
   SavePersistentState();
}

//+------------------------------------------------------------------+
//| Logging: Completed Round Trip                                    |
//+------------------------------------------------------------------+
void LogRoundtrip(string symbol, double volume, double req_buy, double fill_buy,
                  double req_sell, double fill_sell, double snapshot_age_ms,
                  double slip_buy_send_pts, double slip_sell_send_pts,
                  double mid_at_fill, double exit_mid_at_fill,
                  double slip_buy_mid_fill_pts, double slip_sell_mid_fill_pts,
                  double spread_entry_pts, double spread_sell_pts,
                  double mid_entry, double mid_exit, double mid_move_pts,
                  double f2f_cost_eur, double f2f_cost_bps,
                  double midadj_cost_eur, double midadj_cost_bps,
                  double model_cost_eur, string cost_ratio_str,
                  double model_cost_1sp_eur, string cost_ratio_1sp_str,
                  double raw_pnl_eur, double hold_sec, bool pre_filter,
                  double exit_gate_waited_ms, bool exit_zero_spread,
                  double entry_exec_slip_pts, double exit_exec_slip_pts,
                  double entry_drift_pts, double exit_drift_pts,
                  double t_tick_server, double t_send_local_corrected,
                  double send_gap_ms, bool age_uncorrected)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);

   int h = FileOpen(FILE_ROUNDTRIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      string line = StringFormat("%s,%s,%s,%.2f,%f,%f,%f,%f,%.1f,%.2f,%.2f,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.5f,%.5f,%.2f,%.4f,%.2f,%.4f,%.2f,%.4f,%s,%.4f,%s,%.4f,%.1f,%s,%.1f,%s,%.2f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%s,mql5\r\n",
                                 tsStr, session, symbol, volume, req_buy, fill_buy, req_sell, fill_sell,
                                 snapshot_age_ms, slip_buy_send_pts, slip_sell_send_pts,
                                 mid_at_fill, exit_mid_at_fill, slip_buy_mid_fill_pts, slip_sell_mid_fill_pts,
                                 spread_entry_pts, spread_sell_pts, mid_entry, mid_exit, mid_move_pts,
                                 f2f_cost_eur, f2f_cost_bps, midadj_cost_eur, midadj_cost_bps,
                                 model_cost_eur, cost_ratio_str, model_cost_1sp_eur, cost_ratio_1sp_str,
                                 raw_pnl_eur, hold_sec, (pre_filter ? "True" : "False"),
                                 exit_gate_waited_ms, (exit_zero_spread ? "True" : "False"),
                                 entry_exec_slip_pts, exit_exec_slip_pts, entry_drift_pts, exit_drift_pts,
                                 t_tick_server, t_send_local_corrected, send_gap_ms,
                                 (age_uncorrected ? "True" : "False"));
      FileWriteString(h, line);
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Check Hard Safety Limits                                         |
//+------------------------------------------------------------------+
bool CheckSafetyLimits(string &reason)
{
   // 1. Terminal connection
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      reason = "Terminal disconnected from broker server";
      return false;
   }

   // 2. Demo account verification
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      reason = "Account is NOT DEMO (Aborting immediately)";
      return false;
   }

   // 3. Circuit breaker state
   if(g_circuitBreakerTripped)
   {
      reason = "Circuit breaker is active (3 consecutive errors reached)";
      return false;
   }

   // 4. Equity drawdown limit
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_initialEquity - currentEquity) >= InpMaxDrawdownEUR)
   {
      reason = StringFormat("Equity drop %.2f EUR >= %.2f EUR stop",
                            (g_initialEquity - currentEquity), InpMaxDrawdownEUR);
      return false;
   }

   // 5. Consecutive errors circuit breaker check
   if(g_consecutiveErrors >= 3)
   {
      g_circuitBreakerTripped = true;
      SavePersistentState();
      reason = StringFormat("Circuit breaker tripped: %d consecutive errors", g_consecutiveErrors);
      return false;
   }

   // 6. Max orders per day limit
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   if(g_currentDayUtc != todayStart)
   {
      g_currentDayUtc = todayStart;
      g_dailyOrderCount = 0;
      SavePersistentState();
   }

   if(g_dailyOrderCount >= InpMaxOrdersPerDay)
   {
      reason = StringFormat("Daily limit reached: %d/%d orders today",
                            g_dailyOrderCount, InpMaxOrdersPerDay);
      return false;
   }

   // 7. Max 1 open position across account
   if(PositionsTotal() > 1)
   {
      reason = StringFormat("Safety violation: %d open positions > 1 max allowed", PositionsTotal());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Execute BUY Entry                                                |
//+------------------------------------------------------------------+
bool ExecuteEntry(string symbol, int symIdx)
{
   // Check market status
   datetime nowUtc = TimeGMT();
   if(IsMarketClosed(nowUtc))
   {
      LogSkip(symbol, "market_closed", "Forex market is closed for weekend");
      return false;
   }

   // Fresh tick check via tracker
   MqlTick tick = g_trackers[symIdx].last_tick;
   if(tick.bid <= 0 || tick.ask <= 0)
   {
      LogSkip(symbol, "no_tick", "SymbolInfoTick returned invalid or zero quote");
      return false;
   }

   // Gate 1: Spread > 0 (bid < ask)
   double spread = tick.ask - tick.bid;
   if(spread <= 0.0 || tick.bid >= tick.ask)
   {
      LogSkip(symbol, "zero_spread", StringFormat("Reported spread is %.5f <= 0 (bid >= ask)", spread));
      return false;
   }

   // Gate 2: Local tick age <= 500 ms
   double tickAgeMs = GetTickAgeMs(symIdx);
   if(tickAgeMs > 500.0)
   {
      LogSkip(symbol, "stale_tick", StringFormat("Tick age %.1f ms > 500 ms threshold", tickAgeMs));
      return false;
   }

   // Cache entry snapshot metrics
   g_entrySnapshotTick = tick;
   g_entrySnapAgeMs = tickAgeMs;
   g_entryReqPrice = tick.ask;
   g_entrySpreadPts = spread / SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryMid = (tick.bid + tick.ask) / 2.0;
   g_entrySession = GetCurrentSession(nowUtc);

   // Configure CTrade
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Execute BUY order with microsecond timing
   ulong t0 = GetMicrosecondCount();
   bool res = m_trade.Buy(InpVolume, symbol, g_entryReqPrice, 0, 0, "exec_ea_in");
   ulong t1 = GetMicrosecondCount();
   g_entryLatencyMs = (double)(t1 - t0) / 1000.0;

   uint retcode = m_trade.ResultRetcode();
   double fillPrice = m_trade.ResultPrice();

   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s ENTRY FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), g_entryLatencyMs);
      LogTrade(symbol, "BUY", InpVolume, g_entryReqPrice, fillPrice,
               tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
               (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);
      g_consecutiveErrors++;
      SavePersistentState();
      return false;
   }

   g_entryFillPrice = fillPrice;
   g_currentPositionTicket = m_trade.ResultOrder();
   g_positionOpenLocalMs = GetTickCount64();
   g_consecutiveErrors = 0;
   SavePersistentState();

   // Execution slippage vs prevailing tick at deal time
   g_entryExecSlipPts = 0.0;
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
   {
      long dealTimeMsc = HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      MqlTick dealTicks[];
      datetime dealDt = (datetime)(dealTimeMsc / 1000);
      int nTicks = CopyTicksRange(symbol, dealTicks, COPY_TICKS_ALL, (dealDt - 2) * 1000, (dealDt + 2) * 1000);
      if(nTicks > 0)
      {
         for(int i = nTicks - 1; i >= 0; i--)
         {
            if((long)dealTicks[i].time_msc <= dealTimeMsc)
            {
               double prevAsk = dealTicks[i].ask;
               double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
               g_entryExecSlipPts = (pt > 0) ? ((g_entryFillPrice - prevAsk) / pt) : 0.0;
               break;
            }
         }
      }
   }

   // Decision drift vs quote at send
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryDriftPts = (pt > 0) ? ((g_entryFillPrice - g_entryReqPrice) / pt) : 0.0;

   // Query mid at fill
   MqlTick tickAfterFill;
   if(SymbolInfoTick(symbol, tickAfterFill) && tickAfterFill.bid > 0 && tickAfterFill.ask > 0)
      g_entryMidAtFill = (tickAfterFill.bid + tickAfterFill.ask) / 2.0;
   else
      g_entryMidAtFill = g_entryMid;

   LogTrade(symbol, "BUY", InpVolume, g_entryReqPrice, g_entryFillPrice,
            tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
            (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   PrintFormat("[%s ENTRY FILLED] [%s] BUY %.2f @ %f (Req: %f) | Latency: %.1f ms | ExecSlip: %+.2f pt | Drift: %+.2f pt",
               symbol, g_entrySession, InpVolume, g_entryFillPrice, g_entryReqPrice,
               g_entryLatencyMs, g_entryExecSlipPts, g_entryDriftPts);

   return true;
}

//+------------------------------------------------------------------+
//| Execute Position Close (SELL Exit) & Log Roundtrip               |
//+------------------------------------------------------------------+
bool ExecuteExit(string symbol, int symIdx)
{
   if(!m_position.Select(symbol))
   {
      PrintFormat("[%s EXIT ERROR] Position not found for close", symbol);
      return false;
   }

   ulong posTicket = m_position.Ticket();
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double fxToEur = GetFxToEur(symbol);

   // Exit gate validation
   MqlTick tick = g_trackers[symIdx].last_tick;
   double spread = tick.ask - tick.bid;
   double tickAgeMs = GetTickAgeMs(symIdx);

   g_exitZeroSpread = (spread <= 0.0 || tick.bid >= tick.ask);
   double exitReqPrice = tick.bid;
   double midExit = (tick.bid > 0 && tick.ask > 0) ? ((tick.bid + tick.ask) / 2.0) : tick.bid;

   // CTrade close with microsecond timing
   m_trade.SetDeviationInPoints(InpDeviation);
   ulong t0 = GetMicrosecondCount();
   bool res = m_trade.PositionClose(posTicket, InpDeviation);
   ulong t1 = GetMicrosecondCount();
   double exitLatencyMs = (double)(t1 - t0) / 1000.0;

   uint retcode = m_trade.ResultRetcode();
   double exitFillPrice = m_trade.ResultPrice();

   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s EXIT FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), exitLatencyMs);
      LogTrade(symbol, "SELL", InpVolume, exitReqPrice, exitFillPrice,
               tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
               (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);
      g_consecutiveErrors++;
      SavePersistentState();
      return false;
   }

   g_consecutiveErrors = 0;
   SavePersistentState();

   // Exit execution slippage vs prevailing tick at deal time
   double exitExecSlipPts = 0.0;
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
   {
      long dealTimeMsc = HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      MqlTick dealTicks[];
      datetime dealDt = (datetime)(dealTimeMsc / 1000);
      int nTicks = CopyTicksRange(symbol, dealTicks, COPY_TICKS_ALL, (dealDt - 2) * 1000, (dealDt + 2) * 1000);
      if(nTicks > 0)
      {
         for(int i = nTicks - 1; i >= 0; i--)
         {
            if((long)dealTicks[i].time_msc <= dealTimeMsc)
            {
               double prevBid = dealTicks[i].bid;
               exitExecSlipPts = (pt > 0) ? ((prevBid - exitFillPrice) / pt) : 0.0;
               break;
            }
         }
      }
   }

   double exitDriftPts = (pt > 0) ? ((exitReqPrice - exitFillPrice) / pt) : 0.0;

   // First tick after exit fill
   MqlTick tickAfterExit;
   double exitMidAtFill = midExit;
   if(SymbolInfoTick(symbol, tickAfterExit) && tickAfterExit.bid > 0 && tickAfterExit.ask > 0)
      exitMidAtFill = (tickAfterExit.bid + tickAfterExit.ask) / 2.0;

   LogTrade(symbol, "SELL", InpVolume, exitReqPrice, exitFillPrice,
            tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
            (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   // Exact Cost Measures
   double slippageBuyMidFillPts = (pt > 0) ? ((g_entryFillPrice - g_entryMidAtFill) / pt) : 0.0;
   double slippageSellMidFillPts = (pt > 0) ? ((exitMidAtFill - exitFillPrice) / pt) : 0.0;
   double exitSpreadPts = spread / pt;

   // (a) Fill-to-fill cost
   double rawDiff = exitFillPrice - g_entryFillPrice;
   double f2fDrag = -rawDiff;
   double f2fCostEur = f2fDrag * InpVolume * contractSize * fxToEur;
   double f2fCostBps = (g_entryMid > 0) ? ((f2fDrag / g_entryMid) * 10000.0) : 0.0;

   // (b) Mid-adjusted cost
   double entryFriction = g_entryFillPrice - g_entryMid;
   double exitFriction = midExit - exitFillPrice;
   double midAdjDrag = entryFriction + exitFriction;
   double midAdjCostEur = midAdjDrag * InpVolume * contractSize * fxToEur;
   double midAdjCostBps = (g_entryMid > 0) ? ((midAdjDrag / g_entryMid) * 10000.0) : 0.0;

   // Mid move during hold
   double midMove = midExit - g_entryMid;
   double midMovePts = (pt > 0) ? (midMove / pt) : 0.0;

   // Models
   double modelCostEur = 0.0;
   double modelCost1spEur = 0.0;
   string ratioStr = "N/A";
   string ratio1spStr = "N/A";

   if(g_entrySpreadPts > 0)
   {
      double entrySpreadPrice = g_entrySpreadPts * pt;
      modelCostEur = 2.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
      if(modelCostEur > 0)
         ratioStr = StringFormat("%.2f", midAdjCostEur / modelCostEur);

      modelCost1spEur = 1.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
      if(modelCost1spEur > 0)
         ratio1spStr = StringFormat("%.2f", midAdjCostEur / modelCost1spEur);
   }

   double rawPnlEur = rawDiff * InpVolume * contractSize * fxToEur;

   LogRoundtrip(symbol, InpVolume, g_entryReqPrice, g_entryFillPrice,
                exitReqPrice, exitFillPrice, g_entrySnapAgeMs,
                g_entryDriftPts, exitDriftPts,
                g_entryMidAtFill, exitMidAtFill,
                slippageBuyMidFillPts, slippageSellMidFillPts,
                g_entrySpreadPts, exitSpreadPts,
                g_entryMid, midExit, midMovePts,
                f2fCostEur, f2fCostBps,
                midAdjCostEur, midAdjCostBps,
                modelCostEur, ratioStr,
                modelCost1spEur, ratio1spStr,
                rawPnlEur, (double)InpHoldSeconds, false,
                g_exitGateWaitedMs, g_exitZeroSpread,
                g_entryExecSlipPts, exitExecSlipPts,
                g_entryDriftPts, exitDriftPts,
                (double)g_entrySnapshotTick.time_msc, (double)g_entrySnapshotTick.time_msc,
                0.0, false);

   PrintFormat("[%s ROUND-TRIP] F2F: %.4f EUR (%.2f bps) | Mid-Adj: %.4f EUR (%.2f bps) | Ratio 2-sp: %s | Ratio 1-sp: %s | MidMove: %+.1f pts",
               symbol, f2fCostEur, f2fCostBps, midAdjCostEur, midAdjCostBps, ratioStr, ratio1spStr, midMovePts);

   return true;
}

//+------------------------------------------------------------------+
//| Check and Close Any Orphan Position with EA's Magic Number       |
//+------------------------------------------------------------------+
bool CheckAndCloseOrphanPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == InpMagicNumber)
         {
            string sym = m_position.Symbol();
            ulong ticket = m_position.Ticket();
            PrintFormat("[ORPHAN POSITION FOUND] Ticket: %I64d | Symbol: %s | Volume: %.2f. Waiting for valid tick to close...",
                        ticket, sym, m_position.Volume());

            int symIdx = (sym == "EURUSD") ? 0 : 1;
            UpdateSymbolTick(symIdx);
            MqlTick tick = g_trackers[symIdx].last_tick;
            double tickAge = GetTickAgeMs(symIdx);

            if(tick.bid > 0 && tick.ask > 0 && tick.bid < tick.ask && tickAge <= 2000.0)
            {
               m_trade.SetDeviationInPoints(InpDeviation);
               if(m_trade.PositionClose(ticket, InpDeviation))
               {
                  PrintFormat("[ORPHAN POSITION CLOSED] Successfully closed ticket %I64d", ticket);
                  return true;
               }
               else
               {
                  PrintFormat("[ORPHAN CLOSE RETRY] Retcode %u: %s", m_trade.ResultRetcode(), m_trade.ResultComment());
                  return false;
               }
            }
            return false; // Valid tick not yet present, will retry on next timer tick
         }
      }
   }
   return true; // No orphan positions
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=================================================");
   Print("INITIALIZING MT5 EXECUTION QUALITY EA (ExecTest)");
   Print("=================================================");

   // Hard safety rule: DEMO account verification
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Alert("FATAL: Account is NOT DEMO! Refusing to initialize ExecTest EA.");
      return INIT_FAILED;
   }

   // Initialize tracker structures
   for(int i = 0; i < 2; i++)
   {
      g_trackers[i].last_tick_msc = 0;
      g_trackers[i].local_first_seen_ms = 0;
      SymbolSelect(g_activeSymbols[i], true);
      m_symbols[i].Name(g_activeSymbols[i]);
      UpdateSymbolTick(i);
   }

   // Load Persistent State
   LoadPersistentState();

   // Initialize CSV files in Common\Files
   InitCsvFiles();

   // Check if orphan positions exist with EA's magic number
   bool orphanExists = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         orphanExists = true;
         PrintFormat("[INIT CHECK] Orphan position found on %s (Ticket: %I64d). Will close before new entries.",
                     m_position.Symbol(), m_position.Ticket());
         break;
      }
   }

   if(orphanExists)
      g_state = STATE_CLEANUP_ORPHAN;
   else
   {
      g_state = STATE_IDLE;
      g_nextCycleLocalMs = GetTickCount64() + 5000; // Start in 5 seconds
   }

   // Set high-frequency millisecond polling timer (10-20 ms)
   EventSetMillisecondTimer(InpPollIntervalMs);

   PrintFormat("[SAFETY VERIFIED] Demo Account: %I64d | Baseline Equity: %.2f EUR | Max Orders/Day: %d | Poll Interval: %d ms",
               AccountInfoInteger(ACCOUNT_LOGIN), g_initialEquity, InpMaxOrdersPerDay, InpPollIntervalMs);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SavePersistentState();
   PrintFormat("[SHUTDOWN] ExecTest EA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| Expert timer function: High Frequency Polling (10-20 ms)         |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Always poll SymbolInfoTick for both active symbols to keep last_tick_msc and local_first_seen_ms fresh
   for(int i = 0; i < 2; i++)
      UpdateSymbolTick(i);

   string reason = "";
   if(!CheckSafetyLimits(reason))
   {
      static ulong lastSafetyLog = 0;
      ulong nowLocal = GetTickCount64();
      if(nowLocal - lastSafetyLog > 10000) // Log once every 10 seconds
      {
         PrintFormat("[SAFETY ABORT/PAUSE] %s", reason);
         lastSafetyLog = nowLocal;
      }

      if(g_circuitBreakerTripped || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR)
      {
         g_state = STATE_ABORTED;
         EventKillTimer();
      }
      return;
   }

   ulong nowLocal = GetTickCount64();

   switch(g_state)
   {
      case STATE_CLEANUP_ORPHAN:
      {
         if(CheckAndCloseOrphanPosition())
         {
            Print("[ORPHAN CLEANUP COMPLETE] All orphan positions resolved. Transitioning to IDLE.");
            g_state = STATE_IDLE;
            g_nextCycleLocalMs = nowLocal + 5000;
         }
         break;
      }

      case STATE_IDLE:
      {
         if(nowLocal >= g_nextCycleLocalMs)
         {
            int symIdx = g_symbolIndex % 2;
            g_currentSymbol = g_activeSymbols[symIdx];
            g_symbolIndex++;

            PrintFormat("[CYCLE TRIGGER] Attempting round-trip on %s...", g_currentSymbol);
            bool ok = ExecuteEntry(g_currentSymbol, symIdx);
            if(ok)
            {
               g_state = STATE_HOLDING;
            }
            else
            {
               // Retry in 2 minutes (120,000 ms) if entry skipped or failed
               g_nextCycleLocalMs = nowLocal + 120000;
               g_state = STATE_CYCLE_SLEEP;
            }
         }
         break;
      }

      case STATE_HOLDING:
      {
         // Wait for 60 seconds position hold duration using local millisecond ticks
         if((nowLocal - g_positionOpenLocalMs) >= (ulong)(InpHoldSeconds * 1000))
         {
            g_state = STATE_WAIT_EXIT_GATE;
            g_exitGateStartLocalMs = nowLocal;
            g_exitGateWaitedMs = 0.0;
         }
         break;
      }

      case STATE_WAIT_EXIT_GATE:
      {
         int symIdx = (g_currentSymbol == "EURUSD") ? 0 : 1;
         MqlTick tick = g_trackers[symIdx].last_tick;
         double spread = tick.ask - tick.bid;
         double tickAge = GetTickAgeMs(symIdx);
         double elapsedGateMs = (double)(nowLocal - g_exitGateStartLocalMs);

         // Exit gate: if bid >= ask or tick age > 2000 ms, wait up to 3000 ms
         if((spread <= 0.0 || tick.bid >= tick.ask || tickAge > 2000.0) && elapsedGateMs < 3000.0)
         {
            g_exitGateWaitedMs = elapsedGateMs;
            return;
         }

         g_exitGateWaitedMs = elapsedGateMs;
         bool ok = ExecuteExit(g_currentSymbol, symIdx);

         // Schedule next trade cycle (40 orders/day = 20 round-trips -> ~36 min interval)
         g_nextCycleLocalMs = nowLocal + ((ulong)InpCycleIntervalMin * 60 * 1000);
         g_state = STATE_CYCLE_SLEEP;
         break;
      }

      case STATE_CYCLE_SLEEP:
      {
         if(nowLocal >= g_nextCycleLocalMs)
         {
            g_state = STATE_IDLE;
         }
         break;
      }

      case STATE_ABORTED:
         break;
   }
}
//+------------------------------------------------------------------+
