//+------------------------------------------------------------------+
//|                                                     ExecTest.mq5 |
//|                                  MT5 Execution Quality Benchmark |
//|                                                                  |
//| Port of slow_strategies/mt5_exec_test/exec_test.py to native MQL5|
//+------------------------------------------------------------------+
#property copyright "Execution Quality Benchmark"
#property link      ""
#property version   "1.02"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Hard Constraints
#define MAX_ALLOWED_VOLUME 0.01

//--- Input Parameters
input group "=== Strategy Parameters ==="
input double   InpVolume            = 0.01;      // Trade Volume (lots, max 0.01)
input ulong    InpDeviation         = 20;        // Slippage Deviation Points
input int      InpHoldSeconds       = 60;        // Hold duration per round-trip
input int      InpCycleIntervalMin  = 36;        // Cycle interval (minutes) between trades
input int      InpMaxOrdersPerDay   = 40;        // Maximum orders per day limit
input double   InpMaxDrawdownEUR    = 50.0;      // Equity drawdown stop (EUR)
input ulong    InpMagicNumber       = 20261009;  // Magic number
input int      InpPollIntervalMs    = 15;        // Polling interval in ms (10-20 ms)

//--- Global Variables Persistence Keys
// Note: MT5 terminal GlobalVariables expire after ~4 weeks without access
#define GV_BASELINE_EQUITY    "EXECTEST_BASELINE_EQUITY"
#define GV_BASELINE_DATE_UTC  "EXECTEST_BASELINE_DATE_UTC"
#define GV_CIRCUIT_BREAKER    "EXECTEST_CIRCUIT_BREAKER"
#define GV_CONSEC_ERRORS      "EXECTEST_CONSEC_ERRORS"
#define GV_DAILY_ORDER_COUNT  "EXECTEST_DAILY_ORDER_COUNT"
#define GV_DAILY_DATE_UTC     "EXECTEST_DAILY_DATE_UTC"

// Persistence keys for open position & hold metrics
#define GV_HOLD_TICKET        "EXECTEST_HOLD_TICKET"
#define GV_HOLD_SYM_IDX       "EXECTEST_HOLD_SYM_IDX"
#define GV_HOLD_START_TIME    "EXECTEST_HOLD_START_TIME"
#define GV_HOLD_LOCAL_MS      "EXECTEST_HOLD_LOCAL_MS"
#define GV_HOLD_REQ_PRICE     "EXECTEST_HOLD_REQ_PRICE"
#define GV_HOLD_FILL_PRICE    "EXECTEST_HOLD_FILL_PRICE"
#define GV_HOLD_LATENCY_MS    "EXECTEST_HOLD_LATENCY_MS"
#define GV_HOLD_SNAP_AGE_MS   "EXECTEST_HOLD_SNAP_AGE_MS"
#define GV_HOLD_SPREAD_PTS    "EXECTEST_HOLD_SPREAD_PTS"
#define GV_HOLD_MID_ENTRY     "EXECTEST_HOLD_MID_ENTRY"
#define GV_HOLD_MID_FILL      "EXECTEST_HOLD_MID_FILL"
#define GV_HOLD_EXEC_SLIP     "EXECTEST_HOLD_EXEC_SLIP"
#define GV_HOLD_DRIFT_PTS     "EXECTEST_HOLD_DRIFT_PTS"
#define GV_HOLD_LOOKUP_OK     "EXECTEST_HOLD_LOOKUP_OK"
#define GV_HOLD_TICK_MSC      "EXECTEST_HOLD_TICK_MSC"

//--- Global Objects & State
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbols[2];

string         g_activeSymbols[2] = {"EURUSD", "USDJPY"};
int            g_symbolIndex = 0;

double         g_actualVolume = 0.01;
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
   STATE_IDLE,
   STATE_HOLDING,
   STATE_EXIT_RETRY,
   STATE_CYCLE_SLEEP,
   STATE_STOPPED
};

ETestState     g_state = STATE_IDLE;
string         g_currentSymbol = "";
ulong          g_currentPositionTicket = 0;
ulong          g_positionOpenLocalMs = 0;
datetime       g_positionOpenTimeServer = 0;
bool           g_isRestartTrip = false;

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
bool           g_entryLookupOk = true;
string         g_entrySession = "";

// Exit gate & retry variables
ulong          g_exitGateStartLocalMs = 0;
double         g_exitGateWaitedMs = 0.0;
bool           g_exitZeroSpread = false;
int            g_exitFailAttempts = 0;
ulong          g_nextExitAttemptLocalMs = 0;

ulong          g_nextCycleLocalMs = 0;

// CSV Filenames in Common\Files
#define FILE_TRADES     "trades.csv"
#define FILE_ROUNDTRIPS "roundtrips.csv"
#define FILE_SKIPS      "skips.csv"

// In-memory buffer for failed CSV writes (M1)
string         g_bufferTrades[];
string         g_bufferRoundtrips[];
string         g_bufferSkips[];

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
//| Helper: Sanitize / Quote CSV comments (M2)                       |
//+------------------------------------------------------------------+
string SanitizeComment(string raw)
{
   string res = raw;
   StringReplace(res, "\"", "'");
   if(StringFind(res, ",") >= 0)
      res = "\"" + res + "\"";
   return res;
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
//| Helper: Detect Supported Filling Mode (M11)                      |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetSymbolFillingMode(string symbol)
{
   uint filling = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
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
//| Persistence: Load state from GlobalVariables (M7, H5)            |
//+------------------------------------------------------------------+
void LoadPersistentState()
{
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);

   // M7: Equity baseline per UTC day (stored in GV, expires ~4 weeks)
   datetime baselineDate = 0;
   if(GlobalVariableCheck(GV_BASELINE_DATE_UTC))
      baselineDate = (datetime)GlobalVariableGet(GV_BASELINE_DATE_UTC);

   if(baselineDate == todayStart && GlobalVariableCheck(GV_BASELINE_EQUITY))
   {
      g_initialEquity = GlobalVariableGet(GV_BASELINE_EQUITY);
      PrintFormat("[PERSISTENCE] Loaded daily baseline equity for %04d-%02d-%02d: %.2f EUR",
                  mdt.year, mdt.mon, mdt.day, g_initialEquity);
   }
   else
   {
      g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GV_BASELINE_DATE_UTC, (double)todayStart);
      GlobalVariableSet(GV_BASELINE_EQUITY, g_initialEquity);
      PrintFormat("[PERSISTENCE] Set new daily baseline equity for %04d-%02d-%02d: %.2f EUR",
                  mdt.year, mdt.mon, mdt.day, g_initialEquity);
   }

   // Circuit breaker
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

   // Consecutive errors
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

   // Daily order count
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
   GlobalVariableSet(GV_CIRCUIT_BREAKER, g_circuitBreakerTripped ? 1.0 : 0.0);
   GlobalVariableSet(GV_CONSEC_ERRORS, (double)g_consecutiveErrors);
   GlobalVariableSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
   GlobalVariableSet(GV_DAILY_ORDER_COUNT, (double)g_dailyOrderCount);
}

//+------------------------------------------------------------------+
//| Persistence: Save Open Position & Hold Metrics (H5)              |
//+------------------------------------------------------------------+
void SaveHoldState(ulong ticket, int symIdx, ulong openLocalMs, datetime openServerTime)
{
   GlobalVariableSet(GV_HOLD_TICKET, (double)ticket);
   GlobalVariableSet(GV_HOLD_SYM_IDX, (double)symIdx);
   GlobalVariableSet(GV_HOLD_START_TIME, (double)openServerTime);
   GlobalVariableSet(GV_HOLD_LOCAL_MS, (double)openLocalMs);
   GlobalVariableSet(GV_HOLD_REQ_PRICE, g_entryReqPrice);
   GlobalVariableSet(GV_HOLD_FILL_PRICE, g_entryFillPrice);
   GlobalVariableSet(GV_HOLD_LATENCY_MS, g_entryLatencyMs);
   GlobalVariableSet(GV_HOLD_SNAP_AGE_MS, g_entrySnapAgeMs);
   GlobalVariableSet(GV_HOLD_SPREAD_PTS, g_entrySpreadPts);
   GlobalVariableSet(GV_HOLD_MID_ENTRY, g_entryMid);
   GlobalVariableSet(GV_HOLD_MID_FILL, g_entryMidAtFill);
   GlobalVariableSet(GV_HOLD_EXEC_SLIP, g_entryExecSlipPts);
   GlobalVariableSet(GV_HOLD_DRIFT_PTS, g_entryDriftPts);
   GlobalVariableSet(GV_HOLD_LOOKUP_OK, g_entryLookupOk ? 1.0 : 0.0);
   GlobalVariableSet(GV_HOLD_TICK_MSC, (double)g_entrySnapshotTick.time_msc);
}

//+------------------------------------------------------------------+
//| Persistence: Clear Open Position & Hold Metrics (H5)             |
//+------------------------------------------------------------------+
void ClearHoldState()
{
   GlobalVariableDel(GV_HOLD_TICKET);
   GlobalVariableDel(GV_HOLD_SYM_IDX);
   GlobalVariableDel(GV_HOLD_START_TIME);
   GlobalVariableDel(GV_HOLD_LOCAL_MS);
   GlobalVariableDel(GV_HOLD_REQ_PRICE);
   GlobalVariableDel(GV_HOLD_FILL_PRICE);
   GlobalVariableDel(GV_HOLD_LATENCY_MS);
   GlobalVariableDel(GV_HOLD_SNAP_AGE_MS);
   GlobalVariableDel(GV_HOLD_SPREAD_PTS);
   GlobalVariableDel(GV_HOLD_MID_ENTRY);
   GlobalVariableDel(GV_HOLD_MID_FILL);
   GlobalVariableDel(GV_HOLD_EXEC_SLIP);
   GlobalVariableDel(GV_HOLD_DRIFT_PTS);
   GlobalVariableDel(GV_HOLD_LOOKUP_OK);
   GlobalVariableDel(GV_HOLD_TICK_MSC);
}

//+------------------------------------------------------------------+
//| Initialize CSV files in FILE_COMMON (M1)                         |
//+------------------------------------------------------------------+
void InitCsvFiles()
{
   // 1. trades.csv
   if(!FileIsExist(FILE_TRADES, FILE_COMMON))
   {
      int h = FileOpen(FILE_TRADES, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,event_type,side,volume,request_price,fill_price,bid_before,ask_before,spread_before,retcode,latency_ms,deviation,comment,tick_time_msc,tick_age_ms,tick_age_method,poll_interval_ms,engine\r\n");
         FileClose(h);
      }
   }

   // 2. roundtrips.csv
   if(!FileIsExist(FILE_ROUNDTRIPS, FILE_COMMON))
   {
      int h = FileOpen(FILE_ROUNDTRIPS, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,volume,entry_request_price,entry_fill_price,exit_request_price,exit_fill_price,snapshot_age_ms,entry_slippage_pts,exit_slippage_pts,mid_at_fill,exit_mid_at_fill,entry_slippage_mid_fill_pts,exit_slippage_mid_fill_pts,spread_at_entry_pts,exit_spread_pts,mid_entry,mid_exit,mid_move_during_hold_pts,fill_to_fill_cost_eur,fill_to_fill_cost_bps,mid_adjusted_cost_eur,mid_adjusted_cost_bps,model_cost_eur,cost_ratio,model_cost_1sp_eur,cost_ratio_1sp,raw_pnl_eur,hold_seconds,pre_filter,restart,exit_gate_waited_ms,exit_zero_spread,lookup_ok,entry_exec_slip_pts,exit_exec_slip_pts,entry_drift_pts,exit_drift_pts,t_tick_server,t_send_local_corrected,send_gap_ms,age_uncorrected,tick_age_method,engine\r\n");
         FileClose(h);
      }
   }

   // 3. skips.csv
   if(!FileIsExist(FILE_SKIPS, FILE_COMMON))
   {
      int h = FileOpen(FILE_SKIPS, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,reason,details,engine\r\n");
         FileClose(h);
      }
   }
}

//+------------------------------------------------------------------+
//| Flush buffered CSV rows (M1)                                     |
//+------------------------------------------------------------------+
void FlushCsvBuffers()
{
   // Trades buffer
   int nTrades = ArraySize(g_bufferTrades);
   if(nTrades > 0)
   {
      int h = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < nTrades; i++)
            FileWriteString(h, g_bufferTrades[i]);
         FileClose(h);
         ArrayResize(g_bufferTrades, 0);
      }
   }

   // Roundtrips buffer
   int nRt = ArraySize(g_bufferRoundtrips);
   if(nRt > 0)
   {
      int h = FileOpen(FILE_ROUNDTRIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < nRt; i++)
            FileWriteString(h, g_bufferRoundtrips[i]);
         FileClose(h);
         ArrayResize(g_bufferRoundtrips, 0);
      }
   }

   // Skips buffer
   int nSk = ArraySize(g_bufferSkips);
   if(nSk > 0)
   {
      int h = FileOpen(FILE_SKIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < nSk; i++)
            FileWriteString(h, g_bufferSkips[i]);
         FileClose(h);
         ArrayResize(g_bufferSkips, 0);
      }
   }
}

//+------------------------------------------------------------------+
//| Logging: Skip (M1)                                               |
//+------------------------------------------------------------------+
void LogSkip(string symbol, string reason, string details)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);
   string safeDetails = SanitizeComment(details);
   string line = StringFormat("%s,%s,%s,%s,%s,mql5\r\n", tsStr, session, symbol, reason, safeDetails);

   int h = FileOpen(FILE_SKIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line);
      FileClose(h);
   }
   else
   {
      PrintFormat("[CSV ERROR] FileOpen %s failed (error %d). Buffering skip row.", FILE_SKIPS, GetLastError());
      int sz = ArraySize(g_bufferSkips);
      ArrayResize(g_bufferSkips, sz + 1);
      g_bufferSkips[sz] = line;
   }
   PrintFormat("[SKIP LOGGED] %s | %s | Reason: %s | %s", symbol, session, reason, safeDetails);
}

//+------------------------------------------------------------------+
//| Logging: Individual Trade / Event (H5, M1, M2, M3)               |
//+------------------------------------------------------------------+
void LogTradeEvent(string symbol, string event_type, string side, double volume, double req_price,
                   double fill_price, double bid_b, double ask_b, double spread_b,
                   uint retcode, double latency_ms, ulong deviation, string comment,
                   long tick_time_msc, double tick_age_ms, int poll_interval_ms)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);
   string safeComment = SanitizeComment(comment);

   string line = StringFormat("%s,%s,%s,%s,%s,%.2f,%f,%f,%f,%f,%f,%u,%.1f,%I64u,%s,%I64d,%.1f,local_first_seen,%d,mql5\r\n",
                              tsStr, session, symbol, event_type, side, volume, req_price, fill_price,
                              bid_b, ask_b, spread_b, retcode, latency_ms, deviation, safeComment,
                              tick_time_msc, tick_age_ms, poll_interval_ms);

   int h = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line);
      FileClose(h);
   }
   else
   {
      PrintFormat("[CSV ERROR] FileOpen %s failed (error %d). Buffering trade row.", FILE_TRADES, GetLastError());
      int sz = ArraySize(g_bufferTrades);
      ArrayResize(g_bufferTrades, sz + 1);
      g_bufferTrades[sz] = line;
   }

   if(event_type == "trade")
   {
      g_dailyOrderCount++;
      SavePersistentState();
   }
}

//+------------------------------------------------------------------+
//| Logging: Completed Round Trip (M1, M3, M5, H5)                   |
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
                  double raw_pnl_eur, double hold_sec, bool pre_filter, bool restart,
                  double exit_gate_waited_ms, bool exit_zero_spread, bool lookup_ok,
                  double entry_exec_slip_pts, double exit_exec_slip_pts,
                  double entry_drift_pts, double exit_drift_pts,
                  double t_tick_server, double t_send_local_corrected,
                  double send_gap_ms, bool age_uncorrected)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);

   string strExecSlipEntry = lookup_ok ? StringFormat("%.2f", entry_exec_slip_pts) : "NaN";
   string strExecSlipExit  = lookup_ok ? StringFormat("%.2f", exit_exec_slip_pts)  : "NaN";

   string line = StringFormat("%s,%s,%s,%.2f,%f,%f,%f,%f,%.1f,%.2f,%.2f,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.5f,%.5f,%.2f,%.4f,%.2f,%.4f,%.2f,%.4f,%s,%.4f,%s,%.4f,%.1f,%s,%s,%.1f,%s,%s,%s,%s,%.2f,%.2f,%.1f,%.1f,%.1f,%s,local_first_seen,mql5\r\n",
                              tsStr, session, symbol, volume, req_buy, fill_buy, req_sell, fill_sell,
                              snapshot_age_ms, slip_buy_send_pts, slip_sell_send_pts,
                              mid_at_fill, exit_mid_at_fill, slip_buy_mid_fill_pts, slip_sell_mid_fill_pts,
                              spread_entry_pts, spread_sell_pts, mid_entry, mid_exit, mid_move_pts,
                              f2f_cost_eur, f2f_cost_bps, midadj_cost_eur, midadj_cost_bps,
                              model_cost_eur, cost_ratio_str, model_cost_1sp_eur, cost_ratio_1sp_str,
                              raw_pnl_eur, hold_sec, (pre_filter ? "True" : "False"), (restart ? "True" : "False"),
                              exit_gate_waited_ms, (exit_zero_spread ? "True" : "False"),
                              (lookup_ok ? "True" : "False"),
                              strExecSlipEntry, strExecSlipExit, entry_drift_pts, exit_drift_pts,
                              t_tick_server, t_send_local_corrected, send_gap_ms,
                              (age_uncorrected ? "True" : "False"));

   int h = FileOpen(FILE_ROUNDTRIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line);
      FileClose(h);
   }
   else
   {
      PrintFormat("[CSV ERROR] FileOpen %s failed (error %d). Buffering roundtrip row.", FILE_ROUNDTRIPS, GetLastError());
      int sz = ArraySize(g_bufferRoundtrips);
      ArrayResize(g_bufferRoundtrips, sz + 1);
      g_bufferRoundtrips[sz] = line;
   }
}

//+------------------------------------------------------------------+
//| Check Entry Safety Limits (H1, H3) - BLOCKS ENTRIES ONLY         |
//+------------------------------------------------------------------+
bool CheckEntrySafetyLimits(string &reason)
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

   // 4. Equity drawdown limit (EUR 50 stop against daily baseline)
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_initialEquity - currentEquity) >= InpMaxDrawdownEUR)
   {
      reason = StringFormat("Equity drop %.2f EUR >= %.2f EUR stop (Baseline: %.2f, Current: %.2f)",
                            (g_initialEquity - currentEquity), InpMaxDrawdownEUR, g_initialEquity, currentEquity);
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

   // 7. H3: Entry Precondition: PositionsTotal() == 0 across account & foreign positions check
   int totalPos = PositionsTotal();
   if(totalPos > 0)
   {
      int ownCount = 0;
      int foreignCount = 0;
      for(int i = 0; i < totalPos; i++)
      {
         if(m_position.SelectByIndex(i))
         {
            if(m_position.Magic() == InpMagicNumber)
               ownCount++;
            else
               foreignCount++;
         }
      }
      if(foreignCount > 0)
         reason = StringFormat("Foreign position exists on account (%d foreign positions). Skipping entry.", foreignCount);
      else
         reason = StringFormat("Open position exists (%d positions). Skipping entry.", ownCount);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Execute BUY Entry (H6, M6, M11)                                  |
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

   // M11: Configure supported filling mode
   ENUM_ORDER_TYPE_FILLING fillingMode = GetSymbolFillingMode(symbol);
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetTypeFilling(fillingMode);

   // Execute BUY order with microsecond timing
   ulong t0 = GetMicrosecondCount();
   bool res = m_trade.Buy(g_actualVolume, symbol, g_entryReqPrice, 0, 0, "exec_ea_in");
   ulong t1 = GetMicrosecondCount();
   g_entryLatencyMs = (double)(t1 - t0) / 1000.0;

   uint retcode = m_trade.ResultRetcode();
   double fillPrice = m_trade.ResultPrice();

   // H6: Reconcile non-DONE retcodes
   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s ENTRY FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), g_entryLatencyMs);

      // Check whether an open position was actually created despite error
      ulong foundTicket = 0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber && m_position.Symbol() == symbol)
         {
            foundTicket = m_position.Ticket();
            break;
         }
      }

      if(foundTicket > 0)
      {
         PrintFormat("[RECONCILIATION] Position found (Ticket: %I64d) after non-DONE retcode %u. Adopting position.",
                     foundTicket, retcode);
         g_currentPositionTicket = foundTicket;
         g_entryFillPrice = m_position.PriceOpen();
         g_positionOpenLocalMs = GetTickCount64();
         g_positionOpenTimeServer = TimeCurrent();
         g_isRestartTrip = false;
         SaveHoldState(g_currentPositionTicket, symIdx, g_positionOpenLocalMs, g_positionOpenTimeServer);
         return true;
      }

      // M11: Filling mode rejection does NOT count toward circuit breaker
      bool isFillingReject = (retcode == TRADE_RETCODE_INVALID_FILL);
      if(!isFillingReject)
         g_consecutiveErrors++;

      LogTradeEvent(symbol, "trade", "BUY", g_actualVolume, g_entryReqPrice, fillPrice,
                    tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                    (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

      SavePersistentState();
      return false;
   }

   g_entryFillPrice = fillPrice;
   g_currentPositionTicket = m_trade.ResultOrder();
   g_positionOpenLocalMs = GetTickCount64();
   g_positionOpenTimeServer = TimeCurrent();
   g_isRestartTrip = false;
   g_consecutiveErrors = 0;
   SavePersistentState();

   // M5 & M6: Execution slippage & mid_at_fill via CopyTicksRange
   g_entryExecSlipPts = 0.0;
   g_entryLookupOk = false;
   g_entryMidAtFill = g_entryMid;

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
               double prevBid = dealTicks[i].bid;
               double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
               g_entryExecSlipPts = (pt > 0) ? ((g_entryFillPrice - prevAsk) / pt) : 0.0;
               // M6: mid_at_fill from last tick at or before deal time in CopyTicksRange
               if(prevBid > 0 && prevAsk > 0)
                  g_entryMidAtFill = (prevBid + prevAsk) / 2.0;
               g_entryLookupOk = true;
               break;
            }
         }
      }
   }

   if(!g_entryLookupOk)
      g_entryExecSlipPts = 0.0; // Handled as NaN in CSV

   // Decision drift vs quote at send
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryDriftPts = (pt > 0) ? ((g_entryFillPrice - g_entryReqPrice) / pt) : 0.0;

   // H5: Persist hold state
   SaveHoldState(g_currentPositionTicket, symIdx, g_positionOpenLocalMs, g_positionOpenTimeServer);

   LogTradeEvent(symbol, "trade", "BUY", g_actualVolume, g_entryReqPrice, g_entryFillPrice,
                 tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                 (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   PrintFormat("[%s ENTRY FILLED] [%s] BUY %.2f @ %f (Req: %f) | Latency: %.1f ms | ExecSlip: %s | Drift: %+.2f pt",
               symbol, g_entrySession, g_actualVolume, g_entryFillPrice, g_entryReqPrice,
               g_entryLatencyMs, (g_entryLookupOk ? StringFormat("%+.2f pt", g_entryExecSlipPts) : "NaN"), g_entryDriftPts);

   return true;
}

//+------------------------------------------------------------------+
//| Execute Position Close (H1, H2, M5, M6, M10)                     |
//+------------------------------------------------------------------+
bool ExecuteExit(string symbol, int symIdx, ulong posTicket, bool isOrphanCleanup)
{
   // M10: Select position by ticket and verify magic
   if(!m_position.SelectByTicket(posTicket) || m_position.Magic() != InpMagicNumber)
   {
      // If position not found by ticket, search across open positions
      bool found = false;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber && m_position.Symbol() == symbol)
         {
            posTicket = m_position.Ticket();
            found = true;
            break;
         }
      }
      if(!found)
      {
         PrintFormat("[%s EXIT] Position %I64d already closed or not found.", symbol, posTicket);
         ClearHoldState();
         return true;
      }
   }

   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double fxToEur = GetFxToEur(symbol);

   // Exit quote from tracker
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

   // H2: Read close result
   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s EXIT FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), exitLatencyMs);

      // Verify whether position is actually still open
      if(!m_position.SelectByTicket(posTicket))
      {
         PrintFormat("[RECONCILIATION] Position %I64d closed despite retcode %u.", posTicket, retcode);
         ClearHoldState();
         return true;
      }

      // Log close failure row in trades.csv (H5)
      LogTradeEvent(symbol, "close_failure", "SELL", g_actualVolume, exitReqPrice, exitFillPrice,
                    tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
                    (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

      return false; // Stays in exit state to retry
   }

   // Successful close
   ClearHoldState();

   // M5 & M6: Exit execution slippage & exit mid_at_fill via CopyTicksRange
   double exitExecSlipPts = 0.0;
   bool exitLookupOk = false;
   double exitMidAtFill = midExit;

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
               double prevAsk = dealTicks[i].ask;
               exitExecSlipPts = (pt > 0) ? ((prevBid - exitFillPrice) / pt) : 0.0;
               if(prevBid > 0 && prevAsk > 0)
                  exitMidAtFill = (prevBid + prevAsk) / 2.0;
               exitLookupOk = true;
               break;
            }
         }
      }
   }

   double exitDriftPts = (pt > 0) ? ((exitReqPrice - exitFillPrice) / pt) : 0.0;
   string eventType = isOrphanCleanup ? "orphan_close" : (g_isRestartTrip ? "restart_cleanup" : "trade");

   LogTradeEvent(symbol, eventType, "SELL", g_actualVolume, exitReqPrice, exitFillPrice,
                 tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
                 (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   // Roundtrip calculations
   double slippageBuyMidFillPts = (pt > 0) ? ((g_entryFillPrice - g_entryMidAtFill) / pt) : 0.0;
   double slippageSellMidFillPts = (pt > 0) ? ((exitMidAtFill - exitFillPrice) / pt) : 0.0;
   double exitSpreadPts = spread / pt;

   // (a) Fill-to-fill cost
   double rawDiff = exitFillPrice - g_entryFillPrice;
   double f2fDrag = -rawDiff;
   double f2fCostEur = f2fDrag * g_actualVolume * contractSize * fxToEur;
   double f2fCostBps = (g_entryMid > 0) ? ((f2fDrag / g_entryMid) * 10000.0) : 0.0;

   // (b) Mid-adjusted cost
   double entryFriction = g_entryFillPrice - g_entryMid;
   double exitFriction = midExit - exitFillPrice;
   double midAdjDrag = entryFriction + exitFriction;
   double midAdjCostEur = midAdjDrag * g_actualVolume * contractSize * fxToEur;
   double midAdjCostBps = (g_entryMid > 0) ? ((midAdjDrag / g_entryMid) * 10000.0) : 0.0;

   double midMove = midExit - g_entryMid;
   double midMovePts = (pt > 0) ? (midMove / pt) : 0.0;

   double modelCostEur = 0.0;
   double modelCost1spEur = 0.0;
   string ratioStr = "N/A";
   string ratio1spStr = "N/A";

   if(g_entrySpreadPts > 0)
   {
      double entrySpreadPrice = g_entrySpreadPts * pt;
      modelCostEur = 2.0 * entrySpreadPrice * g_actualVolume * contractSize * fxToEur;
      if(modelCostEur > 0)
         ratioStr = StringFormat("%.2f", midAdjCostEur / modelCostEur);

      modelCost1spEur = 1.0 * entrySpreadPrice * g_actualVolume * contractSize * fxToEur;
      if(modelCost1spEur > 0)
         ratio1spStr = StringFormat("%.2f", midAdjCostEur / modelCost1spEur);
   }

   double rawPnlEur = rawDiff * g_actualVolume * contractSize * fxToEur;
   bool overallLookupOk = (g_entryLookupOk && exitLookupOk);

   LogRoundtrip(symbol, g_actualVolume, g_entryReqPrice, g_entryFillPrice,
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
                rawPnlEur, (double)InpHoldSeconds, false, g_isRestartTrip,
                g_exitGateWaitedMs, g_exitZeroSpread, overallLookupOk,
                g_entryExecSlipPts, exitExecSlipPts,
                g_entryDriftPts, exitDriftPts,
                (double)g_entrySnapshotTick.time_msc, (double)g_entrySnapshotTick.time_msc,
                0.0, false);

   PrintFormat("[%s ROUND-TRIP] F2F: %.4f EUR (%.2f bps) | Mid-Adj: %.4f EUR (%.2f bps) | Ratio 2-sp: %s | Restart: %s",
               symbol, f2fCostEur, f2fCostBps, midAdjCostEur, midAdjCostBps, ratioStr, (g_isRestartTrip ? "True" : "False"));

   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function (H3, H4, H5, M7)                  |
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

   // H4: Validate InpVolume against MAX_ALLOWED_VOLUME (0.01)
   if(InpVolume > MAX_ALLOWED_VOLUME)
   {
      Alert(StringFormat("FATAL: InpVolume (%.4f) exceeds maximum allowed volume of %.2f lot!",
                         InpVolume, MAX_ALLOWED_VOLUME));
      return INIT_FAILED;
   }

   // Validate volume against broker symbol limits
   for(int i = 0; i < 2; i++)
   {
      double volMin  = SymbolInfoDouble(g_activeSymbols[i], SYMBOL_VOLUME_MIN);
      double volStep = SymbolInfoDouble(g_activeSymbols[i], SYMBOL_VOLUME_STEP);
      if(InpVolume < volMin)
      {
         Alert(StringFormat("FATAL: InpVolume (%.4f) is below %s minimum volume (%.4f)!",
                            InpVolume, g_activeSymbols[i], volMin));
         return INIT_FAILED;
      }
   }
   g_actualVolume = MAX_ALLOWED_VOLUME;

   // Initialize tracker structures
   for(int i = 0; i < 2; i++)
   {
      g_trackers[i].last_tick_msc = 0;
      g_trackers[i].local_first_seen_ms = 0;
      SymbolSelect(g_activeSymbols[i], true);
      m_symbols[i].Name(g_activeSymbols[i]);
      UpdateSymbolTick(i);
   }

   // Load Persistent State (M7)
   LoadPersistentState();

   // Initialize CSV files in Common\Files (M1)
   InitCsvFiles();

   // H5: Check if hold state or orphan position exists on restart
   ulong existingTicket = 0;
   string existingSymbol = "";
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         existingTicket = m_position.Ticket();
         existingSymbol = m_position.Symbol();
         break;
      }
   }

   if(existingTicket > 0)
   {
      g_currentPositionTicket = existingTicket;
      g_currentSymbol = existingSymbol;
      g_isRestartTrip = true;

      // Check if hold metrics were persisted
      if(GlobalVariableCheck(GV_HOLD_TICKET) && (ulong)GlobalVariableGet(GV_HOLD_TICKET) == existingTicket)
      {
         g_entryReqPrice    = GlobalVariableGet(GV_HOLD_REQ_PRICE);
         g_entryFillPrice   = GlobalVariableGet(GV_HOLD_FILL_PRICE);
         g_entryLatencyMs   = GlobalVariableGet(GV_HOLD_LATENCY_MS);
         g_entrySnapAgeMs   = GlobalVariableGet(GV_HOLD_SNAP_AGE_MS);
         g_entrySpreadPts   = GlobalVariableGet(GV_HOLD_SPREAD_PTS);
         g_entryMid         = GlobalVariableGet(GV_HOLD_MID_ENTRY);
         g_entryMidAtFill   = GlobalVariableGet(GV_HOLD_MID_FILL);
         g_entryExecSlipPts = GlobalVariableGet(GV_HOLD_EXEC_SLIP);
         g_entryDriftPts    = GlobalVariableGet(GV_HOLD_DRIFT_PTS);
         g_entryLookupOk    = (GlobalVariableGet(GV_HOLD_LOOKUP_OK) > 0.5);
         g_entrySnapshotTick.time_msc = (long)GlobalVariableGet(GV_HOLD_TICK_MSC);
         g_positionOpenLocalMs = (ulong)GlobalVariableGet(GV_HOLD_LOCAL_MS);
         g_positionOpenTimeServer = (datetime)GlobalVariableGet(GV_HOLD_START_TIME);

         datetime nowServer = TimeCurrent();
         int elapsedSec = (int)(nowServer - g_positionOpenTimeServer);
         PrintFormat("[RESTART RECOVERY] Recovered mid-hold position %I64d (%s). Open time: %s, Elapsed: %d s",
                     existingTicket, existingSymbol, TimeToString(g_positionOpenTimeServer), elapsedSec);

         if(elapsedSec >= InpHoldSeconds)
         {
            g_state = STATE_EXIT_RETRY;
            g_exitGateStartLocalMs = GetTickCount64();
            g_nextExitAttemptLocalMs = 0;
            g_exitFailAttempts = 0;
         }
         else
         {
            g_state = STATE_HOLDING;
         }
      }
      else
      {
         // Orphan position without persisted hold metrics
         PrintFormat("[INIT CHECK] Orphan position found on %s (Ticket: %I64d). Immediate exit scheduled.",
                     existingSymbol, existingTicket);
         g_entryReqPrice = m_position.PriceOpen();
         g_entryFillPrice = m_position.PriceOpen();
         g_entryMid = m_position.PriceOpen();
         g_entryMidAtFill = m_position.PriceOpen();
         g_entrySpreadPts = 0.0;
         g_entryExecSlipPts = 0.0;
         g_entryDriftPts = 0.0;
         g_entryLookupOk = false;
         g_positionOpenLocalMs = GetTickCount64();
         g_positionOpenTimeServer = TimeCurrent();

         g_state = STATE_EXIT_RETRY;
         g_exitGateStartLocalMs = GetTickCount64();
         g_nextExitAttemptLocalMs = 0;
         g_exitFailAttempts = 0;
      }
   }
   else
   {
      ClearHoldState();
      g_state = STATE_IDLE;
      g_nextCycleLocalMs = GetTickCount64() + 5000; // Start in 5 seconds
   }

   // Set millisecond polling timer (10-20 ms)
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
   FlushCsvBuffers();
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

   // Flush any buffered CSV rows
   FlushCsvBuffers();

   ulong nowLocal = GetTickCount64();

   // H1 & H2: Check if any position with EA's magic is currently open
   ulong openTicket = 0;
   string openSymbol = "";
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber)
      {
         openTicket = m_position.Ticket();
         openSymbol = m_position.Symbol();
         break;
      }
   }

   // H1: If position is open, the ONLY allowed action is the exit path.
   // Safety limits trip blocks ENTRIES only; if a limit trips with a position open, close it first.
   if(openTicket > 0)
   {
      g_currentPositionTicket = openTicket;
      g_currentSymbol = openSymbol;
      int symIdx = (openSymbol == "EURUSD") ? 0 : 1;

      if(g_state == STATE_HOLDING)
      {
         // Check hold duration
         if((nowLocal - g_positionOpenLocalMs) >= (ulong)(InpHoldSeconds * 1000))
         {
            g_state = STATE_EXIT_RETRY;
            g_exitGateStartLocalMs = nowLocal;
            g_exitGateWaitedMs = 0.0;
            g_exitFailAttempts = 0;
            g_nextExitAttemptLocalMs = nowLocal;
         }
         return; // In hold period, stay holding
      }

      // If in any state other than HOLDING (e.g. limit tripped, restart, or EXIT_RETRY), execute EXIT
      if(nowLocal >= g_nextExitAttemptLocalMs)
      {
         MqlTick tick = g_trackers[symIdx].last_tick;
         double spread = tick.ask - tick.bid;
         double tickAge = GetTickAgeMs(symIdx);
         double elapsedGateMs = (double)(nowLocal - g_exitGateStartLocalMs);

         // Exit gate: if bid >= ask or tick age > 2000 ms, wait up to 3000 ms on first attempt
         if(g_exitFailAttempts == 0 && (spread <= 0.0 || tick.bid >= tick.ask || tickAge > 2000.0) && elapsedGateMs < 3000.0)
         {
            g_exitGateWaitedMs = elapsedGateMs;
            return; // Wait for clean tick
         }

         g_exitGateWaitedMs = elapsedGateMs;
         bool isOrphan = (g_state == STATE_IDLE || g_state == STATE_CYCLE_SLEEP || g_state == STATE_STOPPED);
         bool closed = ExecuteExit(openSymbol, symIdx, openTicket, isOrphan);

         if(closed)
         {
            PrintFormat("[EXIT SUCCESS] Position %I64d closed successfully.", openTicket);
            g_exitFailAttempts = 0;

            // Check if safety limits tripped; if so, transition to STATE_STOPPED
            string reason = "";
            if(!CheckEntrySafetyLimits(reason))
            {
               PrintFormat("[TRADING STOPPED AFTER CLOSE] %s", reason);
               g_state = STATE_STOPPED;
            }
            else
            {
               g_nextCycleLocalMs = nowLocal + ((ulong)InpCycleIntervalMin * 60 * 1000);
               g_state = STATE_CYCLE_SLEEP;
            }
         }
         else
         {
            // H2: Close failed. Stay in exit state, retry with backoff
            g_exitFailAttempts++;
            if(g_exitFailAttempts >= 5)
            {
               PrintFormat("[CRITICAL] Exit failed %d consecutive times for position %I64d! Retrying every 5 s.",
                           g_exitFailAttempts, openTicket);
               g_nextExitAttemptLocalMs = nowLocal + 5000;
            }
            else
            {
               PrintFormat("[EXIT RETRY] Close attempt %d failed. Retrying in 250 ms...", g_exitFailAttempts);
               g_nextExitAttemptLocalMs = nowLocal + 250;
            }
            g_state = STATE_EXIT_RETRY;
         }
      }
      return; // Never proceed to entry while position is open
   }

   // -------------------------------------------------------------
   // No open position: normal state machine & Entry Safety Checks
   // -------------------------------------------------------------
   string entryReason = "";
   if(!CheckEntrySafetyLimits(entryReason))
   {
      static ulong lastSafetyLog = 0;
      if(nowLocal - lastSafetyLog > 10000)
      {
         PrintFormat("[SAFETY PAUSE/STOP] %s", entryReason);
         lastSafetyLog = nowLocal;
      }
      if(g_circuitBreakerTripped || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR)
      {
         g_state = STATE_STOPPED;
      }
      return;
   }

   switch(g_state)
   {
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

      case STATE_CYCLE_SLEEP:
      {
         if(nowLocal >= g_nextCycleLocalMs)
         {
            g_state = STATE_IDLE;
         }
         break;
      }

      case STATE_STOPPED:
         break;

      default:
         g_state = STATE_IDLE;
         break;
   }
}
//+------------------------------------------------------------------+
