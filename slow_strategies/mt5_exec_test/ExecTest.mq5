//+------------------------------------------------------------------+
//|                                                     ExecTest.mq5 |
//|                                  MT5 Execution Quality Benchmark |
//|                                                                  |
//| Explicit State-Machine Execution Probe (Deterministic FSM)       |
//+------------------------------------------------------------------+
#property copyright "Execution Quality Benchmark"
#property link      ""
#property version   "2.10"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Hard Constants (Rule 4)
const double MAX_VOLUME = 0.01;

//--- FSM State Definitions (Section 1)
enum ENUM_PROBE_STATE
{
   STATE_IDLE,
   STATE_ENTRY_PENDING,
   STATE_IN_POSITION,
   STATE_EXIT_PENDING,
   STATE_EXIT_RETRY,
   STATE_ORPHAN_CLEANUP,
   STATE_HALTED
};

//--- Input Parameters
input group "=== Strategy Parameters ==="
input double   InpVolume            = 0.01;      // Trade Volume (lots, strictly 0.01)
input ulong    InpDeviation         = 20;        // Slippage Deviation Points
input int      InpHoldSeconds       = 60;        // Hold duration per round-trip (seconds)
input int      InpCycleIntervalMin  = 36;        // Cycle interval (minutes) between trades
input int      InpMaxOrdersPerDay   = 40;        // Maximum orders per day limit
input double   InpMaxDrawdownEUR    = 50.0;      // Equity drawdown stop (EUR)
input ulong    InpMagicNumber       = 20261009;  // Magic number
input int      InpPollIntervalMs    = 15;        // Polling interval in ms (10-20 ms)

input group "=== Fault Injection Suite (Demo Only) ==="
input int      InpInjectCloseReject = 0;         // Artificially simulate N rejected close attempts
input bool     InpInjectTimeout     = false;     // Artificially treat entry return as TIMEOUT (10004)

input group "=== Test Harness (Demo Only) ==="
input bool     InpResetState        = false;     // Wipe EXECTEST_* globals at init (skipped while an own position/hold is open)

//--- Global Variables Persistence Keys (Rule 1, Rule 9 / M11)
// Note: MT5 terminal GlobalVariables expire after ~4 weeks without access
#define GV_IN_FLIGHT          "EXECTEST_IN_FLIGHT"
#define GV_BASELINE_EQUITY    "EXECTEST_BASELINE_EQUITY"
#define GV_BASELINE_DATE_UTC  "EXECTEST_BASELINE_DATE_UTC"
#define GV_CIRCUIT_BREAKER    "EXECTEST_CIRCUIT_BREAKER"
#define GV_CONSEC_ERRORS      "EXECTEST_CONSEC_ERRORS"
#define GV_DAILY_ORDER_COUNT  "EXECTEST_DAILY_ORDER_COUNT"
#define GV_DAILY_DATE_UTC     "EXECTEST_DAILY_DATE_UTC"
#define GV_PROBE_STATE        "EXECTEST_PROBE_STATE"
#define GV_PREFIX             "EXECTEST_"
// Temporary (non-persisted) GV: one ExecTest instance per terminal. Different prefix so a state reset never removes it.
#define GV_INSTANCE_LOCK      "XTEST_INSTANCE_LOCK"

// Persistence keys for open position & hold metrics (Rule 1, H5)
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
#define GV_HOLD_DISPATCH_US   "EXECTEST_HOLD_DISPATCH_US"
#define GV_HOLD_RTT_US        "EXECTEST_HOLD_RTT_US"

//--- Fixed Capacity Ring Buffers & Queues (Rule 7: Zero-Allocation Hot Path)
#define TICK_RING_SIZE        64
#define QUEUE_TRADES_SIZE     128
#define QUEUE_ROUNDTRIPS_SIZE 64
#define QUEUE_SKIPS_SIZE      128

struct STickRing
{
   MqlTick items[TICK_RING_SIZE];
   int     head;
   int     count;
   long    last_tick_msc;
   ulong   local_first_seen_us;   // GetMicrosecondCount() when this tick was first observed (OnTick or OnTimer poll)
};

struct STradeEvent
{
   datetime timestamp_utc;
   uint     timestamp_ms;
   char     session[16];
   char     symbol[16];
   char     event_type[24];
   char     side[8];
   double   volume;
   double   req_price;
   double   fill_price;
   double   bid_before;
   double   ask_before;
   double   spread_before;
   uint     retcode;
   double   latency_ms;
   ulong    deviation;
   char     comment[64];
   long     tick_time_msc;
   double   tick_age_ms;
   int      poll_interval_ms;
   long     latency_dispatch_us;   // t_req - t_tick (us); -1 = no broker dispatch (fault injection / reconcile)
   long     latency_roundtrip_us;  // t_fill - t_req (us); -1 = no broker dispatch
};

struct SRoundtripEvent
{
   datetime timestamp_utc;
   uint     timestamp_ms;
   char     session[16];
   char     symbol[16];
   double   volume;
   double   req_buy;
   double   fill_buy;
   double   req_sell;
   double   fill_sell;
   double   snapshot_age_ms;
   double   slip_buy_send_pts;
   double   slip_sell_send_pts;
   double   mid_at_fill;
   double   exit_mid_at_fill;
   double   slip_buy_mid_fill_pts;
   double   slip_sell_mid_fill_pts;
   double   spread_entry_pts;
   double   spread_sell_pts;
   double   mid_entry;
   double   mid_exit;
   double   mid_move_during_hold_pts;
   double   fill_to_fill_cost_eur;
   double   fill_to_fill_cost_bps;
   double   mid_adjusted_cost_eur;
   double   mid_adjusted_cost_bps;
   double   model_cost_eur;
   double   cost_ratio;       // < 0 means N/A
   double   model_cost_1sp_eur;
   double   cost_ratio_1sp;   // < 0 means N/A
   double   raw_pnl_eur;
   double   hold_seconds;
   bool     pre_filter;
   bool     restart;
   double   exit_gate_waited_ms;
   bool     exit_zero_spread;
   bool     lookup_ok;
   double   entry_exec_slip_pts;
   double   exit_exec_slip_pts;
   double   entry_drift_pts;
   double   exit_drift_pts;
   double   t_tick_server;
   double   t_send_local_corrected;
   double   send_gap_ms;
   bool     age_uncorrected;
   long     entry_dispatch_us;
   long     entry_rtt_us;
   long     exit_dispatch_us;
   long     exit_rtt_us;
};

struct SSkipEvent
{
   datetime timestamp_utc;
   uint     timestamp_ms;
   char     session[16];
   char     symbol[16];
   char     reason[32];
   char     details[80];
};

// Global Queues
STradeEvent      g_queueTrades[QUEUE_TRADES_SIZE];
int              g_qTradesCount = 0;

SRoundtripEvent  g_queueRoundtrips[QUEUE_ROUNDTRIPS_SIZE];
int              g_qRoundtripsCount = 0;

SSkipEvent       g_queueSkips[QUEUE_SKIPS_SIZE];
int              g_qSkipsCount = 0;

// Per-symbol tick ring trackers (0=EURUSD, 1=USDJPY)
STickRing        g_tickRings[2];

//--- Global Objects & State
CTrade           m_trade;
CPositionInfo    m_position;
CSymbolInfo      m_symbols[2];

string           g_activeSymbols[2] = {"EURUSD", "USDJPY"};
int              g_symbolIndex = 0;
int              g_chartSymIdx = -1;         // index of _Symbol in g_activeSymbols, -1 if the chart is on another symbol

//--- Execution latency measurements of the most recent broker dispatch
long             g_lastDispatchUs = -1;      // t_req - t_tick of the most recent broker dispatch
long             g_lastRttUs = -1;           // t_fill - t_req of the most recent broker dispatch

//--- Static symbol / account parameters cached in OnInit (an account change re-runs OnInit)
double           g_symPoint[2];
double           g_symContract[2];
string           g_symProfitCcy[2];
ENUM_ORDER_TYPE_FILLING g_symFilling[2];
bool             g_isDemo = false;

//--- GlobalVariable durability: every GvSet/GvDel is flushed to disk unless inside a GvBegin/GvEnd batch
int              g_gvBatchDepth = 0;
bool             g_gvDirty = false;

//--- Monotonic UTC label anchor: GetMicrosecondCount() at the first observation of the current TimeGMT() second
datetime         g_labelSec = 0;
ulong            g_labelSecUs = 0;
uint             g_labelLastMs = 0;

//--- Deferred FSM transition log (transitions inside the dispatch window are printed after OrderSend returns)
bool             g_deferredLogPending = false;
ENUM_PROBE_STATE g_deferredFrom = STATE_IDLE;
ENUM_PROBE_STATE g_deferredTo = STATE_IDLE;
string           g_deferredReason = "";

const string     g_stateNames[] = {
   "STATE_IDLE",
   "STATE_ENTRY_PENDING",
   "STATE_IN_POSITION",
   "STATE_EXIT_PENDING",
   "STATE_EXIT_RETRY",
   "STATE_ORPHAN_CLEANUP",
   "STATE_HALTED"
};

ENUM_PROBE_STATE g_state = STATE_IDLE;
bool             g_in_flight = false; // Rule 1: Atomic in-flight lock

double           g_initialEquity = 0.0;
int              g_consecutiveErrors = 0;
int              g_dailyOrderCount = 0;
datetime         g_currentDayUtc = 0;
bool             g_circuitBreakerTripped = false;

string           g_currentSymbol = "";
ulong            g_currentPositionTicket = 0;
ulong            g_positionOpenLocalMs = 0;
datetime         g_positionOpenTimeServer = 0;
bool             g_isRestartTrip = false;

// Cached entry metrics
MqlTick          g_entrySnapshotTick;
double           g_entryReqPrice = 0.0;
double           g_entryFillPrice = 0.0;
double           g_entryLatencyMs = 0.0;
double           g_entryMidAtFill = 0.0;
double           g_entryExecSlipPts = 0.0;
double           g_entryDriftPts = 0.0;
double           g_entrySpreadPts = 0.0;
double           g_entryMid = 0.0;
double           g_entrySnapAgeMs = 0.0;
bool             g_entryLookupOk = true;
string           g_entrySession = "";
long             g_entryDispatchUs = -1;
long             g_entryRttUs = -1;

// Exit state tracking
ulong            g_exitGateStartLocalMs = 0;
double           g_exitGateWaitedMs = 0.0;
bool             g_exitZeroSpread = false;
int              g_exitFailAttempts = 0;
ulong            g_nextExitAttemptLocalMs = 0;

ulong            g_nextCycleLocalMs = 0;

// Fault injection tracking
int              g_injectedRejectsRemaining = 0;

// CSV Filenames in Common\Files
#define FILE_TRADES     "trades.csv"
#define FILE_ROUNDTRIPS "roundtrips.csv"
#define FILE_SKIPS      "skips.csv"

//+------------------------------------------------------------------+
//| Forward Declarations                                             |
//+------------------------------------------------------------------+
void SetProbeState(ENUM_PROBE_STATE newState, string reason, bool deferLog = false);
void SetInFlightLock(bool locked);
bool ValidateVolume(string symbol, double volume);
void FlushQueuesToDisk();
bool CheckEntrySafetyLimits(string &reason);
bool ExecuteEntry(string symbol, int symIdx);
bool ExecuteExit(string symbol, int symIdx, ulong posTicket, bool isOrphanCleanup);
bool ReconcileInFlight(string symbol, ulong expectedTicket, bool isExit);

//+------------------------------------------------------------------+
//| GlobalVariable durability                                        |
//| GlobalVariableSet only changes the terminal's in-memory table;   |
//| gvariables.dat is written on graceful shutdown. A forced kill    |
//| (taskkill /f) therefore lost every value written in the session. |
//| Every write now flushes, except inside a GvBegin/GvEnd batch,    |
//| which flushes once at GvEnd. The dispatch window (lock asserted  |
//| -> OrderSend returns) is one batch, so no disk write sits        |
//| between the decision tick and the order.                         |
//+------------------------------------------------------------------+
void GvBegin() { g_gvBatchDepth++; }

void GvEnd()
{
   if(g_gvBatchDepth > 0) g_gvBatchDepth--;
   if(g_gvBatchDepth == 0 && g_gvDirty)
   {
      GlobalVariablesFlush();
      g_gvDirty = false;
   }
}

void GvSet(const string name, double value)
{
   GlobalVariableSet(name, value);
   g_gvDirty = true;
   if(g_gvBatchDepth == 0)
   {
      GlobalVariablesFlush();
      g_gvDirty = false;
   }
}

void GvDel(const string name)
{
   if(!GlobalVariableDel(name)) return;
   g_gvDirty = true;
   if(g_gvBatchDepth == 0)
   {
      GlobalVariablesFlush();
      g_gvDirty = false;
   }
}

//+------------------------------------------------------------------+
//| FSM State Transition Logger (Section 1)                          |
//| deferLog=true is used inside the dispatch window: the transition |
//| is applied and persisted immediately, the Print is emitted by    |
//| EmitDeferredTransitionLog() after OrderSend returns.             |
//+------------------------------------------------------------------+
void SetProbeState(ENUM_PROBE_STATE newState, string reason, bool deferLog = false)
{
   if(g_state == newState) return;

   if(deferLog)
   {
      g_deferredLogPending = true;
      g_deferredFrom = g_state;
      g_deferredTo = newState;
      g_deferredReason = reason;
   }
   else
   {
      PrintFormat("[FSM TRANSITION] %s -> %s | Reason: %s",
                  g_stateNames[g_state], g_stateNames[newState], reason);
   }
   g_state = newState;
   GvSet(GV_PROBE_STATE, (double)newState);
}

void EmitDeferredTransitionLog()
{
   if(!g_deferredLogPending) return;
   PrintFormat("[FSM TRANSITION] %s -> %s | Reason: %s (logged after dispatch)",
               g_stateNames[g_deferredFrom], g_stateNames[g_deferredTo], g_deferredReason);
   g_deferredLogPending = false;
}

//+------------------------------------------------------------------+
//| Rule 1: Atomic In-Flight Lock & Persistence                      |
//+------------------------------------------------------------------+
void SetInFlightLock(bool locked)
{
   g_in_flight = locked;
   GvSet(GV_IN_FLIGHT, locked ? 1.0 : 0.0);
}

//+------------------------------------------------------------------+
//| Monotonic UTC label (human-readable timestamp column only)       |
//| Replaces TimeGMT() + GetTickCount64()%1000, whose millisecond    |
//| part was unrelated to the second and ran backwards in the CSVs.  |
//| The ms part is the GetMicrosecondCount() distance from the first |
//| observation of the current TimeGMT() second; OnTimer refreshes   |
//| the anchor every poll, so the label is accurate to about one     |
//| poll interval and never decreases. Latency deltas never use it.  |
//| Non-decreasing by construction: the second only moves forward    |
//| (a TimeGMT() step back, e.g. an NTP correction, is ignored and   |
//| the label holds at sec.999), and within a second ms is clamped   |
//| to the last value issued. Equal labels are possible (same ms).   |
//+------------------------------------------------------------------+
void UtcLabelAnchorTick()
{
   datetime nowSec = TimeGMT();
   if(nowSec > g_labelSec)
   {
      g_labelSec = nowSec;
      g_labelSecUs = GetMicrosecondCount();
      g_labelLastMs = 0;
   }
}

void UtcLabelNow(datetime &outSec, uint &outMs)
{
   UtcLabelAnchorTick();
   ulong ms = (GetMicrosecondCount() - g_labelSecUs) / 1000;
   if(ms > 999) ms = 999;
   if((uint)ms < g_labelLastMs) ms = g_labelLastMs;
   g_labelLastMs = (uint)ms;
   outSec = g_labelSec;
   outMs = (uint)ms;
}

string UsStr(long us)
{
   return (us < 0) ? "NaN" : IntegerToString(us);
}

void LogDispatch(string symbol, string side)
{
   PrintFormat("[ORDER SENT] %s %s retcode=%u order=%I64u deal=%I64u price=%f dispatch_us=%s rtt_us=%s",
               symbol, side, m_trade.ResultRetcode(), m_trade.ResultOrder(), m_trade.ResultDeal(), m_trade.ResultPrice(),
               UsStr(g_lastDispatchUs), UsStr(g_lastRttUs));
}

//+------------------------------------------------------------------+
//| Rule 4: Hard Volume Guard                                        |
//+------------------------------------------------------------------+
bool ValidateVolume(string symbol, double volume)
{
   if(volume > MAX_VOLUME || volume <= 0.0)
      return false;

   double vMin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vMax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double vStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(volume < vMin || volume > vMax)
      return false;

   if(vStep > 0.0)
   {
      double steps = (volume - vMin) / vStep;
      if(MathAbs(steps - MathRound(steps)) > 0.00001)
         return false;
   }

   return true;
}

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
   int ci = (symbol == g_activeSymbols[0]) ? 0 : ((symbol == g_activeSymbols[1]) ? 1 : -1);
   string profitCurr = (ci >= 0) ? g_symProfitCcy[ci] : SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
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
//| Rule 7: Zero-Allocation Hot Path - Tick Ring Buffer Push         |
//+------------------------------------------------------------------+
void PushTickRing(int idx, const MqlTick &tick, ulong seenUs)
{
   if((long)tick.time_msc != g_tickRings[idx].last_tick_msc)
   {
      g_tickRings[idx].last_tick_msc = (long)tick.time_msc;
      g_tickRings[idx].local_first_seen_us = seenUs;
   }
   g_tickRings[idx].items[g_tickRings[idx].head] = tick;
   g_tickRings[idx].head = (g_tickRings[idx].head + 1) % TICK_RING_SIZE;
   if(g_tickRings[idx].count < TICK_RING_SIZE) g_tickRings[idx].count++;
}

//+------------------------------------------------------------------+
//| Helper: Get Latest Tick and Tick Age in ms                       |
//+------------------------------------------------------------------+
bool GetLatestTick(int idx, MqlTick &outTick, double &outAgeMs)
{
   if(g_tickRings[idx].count == 0)
   {
      outAgeMs = 999999.0;
      return false;
   }
   int lastIdx = (g_tickRings[idx].head - 1 + TICK_RING_SIZE) % TICK_RING_SIZE;
   outTick = g_tickRings[idx].items[lastIdx];
   if(g_tickRings[idx].local_first_seen_us == 0)
      outAgeMs = 999999.0;
   else
      outAgeMs = (double)(GetMicrosecondCount() - g_tickRings[idx].local_first_seen_us) / 1000.0;
   return true;
}

ulong TickFirstSeenUs(int idx)
{
   return g_tickRings[idx].local_first_seen_us;
}

//+------------------------------------------------------------------+
//| Rule 7: Zero-Allocation In-Memory Log Queue Push Functions       |
//+------------------------------------------------------------------+
void QueueSkip(string symbol, string reason, string details)
{
   if(g_qSkipsCount >= QUEUE_SKIPS_SIZE)
   {
      Print("[WARN] Skips queue full. Overwriting oldest entry.");
      g_qSkipsCount = QUEUE_SKIPS_SIZE - 1;
   }

   datetime nowUtc;
   uint ms;
   UtcLabelNow(nowUtc, ms);
   string sess = GetCurrentSession(nowUtc);

   g_queueSkips[g_qSkipsCount].timestamp_utc = nowUtc;
   g_queueSkips[g_qSkipsCount].timestamp_ms  = ms;
   StringToCharArray(sess, g_queueSkips[g_qSkipsCount].session);
   StringToCharArray(symbol, g_queueSkips[g_qSkipsCount].symbol);
   StringToCharArray(reason, g_queueSkips[g_qSkipsCount].reason);
   StringToCharArray(details, g_queueSkips[g_qSkipsCount].details);
   g_qSkipsCount++;

   PrintFormat("[SKIP LOGGED] %s | %s | Reason: %s | %s", symbol, sess, reason, details);
}

void QueueTradeEvent(string symbol, string event_type, string side, double volume, double req_price,
                     double fill_price, double bid_b, double ask_b, double spread_b,
                     uint retcode, double latency_ms, ulong deviation, string comment,
                     long tick_time_msc, double tick_age_ms, int poll_interval_ms,
                     long dispatch_us, long rtt_us)
{
   if(g_qTradesCount >= QUEUE_TRADES_SIZE)
   {
      Print("[WARN] Trades queue full. Overwriting oldest entry.");
      g_qTradesCount = QUEUE_TRADES_SIZE - 1;
   }

   datetime nowUtc;
   uint ms;
   UtcLabelNow(nowUtc, ms);
   string sess = GetCurrentSession(nowUtc);

   g_queueTrades[g_qTradesCount].timestamp_utc   = nowUtc;
   g_queueTrades[g_qTradesCount].timestamp_ms    = ms;
   StringToCharArray(sess, g_queueTrades[g_qTradesCount].session);
   StringToCharArray(symbol, g_queueTrades[g_qTradesCount].symbol);
   StringToCharArray(event_type, g_queueTrades[g_qTradesCount].event_type);
   StringToCharArray(side, g_queueTrades[g_qTradesCount].side);
   g_queueTrades[g_qTradesCount].volume          = volume;
   g_queueTrades[g_qTradesCount].req_price       = req_price;
   g_queueTrades[g_qTradesCount].fill_price      = fill_price;
   g_queueTrades[g_qTradesCount].bid_before      = bid_b;
   g_queueTrades[g_qTradesCount].ask_before      = ask_b;
   g_queueTrades[g_qTradesCount].spread_before   = spread_b;
   g_queueTrades[g_qTradesCount].retcode         = retcode;
   g_queueTrades[g_qTradesCount].latency_ms      = latency_ms;
   g_queueTrades[g_qTradesCount].deviation       = deviation;
   StringToCharArray(comment, g_queueTrades[g_qTradesCount].comment);
   g_queueTrades[g_qTradesCount].tick_time_msc   = tick_time_msc;
   g_queueTrades[g_qTradesCount].tick_age_ms     = tick_age_ms;
   g_queueTrades[g_qTradesCount].poll_interval_ms= poll_interval_ms;
   g_queueTrades[g_qTradesCount].latency_dispatch_us  = dispatch_us;
   g_queueTrades[g_qTradesCount].latency_roundtrip_us = rtt_us;
   g_qTradesCount++;

   if(event_type == "trade")
   {
      g_dailyOrderCount++;
      GvSet(GV_DAILY_ORDER_COUNT, (double)g_dailyOrderCount);
   }
}

void QueueRoundtrip(string symbol, double volume, double req_buy, double fill_buy,
                    double req_sell, double fill_sell, double snapshot_age_ms,
                    double slip_buy_send_pts, double slip_sell_send_pts,
                    double mid_at_fill, double exit_mid_at_fill,
                    double slip_buy_mid_fill_pts, double slip_sell_mid_fill_pts,
                    double spread_entry_pts, double spread_sell_pts,
                    double mid_entry, double mid_exit, double mid_move_pts,
                    double f2f_cost_eur, double f2f_cost_bps,
                    double midadj_cost_eur, double midadj_cost_bps,
                    double model_cost_eur, double cost_ratio,
                    double model_cost_1sp_eur, double cost_ratio_1sp,
                    double raw_pnl_eur, double hold_sec, bool pre_filter, bool restart,
                    double exit_gate_waited_ms, bool exit_zero_spread, bool lookup_ok,
                    double entry_exec_slip_pts, double exit_exec_slip_pts,
                    double entry_drift_pts, double exit_drift_pts,
                    double t_tick_server, double t_send_local_corrected,
                    double send_gap_ms, bool age_uncorrected,
                    long entry_dispatch_us, long entry_rtt_us, long exit_dispatch_us, long exit_rtt_us)
{
   if(g_qRoundtripsCount >= QUEUE_ROUNDTRIPS_SIZE)
   {
      Print("[WARN] Roundtrips queue full. Overwriting oldest entry.");
      g_qRoundtripsCount = QUEUE_ROUNDTRIPS_SIZE - 1;
   }

   datetime nowUtc;
   uint ms;
   UtcLabelNow(nowUtc, ms);
   string sess = GetCurrentSession(nowUtc);

   g_queueRoundtrips[g_qRoundtripsCount].timestamp_utc            = nowUtc;
   g_queueRoundtrips[g_qRoundtripsCount].timestamp_ms             = ms;
   StringToCharArray(sess, g_queueRoundtrips[g_qRoundtripsCount].session);
   StringToCharArray(symbol, g_queueRoundtrips[g_qRoundtripsCount].symbol);
   g_queueRoundtrips[g_qRoundtripsCount].volume                   = volume;
   g_queueRoundtrips[g_qRoundtripsCount].req_buy                  = req_buy;
   g_queueRoundtrips[g_qRoundtripsCount].fill_buy                 = fill_buy;
   g_queueRoundtrips[g_qRoundtripsCount].req_sell                 = req_sell;
   g_queueRoundtrips[g_qRoundtripsCount].fill_sell                = fill_sell;
   g_queueRoundtrips[g_qRoundtripsCount].snapshot_age_ms          = snapshot_age_ms;
   g_queueRoundtrips[g_qRoundtripsCount].slip_buy_send_pts        = slip_buy_send_pts;
   g_queueRoundtrips[g_qRoundtripsCount].slip_sell_send_pts       = slip_sell_send_pts;
   g_queueRoundtrips[g_qRoundtripsCount].mid_at_fill              = mid_at_fill;
   g_queueRoundtrips[g_qRoundtripsCount].exit_mid_at_fill         = exit_mid_at_fill;
   g_queueRoundtrips[g_qRoundtripsCount].slip_buy_mid_fill_pts    = slip_buy_mid_fill_pts;
   g_queueRoundtrips[g_qRoundtripsCount].slip_sell_mid_fill_pts   = slip_sell_mid_fill_pts;
   g_queueRoundtrips[g_qRoundtripsCount].spread_entry_pts         = spread_entry_pts;
   g_queueRoundtrips[g_qRoundtripsCount].spread_sell_pts          = spread_sell_pts;
   g_queueRoundtrips[g_qRoundtripsCount].mid_entry                = mid_entry;
   g_queueRoundtrips[g_qRoundtripsCount].mid_exit                 = mid_exit;
   g_queueRoundtrips[g_qRoundtripsCount].mid_move_during_hold_pts = mid_move_pts;
   g_queueRoundtrips[g_qRoundtripsCount].fill_to_fill_cost_eur    = f2f_cost_eur;
   g_queueRoundtrips[g_qRoundtripsCount].fill_to_fill_cost_bps    = f2f_cost_bps;
   g_queueRoundtrips[g_qRoundtripsCount].mid_adjusted_cost_eur    = midadj_cost_eur;
   g_queueRoundtrips[g_qRoundtripsCount].mid_adjusted_cost_bps    = midadj_cost_bps;
   g_queueRoundtrips[g_qRoundtripsCount].model_cost_eur           = model_cost_eur;
   g_queueRoundtrips[g_qRoundtripsCount].cost_ratio               = cost_ratio;
   g_queueRoundtrips[g_qRoundtripsCount].model_cost_1sp_eur       = model_cost_1sp_eur;
   g_queueRoundtrips[g_qRoundtripsCount].cost_ratio_1sp           = cost_ratio_1sp;
   g_queueRoundtrips[g_qRoundtripsCount].raw_pnl_eur              = raw_pnl_eur;
   g_queueRoundtrips[g_qRoundtripsCount].hold_seconds             = hold_sec;
   g_queueRoundtrips[g_qRoundtripsCount].pre_filter               = pre_filter;
   g_queueRoundtrips[g_qRoundtripsCount].restart                  = restart;
   g_queueRoundtrips[g_qRoundtripsCount].exit_gate_waited_ms      = exit_gate_waited_ms;
   g_queueRoundtrips[g_qRoundtripsCount].exit_zero_spread         = exit_zero_spread;
   g_queueRoundtrips[g_qRoundtripsCount].lookup_ok                = lookup_ok;
   g_queueRoundtrips[g_qRoundtripsCount].entry_exec_slip_pts      = entry_exec_slip_pts;
   g_queueRoundtrips[g_qRoundtripsCount].exit_exec_slip_pts       = exit_exec_slip_pts;
   g_queueRoundtrips[g_qRoundtripsCount].entry_drift_pts          = entry_drift_pts;
   g_queueRoundtrips[g_qRoundtripsCount].exit_drift_pts           = exit_drift_pts;
   g_queueRoundtrips[g_qRoundtripsCount].t_tick_server            = t_tick_server;
   g_queueRoundtrips[g_qRoundtripsCount].t_send_local_corrected   = t_send_local_corrected;
   g_queueRoundtrips[g_qRoundtripsCount].send_gap_ms              = send_gap_ms;
   g_queueRoundtrips[g_qRoundtripsCount].age_uncorrected          = age_uncorrected;
   g_queueRoundtrips[g_qRoundtripsCount].entry_dispatch_us        = entry_dispatch_us;
   g_queueRoundtrips[g_qRoundtripsCount].entry_rtt_us             = entry_rtt_us;
   g_queueRoundtrips[g_qRoundtripsCount].exit_dispatch_us         = exit_dispatch_us;
   g_queueRoundtrips[g_qRoundtripsCount].exit_rtt_us              = exit_rtt_us;
   g_qRoundtripsCount++;
}

//+------------------------------------------------------------------+
//| Rule 7: Flush Log Queues to CSV Files in STATE_IDLE Only         |
//+------------------------------------------------------------------+
void FlushQueuesToDisk()
{
   // Flush Skips
   if(g_qSkipsCount > 0)
   {
      int h = FileOpen(FILE_SKIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < g_qSkipsCount; i++)
         {
            string tsStr = FormatUtcTime(g_queueSkips[i].timestamp_utc, g_queueSkips[i].timestamp_ms);
            string line = StringFormat("%s,%s,%s,%s,%s,mql5\r\n",
                                       tsStr,
                                       CharArrayToString(g_queueSkips[i].session),
                                       CharArrayToString(g_queueSkips[i].symbol),
                                       CharArrayToString(g_queueSkips[i].reason),
                                       SanitizeComment(CharArrayToString(g_queueSkips[i].details)));
            FileWriteString(h, line);
         }
         FileClose(h);
         g_qSkipsCount = 0;
      }
      else
      {
         PrintFormat("[CSV FLUSH ERROR] FileOpen %s failed (error %d)", FILE_SKIPS, GetLastError());
      }
   }

   // Flush Trades
   if(g_qTradesCount > 0)
   {
      int h = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < g_qTradesCount; i++)
         {
            string tsStr = FormatUtcTime(g_queueTrades[i].timestamp_utc, g_queueTrades[i].timestamp_ms);
            string line = StringFormat("%s,%s,%s,%s,%s,%.2f,%f,%f,%f,%f,%f,%u,%.1f,%I64u,%s,%I64d,%.1f,local_first_seen,%d,mql5,%s,%s\r\n",
                                       tsStr,
                                       CharArrayToString(g_queueTrades[i].session),
                                       CharArrayToString(g_queueTrades[i].symbol),
                                       CharArrayToString(g_queueTrades[i].event_type),
                                       CharArrayToString(g_queueTrades[i].side),
                                       g_queueTrades[i].volume,
                                       g_queueTrades[i].req_price,
                                       g_queueTrades[i].fill_price,
                                       g_queueTrades[i].bid_before,
                                       g_queueTrades[i].ask_before,
                                       g_queueTrades[i].spread_before,
                                       g_queueTrades[i].retcode,
                                       g_queueTrades[i].latency_ms,
                                       g_queueTrades[i].deviation,
                                       SanitizeComment(CharArrayToString(g_queueTrades[i].comment)),
                                       g_queueTrades[i].tick_time_msc,
                                       g_queueTrades[i].tick_age_ms,
                                       g_queueTrades[i].poll_interval_ms,
                                       UsStr(g_queueTrades[i].latency_dispatch_us),
                                       UsStr(g_queueTrades[i].latency_roundtrip_us));
            FileWriteString(h, line);
         }
         FileClose(h);
         g_qTradesCount = 0;
      }
      else
      {
         PrintFormat("[CSV FLUSH ERROR] FileOpen %s failed (error %d)", FILE_TRADES, GetLastError());
      }
   }

   // Flush Roundtrips
   if(g_qRoundtripsCount > 0)
   {
      int h = FileOpen(FILE_ROUNDTRIPS, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         for(int i = 0; i < g_qRoundtripsCount; i++)
         {
            string tsStr = FormatUtcTime(g_queueRoundtrips[i].timestamp_utc, g_queueRoundtrips[i].timestamp_ms);
            string strExecSlipEntry = g_queueRoundtrips[i].lookup_ok ? StringFormat("%.2f", g_queueRoundtrips[i].entry_exec_slip_pts) : "NaN";
            string strExecSlipExit  = g_queueRoundtrips[i].lookup_ok ? StringFormat("%.2f", g_queueRoundtrips[i].exit_exec_slip_pts)  : "NaN";
            string strRatio         = (g_queueRoundtrips[i].cost_ratio >= 0.0) ? StringFormat("%.2f", g_queueRoundtrips[i].cost_ratio) : "N/A";
            string strRatio1sp      = (g_queueRoundtrips[i].cost_ratio_1sp >= 0.0) ? StringFormat("%.2f", g_queueRoundtrips[i].cost_ratio_1sp) : "N/A";

            string line = StringFormat("%s,%s,%s,%.2f,%f,%f,%f,%f,%.1f,%.2f,%.2f,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.5f,%.5f,%.2f,%.4f,%.2f,%.4f,%.2f,%.4f,%s,%.4f,%s,%.4f,%.1f,%s,%s,%.1f,%s,%s,%s,%s,%.2f,%.2f,%.1f,%.1f,%.1f,%s,local_first_seen,mql5,%s,%s,%s,%s\r\n",
                                       tsStr,
                                       CharArrayToString(g_queueRoundtrips[i].session),
                                       CharArrayToString(g_queueRoundtrips[i].symbol),
                                       g_queueRoundtrips[i].volume,
                                       g_queueRoundtrips[i].req_buy,
                                       g_queueRoundtrips[i].fill_buy,
                                       g_queueRoundtrips[i].req_sell,
                                       g_queueRoundtrips[i].fill_sell,
                                       g_queueRoundtrips[i].snapshot_age_ms,
                                       g_queueRoundtrips[i].slip_buy_send_pts,
                                       g_queueRoundtrips[i].slip_sell_send_pts,
                                       g_queueRoundtrips[i].mid_at_fill,
                                       g_queueRoundtrips[i].exit_mid_at_fill,
                                       g_queueRoundtrips[i].slip_buy_mid_fill_pts,
                                       g_queueRoundtrips[i].slip_sell_mid_fill_pts,
                                       g_queueRoundtrips[i].spread_entry_pts,
                                       g_queueRoundtrips[i].spread_sell_pts,
                                       g_queueRoundtrips[i].mid_entry,
                                       g_queueRoundtrips[i].mid_exit,
                                       g_queueRoundtrips[i].mid_move_during_hold_pts,
                                       g_queueRoundtrips[i].fill_to_fill_cost_eur,
                                       g_queueRoundtrips[i].fill_to_fill_cost_bps,
                                       g_queueRoundtrips[i].mid_adjusted_cost_eur,
                                       g_queueRoundtrips[i].mid_adjusted_cost_bps,
                                       g_queueRoundtrips[i].model_cost_eur,
                                       strRatio,
                                       g_queueRoundtrips[i].model_cost_1sp_eur,
                                       strRatio1sp,
                                       g_queueRoundtrips[i].raw_pnl_eur,
                                       g_queueRoundtrips[i].hold_seconds,
                                       (g_queueRoundtrips[i].pre_filter ? "True" : "False"),
                                       (g_queueRoundtrips[i].restart ? "True" : "False"),
                                       g_queueRoundtrips[i].exit_gate_waited_ms,
                                       (g_queueRoundtrips[i].exit_zero_spread ? "True" : "False"),
                                       (g_queueRoundtrips[i].lookup_ok ? "True" : "False"),
                                       strExecSlipEntry,
                                       strExecSlipExit,
                                       g_queueRoundtrips[i].entry_drift_pts,
                                       g_queueRoundtrips[i].exit_drift_pts,
                                       g_queueRoundtrips[i].t_tick_server,
                                       g_queueRoundtrips[i].t_send_local_corrected,
                                       g_queueRoundtrips[i].send_gap_ms,
                                       (g_queueRoundtrips[i].age_uncorrected ? "True" : "False"),
                                       UsStr(g_queueRoundtrips[i].entry_dispatch_us),
                                       UsStr(g_queueRoundtrips[i].entry_rtt_us),
                                       UsStr(g_queueRoundtrips[i].exit_dispatch_us),
                                       UsStr(g_queueRoundtrips[i].exit_rtt_us));
            FileWriteString(h, line);
         }
         FileClose(h);
         g_qRoundtripsCount = 0;
      }
      else
      {
         PrintFormat("[CSV FLUSH ERROR] FileOpen %s failed (error %d)", FILE_ROUNDTRIPS, GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Initialize CSV files in FILE_COMMON                              |
//+------------------------------------------------------------------+
#define HDR_TRADES     "timestamp_utc,session,symbol,event_type,side,volume,request_price,fill_price,bid_before,ask_before,spread_before,retcode,latency_ms,deviation,comment,tick_time_msc,tick_age_ms,tick_age_method,poll_interval_ms,engine,latency_dispatch_us,latency_roundtrip_us"
#define HDR_ROUNDTRIPS "timestamp_utc,session,symbol,volume,entry_request_price,entry_fill_price,exit_request_price,exit_fill_price,snapshot_age_ms,entry_slippage_pts,exit_slippage_pts,mid_at_fill,exit_mid_at_fill,entry_slippage_mid_fill_pts,exit_slippage_mid_fill_pts,spread_at_entry_pts,exit_spread_pts,mid_entry,mid_exit,mid_move_during_hold_pts,fill_to_fill_cost_eur,fill_to_fill_cost_bps,mid_adjusted_cost_eur,mid_adjusted_cost_bps,model_cost_eur,cost_ratio,model_cost_1sp_eur,cost_ratio_1sp,raw_pnl_eur,hold_seconds,pre_filter,restart,exit_gate_waited_ms,exit_zero_spread,lookup_ok,entry_exec_slip_pts,exit_exec_slip_pts,entry_drift_pts,exit_drift_pts,t_tick_server,t_send_local_corrected,send_gap_ms,age_uncorrected,tick_age_method,engine,entry_dispatch_us,entry_rtt_us,exit_dispatch_us,exit_rtt_us"
#define HDR_SKIPS      "timestamp_utc,session,symbol,reason,details,engine"

//+------------------------------------------------------------------+
//| Ensure a Common\Files CSV exists with exactly this header. A file|
//| with an older header is renamed <name>_schema_<utc>.csv instead  |
//| of being appended to with a different column count.              |
//+------------------------------------------------------------------+
void EnsureCsvHeader(string fileName, string header)
{
   if(FileIsExist(fileName, FILE_COMMON))
   {
      string existing = "";
      int hr = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(hr != INVALID_HANDLE)
      {
         if(!FileIsEnding(hr)) existing = FileReadString(hr);
         FileClose(hr);
      }
      if(existing == header) return;

      MqlDateTime mdt;
      TimeToStruct(TimeGMT(), mdt);
      string base = StringSubstr(fileName, 0, StringLen(fileName) - 4);
      string rotated = StringFormat("%s_schema_%04d%02d%02d_%02d%02d%02d.csv", base,
                                    mdt.year, mdt.mon, mdt.day, mdt.hour, mdt.min, mdt.sec);
      if(FileMove(fileName, FILE_COMMON, rotated, FILE_COMMON))
         PrintFormat("[CSV SCHEMA] %s had a different header; rotated to %s", fileName, rotated);
      else
      {
         PrintFormat("[CSV SCHEMA ERROR] %s header mismatch and rotation failed (error %d); not writing a second schema",
                     fileName, GetLastError());
         return;
      }
   }

   int h = FileOpen(fileName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, header + "\r\n");
      FileClose(h);
   }
}

void InitCsvFiles()
{
   EnsureCsvHeader(FILE_TRADES, HDR_TRADES);
   EnsureCsvHeader(FILE_ROUNDTRIPS, HDR_ROUNDTRIPS);
   EnsureCsvHeader(FILE_SKIPS, HDR_SKIPS);
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

   GvBegin();

   // In-flight lock
   if(GlobalVariableCheck(GV_IN_FLIGHT))
      g_in_flight = (GlobalVariableGet(GV_IN_FLIGHT) > 0.5);
   else
   {
      g_in_flight = false;
      GvSet(GV_IN_FLIGHT, 0.0);
   }

   // Daily baseline equity (M7)
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
      GvSet(GV_BASELINE_DATE_UTC, (double)todayStart);
      GvSet(GV_BASELINE_EQUITY, g_initialEquity);
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
      GvSet(GV_CIRCUIT_BREAKER, 0.0);
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
      GvSet(GV_CONSEC_ERRORS, 0.0);
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
      GvSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
      GvSet(GV_DAILY_ORDER_COUNT, 0.0);
      Print("[PERSISTENCE] Initialized new daily order count for today: 0");
   }

   GvEnd();
}

//+------------------------------------------------------------------+
//| Persistence: Save Open Position & Hold Metrics                   |
//+------------------------------------------------------------------+
void SaveHoldState(ulong ticket, int symIdx, ulong openLocalMs, datetime openServerTime)
{
   GvBegin();
   GvSet(GV_HOLD_TICKET, (double)ticket);
   GvSet(GV_HOLD_SYM_IDX, (double)symIdx);
   GvSet(GV_HOLD_START_TIME, (double)openServerTime);
   GvSet(GV_HOLD_LOCAL_MS, (double)openLocalMs);
   GvSet(GV_HOLD_REQ_PRICE, g_entryReqPrice);
   GvSet(GV_HOLD_FILL_PRICE, g_entryFillPrice);
   GvSet(GV_HOLD_LATENCY_MS, g_entryLatencyMs);
   GvSet(GV_HOLD_SNAP_AGE_MS, g_entrySnapAgeMs);
   GvSet(GV_HOLD_SPREAD_PTS, g_entrySpreadPts);
   GvSet(GV_HOLD_MID_ENTRY, g_entryMid);
   GvSet(GV_HOLD_MID_FILL, g_entryMidAtFill);
   GvSet(GV_HOLD_EXEC_SLIP, g_entryExecSlipPts);
   GvSet(GV_HOLD_DRIFT_PTS, g_entryDriftPts);
   GvSet(GV_HOLD_LOOKUP_OK, g_entryLookupOk ? 1.0 : 0.0);
   GvSet(GV_HOLD_TICK_MSC, (double)g_entrySnapshotTick.time_msc);
   GvSet(GV_HOLD_DISPATCH_US, (double)g_entryDispatchUs);
   GvSet(GV_HOLD_RTT_US, (double)g_entryRttUs);
   GvEnd();   // one GlobalVariablesFlush(): the hold ticket survives taskkill /f from here on
}

void ClearHoldState()
{
   GvBegin();
   GvDel(GV_HOLD_TICKET);
   GvDel(GV_HOLD_SYM_IDX);
   GvDel(GV_HOLD_START_TIME);
   GvDel(GV_HOLD_LOCAL_MS);
   GvDel(GV_HOLD_REQ_PRICE);
   GvDel(GV_HOLD_FILL_PRICE);
   GvDel(GV_HOLD_LATENCY_MS);
   GvDel(GV_HOLD_SNAP_AGE_MS);
   GvDel(GV_HOLD_SPREAD_PTS);
   GvDel(GV_HOLD_MID_ENTRY);
   GvDel(GV_HOLD_MID_FILL);
   GvDel(GV_HOLD_EXEC_SLIP);
   GvDel(GV_HOLD_DRIFT_PTS);
   GvDel(GV_HOLD_LOOKUP_OK);
   GvDel(GV_HOLD_TICK_MSC);
   GvDel(GV_HOLD_DISPATCH_US);
   GvDel(GV_HOLD_RTT_US);
   GvEnd();
}

//+------------------------------------------------------------------+
//| Rule 2: Entry Limits Check (GATES ENTRY ATTEMPTS ONLY)           |
//+------------------------------------------------------------------+
bool CheckEntrySafetyLimits(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      reason = "Terminal disconnected from broker server";
      return false;
   }

   // Cached in OnInit; an account switch triggers OnDeinit(REASON_ACCOUNT) + OnInit, which re-validates
   if(!g_isDemo)
   {
      reason = "Account is NOT DEMO (Aborting immediately)";
      return false;
   }

   if(g_circuitBreakerTripped)
   {
      reason = "Circuit breaker is active (3 consecutive errors reached)";
      return false;
   }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_initialEquity - currentEquity) >= InpMaxDrawdownEUR)
   {
      reason = StringFormat("Equity drop %.2f EUR >= %.2f EUR stop (Baseline: %.2f, Current: %.2f)",
                            (g_initialEquity - currentEquity), InpMaxDrawdownEUR, g_initialEquity, currentEquity);
      return false;
   }

   if(g_consecutiveErrors >= 3)
   {
      g_circuitBreakerTripped = true;
      GvSet(GV_CIRCUIT_BREAKER, 1.0);
      reason = StringFormat("Circuit breaker tripped: %d consecutive errors", g_consecutiveErrors);
      return false;
   }

   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   if(g_currentDayUtc != todayStart)
   {
      g_currentDayUtc = todayStart;
      g_dailyOrderCount = 0;
      GvSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
      GvSet(GV_DAILY_ORDER_COUNT, 0.0);
   }

   if(g_dailyOrderCount >= InpMaxOrdersPerDay)
   {
      reason = StringFormat("Daily limit reached: %d/%d orders today",
                            g_dailyOrderCount, InpMaxOrdersPerDay);
      return false;
   }

   // Rule 5: Strict Mutual Exclusion (PositionsTotal == 0 across account & foreign positions)
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
         reason = StringFormat("Foreign position exists on account (%d foreign). Gating entry.", foreignCount);
      else
         reason = StringFormat("Position already open (%d own). Gating entry.", ownCount);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Rule 3: Indeterminate Retcode Reconciliation                     |
//+------------------------------------------------------------------+
bool ReconcileInFlight(string symbol, ulong expectedTicket, bool isExit)
{
   PrintFormat("[RECONCILIATION] Initiating deep bounded reconciliation for %s (Ticket: %I64d, isExit: %s)...",
               symbol, expectedTicket, (isExit ? "true" : "false"));

   // Multi-pass bounded polling window across ~1000 ms (3 passes x 330 ms)
   ulong foundPosTicket = 0;
   for(int pass = 0; pass < 3; pass++)
   {
      foundPosTicket = 0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber && m_position.Symbol() == symbol)
         {
            foundPosTicket = m_position.Ticket();
            break;
         }
      }

      if(!isExit && foundPosTicket > 0)
         break;
      if(isExit && foundPosTicket == 0)
         break;

      Sleep(330);
   }

   int symIdx = (symbol == g_activeSymbols[0]) ? 0 : 1;
   double pt = g_symPoint[symIdx];
   double contractSize = g_symContract[symIdx];
   double fxToEur = GetFxToEur(symbol);

   if(!isExit)
   {
      // Entry reconciliation
      if(foundPosTicket > 0)
      {
         PrintFormat("[RECONCILIATION RESULT] Entry confirmed filled! Position ticket: %I64d", foundPosTicket);
         g_currentPositionTicket = foundPosTicket;
         g_entryFillPrice = m_position.PriceOpen();
         g_positionOpenLocalMs = GetTickCount64();
         g_positionOpenTimeServer = TimeCurrent();
         g_isRestartTrip = false;
         g_consecutiveErrors = 0;
         GvSet(GV_CONSEC_ERRORS, 0.0);

         // Fetch deal from history for exact fill details & slippage
         ulong dealTicket = 0;
         datetime fromTime = TimeCurrent() - 60;
         if(HistorySelect(fromTime, TimeCurrent()))
         {
            int dTotal = HistoryDealsTotal();
            for(int i = dTotal - 1; i >= 0; i--)
            {
               ulong dt = HistoryDealGetTicket(i);
               if(dt > 0 && HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber &&
                  HistoryDealGetString(dt, DEAL_SYMBOL) == symbol &&
                  HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_IN)
               {
                  dealTicket = dt;
                  break;
               }
            }
         }

         g_entryExecSlipPts = 0.0;
         g_entryLookupOk = false;
         g_entryMidAtFill = g_entryMid;

         if(dealTicket > 0 && HistoryDealSelect(dealTicket))
         {
            g_entryFillPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
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
                     g_entryExecSlipPts = (pt > 0) ? ((g_entryFillPrice - prevAsk) / pt) : 0.0;
                     if(prevBid > 0 && prevAsk > 0)
                        g_entryMidAtFill = (prevBid + prevAsk) / 2.0;
                     g_entryLookupOk = true;
                     break;
                  }
               }
            }
         }

         g_entryDriftPts = (pt > 0) ? ((g_entryFillPrice - g_entryReqPrice) / pt) : 0.0;

         SaveHoldState(g_currentPositionTicket, symIdx, g_positionOpenLocalMs, g_positionOpenTimeServer);

         QueueTradeEvent(symbol, "trade", "BUY", InpVolume, g_entryReqPrice, g_entryFillPrice,
                         g_entrySnapshotTick.bid, g_entrySnapshotTick.ask,
                         (g_entrySnapshotTick.ask - g_entrySnapshotTick.bid),
                         TRADE_RETCODE_DONE, g_entryLatencyMs, InpDeviation, "reconcile_entry_fill",
                         (long)g_entrySnapshotTick.time_msc, g_entrySnapAgeMs, InpPollIntervalMs,
                         g_entryDispatchUs, g_entryRttUs);

         SetInFlightLock(false);
         SetProbeState(STATE_IN_POSITION, "Entry reconciled as filled");
         return true;
      }
      else
      {
         // Check history orders to confirm rejection or cancellation
         datetime fromTime = TimeCurrent() - 60;
         HistorySelect(fromTime, TimeCurrent());
         int totalHist = HistoryOrdersTotal();
         bool rejectedInHistory = false;
         for(int i = totalHist - 1; i >= 0; i--)
         {
            ulong oTicket = HistoryOrderGetTicket(i);
            if(oTicket > 0 && HistoryOrderGetInteger(oTicket, ORDER_MAGIC) == InpMagicNumber &&
               HistoryOrderGetString(oTicket, ORDER_SYMBOL) == symbol)
            {
               long oState = HistoryOrderGetInteger(oTicket, ORDER_STATE);
               if(oState == ORDER_STATE_CANCELED || oState == ORDER_STATE_REJECTED || oState == ORDER_STATE_EXPIRED)
               {
                  rejectedInHistory = true;
                  break;
               }
            }
         }

         PrintFormat("[RECONCILIATION RESULT] Entry confirmed NOT filled (Rejected in history: %s)",
                     (rejectedInHistory ? "true" : "false"));
         SetInFlightLock(false);
         SetProbeState(STATE_IDLE, "Entry reconciled as unfulfilled");
         return false;
      }
   }
   else
   {
      // Exit reconciliation
      if(foundPosTicket == 0)
      {
         PrintFormat("[RECONCILIATION RESULT] Exit confirmed closed! Position %I64d liquidated.", expectedTicket);

         // Find closing deal in history
         ulong closeDealTicket = 0;
         double exitFillPrice = 0.0;
         datetime fromTime = TimeCurrent() - 120;
         if(HistorySelect(fromTime, TimeCurrent()))
         {
            int dTotal = HistoryDealsTotal();
            for(int i = dTotal - 1; i >= 0; i--)
            {
               ulong dt = HistoryDealGetTicket(i);
               if(dt > 0 && HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber &&
                  HistoryDealGetString(dt, DEAL_SYMBOL) == symbol &&
                  HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
               {
                  if(expectedTicket == 0 || (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID) == expectedTicket)
                  {
                     closeDealTicket = dt;
                     exitFillPrice = HistoryDealGetDouble(dt, DEAL_PRICE);
                     break;
                  }
               }
            }
         }

         MqlTick tick;
         double tickAgeMs = 0.0;
         GetLatestTick(symIdx, tick, tickAgeMs);
         double exitReqPrice = (tick.bid > 0) ? tick.bid : exitFillPrice;
         double midExit = (tick.bid > 0 && tick.ask > 0) ? ((tick.bid + tick.ask) / 2.0) : exitFillPrice;
         double spread = tick.ask - tick.bid;
         if(exitFillPrice <= 0.0) exitFillPrice = exitReqPrice;

         // Execution slippage & mid_at_fill for reconcile close
         double exitExecSlipPts = 0.0;
         bool exitLookupOk = false;
         double exitMidAtFill = midExit;

         if(closeDealTicket > 0 && HistoryDealSelect(closeDealTicket))
         {
            long dealTimeMsc = HistoryDealGetInteger(closeDealTicket, DEAL_TIME_MSC);
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
         QueueTradeEvent(symbol, "trade", "SELL", InpVolume, exitReqPrice, exitFillPrice,
                         tick.bid, tick.ask, spread, TRADE_RETCODE_DONE, (g_lastRttUs >= 0 ? g_lastRttUs / 1000.0 : 0.0),
                         InpDeviation, "reconcile_exit_close",
                         (long)tick.time_msc, tickAgeMs, InpPollIntervalMs,
                         g_lastDispatchUs, g_lastRttUs);

         // Roundtrip metrics
         double slippageBuyMidFillPts = (pt > 0) ? ((g_entryFillPrice - g_entryMidAtFill) / pt) : 0.0;
         double slippageSellMidFillPts = (pt > 0) ? ((exitMidAtFill - exitFillPrice) / pt) : 0.0;
         double exitSpreadPts = (pt > 0.0) ? (spread / pt) : 0.0;

         double rawDiff = exitFillPrice - g_entryFillPrice;
         double f2fDrag = -rawDiff;
         double f2fCostEur = f2fDrag * InpVolume * contractSize * fxToEur;
         double f2fCostBps = (g_entryMid > 0) ? ((f2fDrag / g_entryMid) * 10000.0) : 0.0;

         double entryFriction = g_entryFillPrice - g_entryMid;
         double exitFriction = midExit - exitFillPrice;
         double midAdjDrag = entryFriction + exitFriction;
         double midAdjCostEur = midAdjDrag * InpVolume * contractSize * fxToEur;
         double midAdjCostBps = (g_entryMid > 0) ? ((midAdjDrag / g_entryMid) * 10000.0) : 0.0;

         double midMove = midExit - g_entryMid;
         double midMovePts = (pt > 0) ? (midMove / pt) : 0.0;

         double modelCostEur = 0.0;
         double modelCost1spEur = 0.0;
         double ratioVal = -1.0;
         double ratio1spVal = -1.0;

         if(g_entrySpreadPts > 0)
         {
            double entrySpreadPrice = g_entrySpreadPts * pt;
            modelCostEur = 2.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
            if(modelCostEur > 0.0)
               ratioVal = midAdjCostEur / modelCostEur;

            modelCost1spEur = 1.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
            if(modelCost1spEur > 0.0)
               ratio1spVal = midAdjCostEur / modelCost1spEur;
         }

         double rawPnlEur = rawDiff * InpVolume * contractSize * fxToEur;
         bool overallLookupOk = (g_entryLookupOk && exitLookupOk);
         double elapsedHoldSec = (g_positionOpenTimeServer > 0) ? (double)(TimeCurrent() - g_positionOpenTimeServer) : (double)InpHoldSeconds;

         QueueRoundtrip(symbol, InpVolume, g_entryReqPrice, g_entryFillPrice,
                        exitReqPrice, exitFillPrice, g_entrySnapAgeMs,
                        g_entryDriftPts, exitDriftPts,
                        g_entryMidAtFill, exitMidAtFill,
                        slippageBuyMidFillPts, slippageSellMidFillPts,
                        g_entrySpreadPts, exitSpreadPts,
                        g_entryMid, midExit, midMovePts,
                        f2fCostEur, f2fCostBps,
                        midAdjCostEur, midAdjCostBps,
                        modelCostEur, ratioVal,
                        modelCost1spEur, ratio1spVal,
                        rawPnlEur, elapsedHoldSec, false, g_isRestartTrip,
                        g_exitGateWaitedMs, g_exitZeroSpread, overallLookupOk,
                        g_entryExecSlipPts, exitExecSlipPts,
                        g_entryDriftPts, exitDriftPts,
                        (double)g_entrySnapshotTick.time_msc, (double)g_entrySnapshotTick.time_msc,
                        g_entrySnapAgeMs, false,
                        g_entryDispatchUs, g_entryRttUs, g_lastDispatchUs, g_lastRttUs);

         ClearHoldState();
         SetInFlightLock(false);
         return true;
      }
      else
      {
         PrintFormat("[RECONCILIATION RESULT] Position %I64d is still open! Exit retry required.", foundPosTicket);
         SetInFlightLock(false);
         return false;
      }
   }
}

//+------------------------------------------------------------------+
//| Execute BUY Entry (Rules 1, 3, 4, 8)                             |
//+------------------------------------------------------------------+
bool ExecuteEntry(string symbol, int symIdx)
{
   if(g_in_flight)
   {
      Print("[WARN] In-flight lock is active. Rejecting duplicate entry attempt.");
      return false;
   }

   datetime nowUtc = TimeGMT();
   if(IsMarketClosed(nowUtc))
   {
      QueueSkip(symbol, "market_closed", "Forex market is closed for weekend");
      return false;
   }

   MqlTick tick;
   double tickAgeMs = 0.0;
   if(!GetLatestTick(symIdx, tick, tickAgeMs) || tick.bid <= 0 || tick.ask <= 0)
   {
      QueueSkip(symbol, "no_tick", "SymbolInfoTick returned invalid or zero quote");
      return false;
   }

   double spread = tick.ask - tick.bid;
   if(spread <= 0.0 || tick.bid >= tick.ask)
   {
      QueueSkip(symbol, "zero_spread", StringFormat("Reported spread is %.5f <= 0 (bid >= ask)", spread));
      return false;
   }

   if(tickAgeMs > 500.0)
   {
      QueueSkip(symbol, "stale_tick", StringFormat("Tick age %.1f ms > 500 ms threshold", tickAgeMs));
      return false;
   }

   // Cache entry metrics
   double pt = g_symPoint[symIdx];
   g_entrySnapshotTick = tick;
   g_entrySnapAgeMs = tickAgeMs;
   g_entryReqPrice = tick.ask;
   g_entrySpreadPts = (pt > 0) ? (spread / pt) : 0.0;
   g_entryMid = (tick.bid + tick.ask) / 2.0;
   ulong tTickUs = TickFirstSeenUs(symIdx);

   // ---- Dispatch window: no Print and no disk write between here and OrderSend returning ----
   GvBegin();
   SetProbeState(STATE_ENTRY_PENDING, "Asserting in-flight lock before OrderSend", true);
   SetInFlightLock(true); // Rule 1: Assert lock immediately BEFORE calling OrderSend

   m_trade.SetTypeFilling(g_symFilling[symIdx]);
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetExpertMagicNumber(InpMagicNumber);

   ulong tReq = GetMicrosecondCount();
   bool res = m_trade.Buy(InpVolume, symbol, g_entryReqPrice, 0, 0, "exec_probe");
   ulong tFill = GetMicrosecondCount();

   g_lastDispatchUs = (tTickUs > 0 && tReq >= tTickUs) ? (long)(tReq - tTickUs) : -1;
   g_lastRttUs = (long)(tFill - tReq);
   GvEnd();   // single GlobalVariablesFlush() for lock + ENTRY_PENDING, after the broker answered
   // ---- End of dispatch window ----

   g_entryDispatchUs = g_lastDispatchUs;
   g_entryRttUs = g_lastRttUs;
   g_entryLatencyMs = (double)g_lastRttUs / 1000.0;
   g_entrySession = GetCurrentSession(nowUtc);
   EmitDeferredTransitionLog();
   LogDispatch(symbol, "BUY");

   uint retcode = m_trade.ResultRetcode();
   double fillPrice = m_trade.ResultPrice();

   // Rule 8: Fault injection suite (InpInjectTimeout)
   if(InpInjectTimeout)
   {
      Print("[FAULT INJECTION] Simulating TRADE_RETCODE_TIMEOUT (10004)...");
      retcode = TRADE_RETCODE_TIMEOUT;
      res = false;
   }

   // Rule 3: Indeterminate retcodes reconciliation
   if(retcode == TRADE_RETCODE_TIMEOUT || retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == 10004 || retcode == 10008 || retcode == 10010)
   {
      PrintFormat("[%s INDETERMINATE RETCODE %u] Routing immediately to reconciliation...", symbol, retcode);
      return ReconcileInFlight(symbol, m_trade.ResultOrder(), false);
   }

   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s ENTRY FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), g_entryLatencyMs);

      // Verify whether position opened despite failure
      bool ok = ReconcileInFlight(symbol, m_trade.ResultOrder(), false);
      if(ok) return true;

      bool isFillingReject = (retcode == TRADE_RETCODE_INVALID_FILL);
      if(!isFillingReject)
      {
         g_consecutiveErrors++;
         GvSet(GV_CONSEC_ERRORS, (double)g_consecutiveErrors);
      }

      QueueTradeEvent(symbol, "trade", "BUY", InpVolume, g_entryReqPrice, fillPrice,
                      tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                      (long)tick.time_msc, tickAgeMs, InpPollIntervalMs,
                      g_entryDispatchUs, g_entryRttUs);

      SetInFlightLock(false);
      SetProbeState(STATE_IDLE, "Entry failed and cleared");
      return false;
   }

   g_entryFillPrice = fillPrice;
   g_currentPositionTicket = m_trade.ResultOrder();   // replaced by DEAL_POSITION_ID below when the deal is visible
   g_positionOpenLocalMs = GetTickCount64();
   g_positionOpenTimeServer = TimeCurrent();
   g_isRestartTrip = false;
   g_consecutiveErrors = 0;
   GvSet(GV_CONSEC_ERRORS, 0.0);

   // Execution slippage & mid_at_fill via CopyTicksRange (M5 & M6)
   g_entryExecSlipPts = 0.0;
   g_entryLookupOk = false;
   g_entryMidAtFill = g_entryMid;

   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
   {
      // The restart path matches GV_HOLD_TICKET against PositionGetTicket(); store the position id, not the order id
      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId > 0) g_currentPositionTicket = posId;
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
               g_entryExecSlipPts = (pt > 0) ? ((g_entryFillPrice - prevAsk) / pt) : 0.0;
               if(prevBid > 0 && prevAsk > 0)
                  g_entryMidAtFill = (prevBid + prevAsk) / 2.0;
               g_entryLookupOk = true;
               break;
            }
         }
      }
   }

   g_entryDriftPts = (pt > 0) ? ((g_entryFillPrice - g_entryReqPrice) / pt) : 0.0;

   SaveHoldState(g_currentPositionTicket, symIdx, g_positionOpenLocalMs, g_positionOpenTimeServer);

   QueueTradeEvent(symbol, "trade", "BUY", InpVolume, g_entryReqPrice, g_entryFillPrice,
                   tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                   (long)tick.time_msc, tickAgeMs, InpPollIntervalMs,
                   g_entryDispatchUs, g_entryRttUs);

   SetInFlightLock(false);
   SetProbeState(STATE_IN_POSITION, "BUY order executed successfully");

   PrintFormat("[%s ENTRY FILLED] [%s] BUY %.2f @ %f (Req: %f) | Latency: %.1f ms | ExecSlip: %s | Drift: %+.2f pt",
               symbol, g_entrySession, InpVolume, g_entryFillPrice, g_entryReqPrice,
               g_entryLatencyMs, (g_entryLookupOk ? StringFormat("%+.2f pt", g_entryExecSlipPts) : "NaN"), g_entryDriftPts);
   PrintFormat("[HOLD ARMED] position %I64u | hold %d s | exit due at local tick %I64u",
               g_currentPositionTicket, InpHoldSeconds, g_positionOpenLocalMs + (ulong)InpHoldSeconds * 1000);

   return true;
}

//+------------------------------------------------------------------+
//| Execute Position Close (Rules 1, 2, 3, 8)                        |
//+------------------------------------------------------------------+
bool ExecuteExit(string symbol, int symIdx, ulong posTicket, bool isOrphanCleanup)
{
   if(!m_position.SelectByTicket(posTicket) || m_position.Magic() != InpMagicNumber)
   {
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
         PrintFormat("[%s EXIT] Position %I64d already liquidated or not found.", symbol, posTicket);
         ClearHoldState();
         SetInFlightLock(false);
         return true;
      }
   }

   double posVolume = m_position.Volume();   // position selected above (by ticket or by index)
   if(posVolume <= 0.0) posVolume = InpVolume;

   double pt = g_symPoint[symIdx];
   double contractSize = g_symContract[symIdx];
   double fxToEur = GetFxToEur(symbol);

   MqlTick tick;
   double tickAgeMs = 0.0;
   GetLatestTick(symIdx, tick, tickAgeMs);
   double spread = tick.ask - tick.bid;
   ulong tTickUs = TickFirstSeenUs(symIdx);

   g_exitZeroSpread = (spread <= 0.0 || tick.bid >= tick.ask);
   double exitReqPrice = tick.bid;
   double midExit = (tick.bid > 0 && tick.ask > 0) ? ((tick.bid + tick.ask) / 2.0) : tick.bid;

   // Rule 8: Fault injection suite (InpInjectCloseReject) - checked BEFORE broker call
   bool res = false;
   uint retcode = 0;
   double exitLatencyMs = 0.0;
   double exitFillPrice = 0.0;
   long exitDispatchUs = -1;
   long exitRttUs = -1;
   string resultComment = "";

   // ---- Dispatch window: no Print and no disk write between here and OrderSend returning ----
   GvBegin();
   SetProbeState(STATE_EXIT_PENDING, "Asserting in-flight lock before PositionClose", true);
   SetInFlightLock(true); // Rule 1: Assert lock immediately BEFORE calling OrderSend

   bool injected = (g_injectedRejectsRemaining > 0);
   if(injected)
   {
      g_injectedRejectsRemaining--;
      retcode = TRADE_RETCODE_REJECT;
      res = false;
      resultComment = "fault_injection";
   }
   else
   {
      // Set on every close: after a restart no entry has run in this process, and CTrade would otherwise
      // send the close with magic 0 / default filling, which the DEAL_MAGIC history lookups do not match.
      m_trade.SetTypeFilling(g_symFilling[symIdx]);
      m_trade.SetExpertMagicNumber(InpMagicNumber);
      m_trade.SetDeviationInPoints(InpDeviation);
      ulong tReq = GetMicrosecondCount();
      res = m_trade.PositionClose(posTicket, InpDeviation);
      ulong tFill = GetMicrosecondCount();

      g_lastDispatchUs = (tTickUs > 0 && tReq >= tTickUs) ? (long)(tReq - tTickUs) : -1;
      g_lastRttUs = (long)(tFill - tReq);

      retcode = m_trade.ResultRetcode();
      exitFillPrice = m_trade.ResultPrice();
      exitDispatchUs = g_lastDispatchUs;
      exitRttUs = g_lastRttUs;
      exitLatencyMs = (double)exitRttUs / 1000.0;
      resultComment = m_trade.ResultComment();
   }
   GvEnd();
   // ---- End of dispatch window ----

   EmitDeferredTransitionLog();
   if(injected)
      PrintFormat("[FAULT INJECTION] Simulated rejected close attempt (%d remaining). Broker call skipped.", g_injectedRejectsRemaining);
   else
      LogDispatch(symbol, "SELL");

   // Rule 3: Indeterminate retcodes reconciliation on exit
   if(retcode == TRADE_RETCODE_TIMEOUT || retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == 10004 || retcode == 10008 || retcode == 10010)
   {
      PrintFormat("[%s INDETERMINATE EXIT RETCODE %u] Routing immediately to reconciliation...", symbol, retcode);
      return ReconcileInFlight(symbol, posTicket, true);
   }

   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s EXIT FAIL] Retcode: %u | %s | Latency: %s ms",
                  symbol, retcode, resultComment, (injected ? "NaN" : DoubleToString(exitLatencyMs, 1)));

      // Verify whether position closed despite retcode
      if(!m_position.SelectByTicket(posTicket))
      {
         PrintFormat("[RECONCILIATION] Position %I64d closed despite retcode %u.", posTicket, retcode);
         ClearHoldState();
         SetInFlightLock(false);
         return true;
      }

      QueueTradeEvent(symbol, "close_failure", "SELL", posVolume, exitReqPrice, exitFillPrice,
                      tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, resultComment,
                      (long)tick.time_msc, tickAgeMs, InpPollIntervalMs,
                      exitDispatchUs, exitRttUs);

      SetInFlightLock(false);
      SetProbeState(STATE_EXIT_RETRY, "Exit failed; holding in EXIT_RETRY for backoff retry");
      return false; // Stays in exit state to retry
   }

   ClearHoldState();
   SetInFlightLock(false);

   // Exit slippage & mid_at_fill via CopyTicksRange
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

   QueueTradeEvent(symbol, eventType, "SELL", posVolume, exitReqPrice, exitFillPrice,
                   tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, resultComment,
                   (long)tick.time_msc, tickAgeMs, InpPollIntervalMs,
                   exitDispatchUs, exitRttUs);

   // Roundtrip calculations
   double slippageBuyMidFillPts = (pt > 0) ? ((g_entryFillPrice - g_entryMidAtFill) / pt) : 0.0;
   double slippageSellMidFillPts = (pt > 0) ? ((exitMidAtFill - exitFillPrice) / pt) : 0.0;
   double exitSpreadPts = (pt > 0.0) ? (spread / pt) : 0.0;

   double rawDiff = exitFillPrice - g_entryFillPrice;
   double f2fDrag = -rawDiff;
   double f2fCostEur = f2fDrag * InpVolume * contractSize * fxToEur;
   double f2fCostBps = (g_entryMid > 0) ? ((f2fDrag / g_entryMid) * 10000.0) : 0.0;

   double entryFriction = g_entryFillPrice - g_entryMid;
   double exitFriction = midExit - exitFillPrice;
   double midAdjDrag = entryFriction + exitFriction;
   double midAdjCostEur = midAdjDrag * InpVolume * contractSize * fxToEur;
   double midAdjCostBps = (g_entryMid > 0) ? ((midAdjDrag / g_entryMid) * 10000.0) : 0.0;

   double midMove = midExit - g_entryMid;
   double midMovePts = (pt > 0) ? (midMove / pt) : 0.0;

   double modelCostEur = 0.0;
   double modelCost1spEur = 0.0;
   double ratioVal = -1.0;
   double ratio1spVal = -1.0;

   if(g_entrySpreadPts > 0)
   {
      double entrySpreadPrice = g_entrySpreadPts * pt;
      modelCostEur = 2.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
      if(modelCostEur > 0.0)
         ratioVal = midAdjCostEur / modelCostEur;

      modelCost1spEur = 1.0 * entrySpreadPrice * InpVolume * contractSize * fxToEur;
      if(modelCost1spEur > 0.0)
         ratio1spVal = midAdjCostEur / modelCost1spEur;
   }

   double rawPnlEur = rawDiff * InpVolume * contractSize * fxToEur;
   bool overallLookupOk = (g_entryLookupOk && exitLookupOk);
   double elapsedHoldSec = (g_positionOpenTimeServer > 0) ? (double)(TimeCurrent() - g_positionOpenTimeServer) : (double)InpHoldSeconds;

   QueueRoundtrip(symbol, InpVolume, g_entryReqPrice, g_entryFillPrice,
                  exitReqPrice, exitFillPrice, g_entrySnapAgeMs,
                  g_entryDriftPts, exitDriftPts,
                  g_entryMidAtFill, exitMidAtFill,
                  slippageBuyMidFillPts, slippageSellMidFillPts,
                  g_entrySpreadPts, exitSpreadPts,
                  g_entryMid, midExit, midMovePts,
                  f2fCostEur, f2fCostBps,
                  midAdjCostEur, midAdjCostBps,
                  modelCostEur, ratioVal,
                  modelCost1spEur, ratio1spVal,
                  rawPnlEur, elapsedHoldSec, false, g_isRestartTrip,
                  g_exitGateWaitedMs, g_exitZeroSpread, overallLookupOk,
                  g_entryExecSlipPts, exitExecSlipPts,
                  g_entryDriftPts, exitDriftPts,
                  (double)g_entrySnapshotTick.time_msc, (double)g_entrySnapshotTick.time_msc,
                  g_entrySnapAgeMs, false,
                  g_entryDispatchUs, g_entryRttUs, exitDispatchUs, exitRttUs);

   PrintFormat("[%s ROUND-TRIP COMPLETE] F2F: %.4f EUR (%.2f bps) | Mid-Adj: %.4f EUR (%.2f bps) | Hold: %.1f s | Restart: %s",
               symbol, f2fCostEur, f2fCostBps, midAdjCostEur, midAdjCostBps, elapsedHoldSec, (g_isRestartTrip ? "True" : "False"));

   return true;
}

//+------------------------------------------------------------------+
//| Rule 6: Orphan Close Reconciliation                              |
//+------------------------------------------------------------------+
void ReconcileOrphanCloses()
{
   datetime fromTime = TimeCurrent() - 86400; // Check past 24 hours
   if(!HistorySelect(fromTime, TimeCurrent())) return;

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dTicket = HistoryDealGetTicket(i);
      if(dTicket > 0 && HistoryDealGetInteger(dTicket, DEAL_MAGIC) == InpMagicNumber)
      {
         long dEntry = HistoryDealGetInteger(dTicket, DEAL_ENTRY);
         if(dEntry == DEAL_ENTRY_OUT)
         {
            long dReason = HistoryDealGetInteger(dTicket, DEAL_REASON);
            if(dReason == DEAL_REASON_SO || dReason == DEAL_REASON_EXPERT)
            {
               // Already recorded or audited
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction: Rule 1 In-Flight Resolution Callback         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_REQUEST)
   {
      if(trans.position > 0 && trans.symbol != "")
      {
         // Verify whether transaction resolves in-flight lock
         if(g_in_flight)
         {
            PrintFormat("[TRADE TRANSACTION] In-flight resolution: %s (Type: %d, Position: %I64d)",
                        trans.symbol, trans.type, trans.position);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Instance lock key: low 52 bits of the chart id. A GV is a double,|
//| which holds integers exactly only up to 2^53; raw chart ids      |
//| (~1.3e17) would round, and neighbouring ids could collide.       |
//+------------------------------------------------------------------+
double InstanceKey(long chartId)
{
   return (double)(chartId & 0xFFFFFFFFFFFFF);
}

bool InstanceOwnerAlive(double key)
{
   for(long c = ChartFirst(); c >= 0; c = ChartNext(c))
   {
      if(c == ChartID()) continue;
      if(InstanceKey(c) == key && ChartGetString(c, CHART_EXPERT_NAME) == MQLInfoString(MQL_PROGRAM_NAME))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Harness-only reset of EXECTEST_* globals (InpResetState=true).   |
//| Skipped while an own-magic position is open, and while a hold    |
//| record exists before the terminal is connected (positions may    |
//| not be synchronized yet), so a crash-restart keeps its recovery  |
//| data. The result line is what the smoke harness asserts on.      |
//+------------------------------------------------------------------+
void ResetPersistedStateIfSafe()
{
   int ownPositions = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber) ownPositions++;

   bool holdRecord = GlobalVariableCheck(GV_HOLD_TICKET);
   bool connected = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   if(ownPositions > 0 || (holdRecord && !connected))
   {
      PrintFormat("[STATE RESET] SKIPPED: %d own position(s) open, hold record %s, connected %s; persisted state kept for recovery",
                  ownPositions, holdRecord ? "present" : "absent", connected ? "true" : "false");
      return;
   }

   int deleted = 0;
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, GV_PREFIX) == 0 && GlobalVariableDel(name)) deleted++;
   }
   GlobalVariablesFlush();
   PrintFormat("[STATE RESET] Cleared %d EXECTEST_* globals (InpResetState=true, 0 own positions)", deleted);
}

//+------------------------------------------------------------------+
//| Expert Initialization Function (Rules 4, 8, M10, M11)            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=================================================");
   Print("INITIALIZING MT5 EXECUTION QUALITY EA (ExecTest)");
   Print("=================================================");

   // Hard safety rule: DEMO account verification
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   g_isDemo = (tradeMode == ACCOUNT_TRADE_MODE_DEMO);
   if(!g_isDemo)
   {
      Alert("FATAL: Account is NOT DEMO! Refusing to initialize ExecTest EA.");
      return INIT_FAILED;
   }

   // Single-instance guard: a second chart running ExecTest (e.g. restored from a saved profile next to a
   // /config startup chart) would trade the same magic number.
   //  * The lock is a temporary GV: never written by GlobalVariablesFlush() and gone when the terminal
   //    process ends, so after taskkill /f the relaunched terminal starts with no lock at all.
   //  * A stale lock inside a running terminal (owner stopped without OnDeinit) is taken over when no open
   //    chart with that key still runs ExecTest.
   double myKey = InstanceKey(ChartID());
   string prevLock = "none";
   if(GlobalVariableCheck(GV_INSTANCE_LOCK))
   {
      double heldKey = GlobalVariableGet(GV_INSTANCE_LOCK);
      if(heldKey != myKey)
      {
         if(InstanceOwnerAlive(heldKey))
         {
            Alert("FATAL: another ExecTest instance is already running in this terminal. Refusing to initialize.");
            PrintFormat("[INSTANCE LOCK] Duplicate ExecTest instance refused (INIT_FAILED); held by chart key %.0f", heldKey);
            return INIT_FAILED;
         }
         prevLock = StringFormat("stale key %.0f taken over", heldKey);
      }
      else
         prevLock = "own chart (re-init)";
   }
   GlobalVariableTemp(GV_INSTANCE_LOCK);
   GlobalVariableSet(GV_INSTANCE_LOCK, myKey);
   PrintFormat("[INSTANCE LOCK] acquired by chart key %.0f (previous: %s)", myKey, prevLock);

   // Rule 4: Hard volume guard: strict equality with MAX_VOLUME (0.01)
   if(MathAbs(InpVolume - MAX_VOLUME) > 0.0001)
   {
      Alert(StringFormat("FATAL: InpVolume (%.4f) violates hard MAX_VOLUME limit of %.2f lot!",
                         InpVolume, MAX_VOLUME));
      return INIT_FAILED;
   }

   // Initialize symbols and tick ring structures
   for(int i = 0; i < 2; i++)
   {
      SymbolSelect(g_activeSymbols[i], true);
      m_symbols[i].Name(g_activeSymbols[i]);

      if(!ValidateVolume(g_activeSymbols[i], InpVolume))
      {
         Alert(StringFormat("FATAL: InpVolume (%.4f) violates %s broker constraints!",
                            InpVolume, g_activeSymbols[i]));
         return INIT_FAILED;
      }

      // Cache static symbol parameters once (previously re-queried on every entry/exit)
      g_symPoint[i]      = SymbolInfoDouble(g_activeSymbols[i], SYMBOL_POINT);
      g_symContract[i]   = SymbolInfoDouble(g_activeSymbols[i], SYMBOL_TRADE_CONTRACT_SIZE);
      g_symProfitCcy[i]  = SymbolInfoString(g_activeSymbols[i], SYMBOL_CURRENCY_PROFIT);
      g_symFilling[i]    = GetSymbolFillingMode(g_activeSymbols[i]);
      if(g_symPoint[i] <= 0.0 || g_symContract[i] <= 0.0)
      {
         Alert(StringFormat("FATAL: %s point (%f) or contract size (%f) unavailable", g_activeSymbols[i],
                            g_symPoint[i], g_symContract[i]));
         return INIT_FAILED;
      }

   }

   g_chartSymIdx = -1;
   for(int i = 0; i < 2; i++)
      if(_Symbol == g_activeSymbols[i]) g_chartSymIdx = i;

   // Initialize fault injection suite (Rule 8)
   g_injectedRejectsRemaining = InpInjectCloseReject;
   if(InpInjectCloseReject > 0)
      PrintFormat("[FAULT INJECTION CONFIGURED] InpInjectCloseReject = %d", InpInjectCloseReject);
   if(InpInjectTimeout)
      Print("[FAULT INJECTION CONFIGURED] InpInjectTimeout = TRUE");

   // Initialize tick rings
   for(int i = 0; i < 2; i++)
   {
      g_tickRings[i].head = 0;
      g_tickRings[i].count = 0;
      g_tickRings[i].last_tick_msc = 0;
      g_tickRings[i].local_first_seen_us = 0;

      MqlTick tick;
      if(SymbolInfoTick(g_activeSymbols[i], tick))
         PushTickRing(i, tick, GetMicrosecondCount());
   }

   // Harness-only state reset (InpResetState). Never wipes state an open position or hold record depends on.
   if(InpResetState)
      ResetPersistedStateIfSafe();

   // Load Persistent State
   double priorStateGv = GlobalVariableCheck(GV_PROBE_STATE) ? GlobalVariableGet(GV_PROBE_STATE) : -1.0;
   bool priorInFlight = GlobalVariableCheck(GV_IN_FLIGHT) && (GlobalVariableGet(GV_IN_FLIGHT) > 0.5);
   LoadPersistentState();
   InitCsvFiles();

   // Reconcile orphan closes from history (Rule 6)
   ReconcileOrphanCloses();

   // Inspect open positions on startup (Rules 1, 2, 6)
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
         g_entryDispatchUs  = GlobalVariableCheck(GV_HOLD_DISPATCH_US) ? (long)GlobalVariableGet(GV_HOLD_DISPATCH_US) : -1;
         g_entryRttUs       = GlobalVariableCheck(GV_HOLD_RTT_US) ? (long)GlobalVariableGet(GV_HOLD_RTT_US) : -1;
         ulong savedLocalMs = (ulong)GlobalVariableGet(GV_HOLD_LOCAL_MS);
         g_positionOpenTimeServer = (datetime)GlobalVariableGet(GV_HOLD_START_TIME);

         // Hold clock: GetTickCount64 is machine uptime, so the saved value stays valid across a terminal
         // restart. After a reboot it is not (saved > now); fall back to server-time elapsed then.
         ulong nowLocalMs = GetTickCount64();
         long elapsedMs;
         string clockSrc;
         if(savedLocalMs > 0 && savedLocalMs <= nowLocalMs && (nowLocalMs - savedLocalMs) < 86400000)
         {
            elapsedMs = (long)(nowLocalMs - savedLocalMs);
            clockSrc = "local_uptime";
         }
         else
         {
            elapsedMs = (long)(TimeCurrent() - g_positionOpenTimeServer) * 1000;
            if(elapsedMs < 0) elapsedMs = 0;
            clockSrc = "server_time";
         }
         g_positionOpenLocalMs = nowLocalMs - (ulong)elapsedMs;
         int elapsedSec = (int)(elapsedMs / 1000);

         PrintFormat("[RESTART RECOVERY] Recovered position %I64d (%s). Open server time: %s, Elapsed: %d s (%s), prior state: %s, prior in-flight: %s",
                     existingTicket, existingSymbol, TimeToString(g_positionOpenTimeServer), elapsedSec, clockSrc,
                     (priorStateGv >= 0 && priorStateGv <= 6) ? g_stateNames[(int)priorStateGv] : "unknown",
                     priorInFlight ? "true" : "false");
         SetInFlightLock(false);   // the order that was in flight resolved into this position

         if(elapsedMs >= (long)InpHoldSeconds * 1000)
         {
            SetProbeState(STATE_EXIT_PENDING, "Restart position hold duration elapsed; scheduling exit");
            g_exitGateStartLocalMs = GetTickCount64();
            g_nextExitAttemptLocalMs = 0;
            g_exitFailAttempts = 0;
         }
         else
         {
            SetProbeState(STATE_IN_POSITION, "Restart position mid-hold resumed");
         }
      }
      else
      {
         PrintFormat("[ORPHAN DETECTED] Unpersisted orphan position found on %s (%I64d). Immediate cleanup required. (hold ticket GV: %s, prior state: %s)",
                     existingSymbol, existingTicket,
                     GlobalVariableCheck(GV_HOLD_TICKET) ? DoubleToString(GlobalVariableGet(GV_HOLD_TICKET), 0) : "absent",
                     (priorStateGv >= 0 && priorStateGv <= 6) ? g_stateNames[(int)priorStateGv] : "unknown");
         SetInFlightLock(false);
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

         SetProbeState(STATE_ORPHAN_CLEANUP, "Orphan position cleanup scheduled");
         g_exitGateStartLocalMs = GetTickCount64();
         g_nextExitAttemptLocalMs = 0;
         g_exitFailAttempts = 0;
      }
   }
   else
   {
      ClearHoldState();
      SetInFlightLock(false);
      g_state = STATE_IDLE;
      GvSet(GV_PROBE_STATE, (double)STATE_IDLE);
      Print("[FSM TRANSITION] STARTUP -> STATE_IDLE | Reason: Startup clean; ready in IDLE");
      g_nextCycleLocalMs = GetTickCount64() + 5000;
   }

   // High-frequency polling timer (10-20 ms)
   EventSetMillisecondTimer(InpPollIntervalMs);

   PrintFormat("[SAFETY VERIFIED] Demo Account: %I64d | Baseline Equity: %.2f EUR | Max Orders/Day: %d | Poll Interval: %d ms",
               AccountInfoInteger(ACCOUNT_LOGIN), g_initialEquity, InpMaxOrdersPerDay, InpPollIntervalMs);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert Deinitialization Function (Rules 9 / M10, M11)            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   FlushQueuesToDisk();

   // Clear GlobalVariables if deinitialization is user-requested normal shutdown
   if(reason == REASON_REMOVE || reason == REASON_PROGRAM)
   {
      Print("[CLEAN SHUTDOWN] Clearing active execution GlobalVariables.");
      GvDel(GV_IN_FLIGHT);
   }

   if(GlobalVariableCheck(GV_INSTANCE_LOCK) && GlobalVariableGet(GV_INSTANCE_LOCK) == InstanceKey(ChartID()))
      GlobalVariableDel(GV_INSTANCE_LOCK);

   GlobalVariablesFlush();
   PrintFormat("[SHUTDOWN] ExecTest EA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| OnTick Hot Path (Rule 7: Zero-Allocation Hot Path)               |
//| t_tick is taken first; it becomes the tick's first-seen time     |
//| unless OnTimer polled the same tick earlier.                     |
//+------------------------------------------------------------------+
void OnTick()
{
   ulong tTickUs = GetMicrosecondCount();
   if(g_chartSymIdx < 0) return;
   MqlTick tick;
   if(SymbolInfoTick(g_activeSymbols[g_chartSymIdx], tick))
      PushTickRing(g_chartSymIdx, tick, tTickUs);
}

//+------------------------------------------------------------------+
//| OnTimer FSM Execution Engine (Sections 1 & 2)                    |
//+------------------------------------------------------------------+
ulong g_lastTimerUs = 0;

void OnTimer()
{
   ulong nowUs = GetMicrosecondCount();
   UtcLabelAnchorTick();

   // Timer-stall watchdog: the hold clock is only evaluated here, so a blocked handler delays exits.
   if(g_lastTimerUs > 0 && nowUs - g_lastTimerUs > 1000000)
      PrintFormat("[TIMER STALL] OnTimer gap %I64u ms (poll interval %d ms), state %s",
                  (nowUs - g_lastTimerUs) / 1000, InpPollIntervalMs, g_stateNames[g_state]);
   g_lastTimerUs = nowUs;

   // Always poll both active symbols into fixed tick rings
   for(int i = 0; i < 2; i++)
   {
      MqlTick tick;
      if(SymbolInfoTick(g_activeSymbols[i], tick))
         PushTickRing(i, tick, nowUs);
   }

   ulong nowLocal = GetTickCount64();

   // Inspect open positions with EA magic
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

   // =================================================================
   // Rule 2: INDEPENDENT EXIT PATH (Exit gates are NEVER blocked)
   // =================================================================
   if(openTicket > 0)
   {
      g_currentPositionTicket = openTicket;
      g_currentSymbol = openSymbol;
      int symIdx = (openSymbol == g_activeSymbols[0]) ? 0 : 1;

      if(g_state == STATE_IN_POSITION)
      {
         ulong heldMs = (nowLocal >= g_positionOpenLocalMs) ? (nowLocal - g_positionOpenLocalMs) : 0;
         if(heldMs >= (ulong)InpHoldSeconds * 1000)
         {
            PrintFormat("[HOLD EXPIRED] position %I64u held %I64u ms (target %d ms)",
                        openTicket, heldMs, InpHoldSeconds * 1000);
            SetProbeState(STATE_EXIT_PENDING, "Hold period elapsed; transition to EXIT_PENDING");
            g_exitGateStartLocalMs = nowLocal;
            g_exitGateWaitedMs = 0.0;
            g_exitFailAttempts = 0;
            g_nextExitAttemptLocalMs = nowLocal;
         }
         return; // Retain position during hold duration
      }

      // Exit Execution & Retry Loop (Rule 2: Exponential Backoff 250 ms to 5000 ms)
      if(nowLocal >= g_nextExitAttemptLocalMs)
      {
         MqlTick tick;
         double tickAgeMs = 0.0;
         GetLatestTick(symIdx, tick, tickAgeMs);
         double spread = tick.ask - tick.bid;
         double elapsedGateMs = (double)(nowLocal - g_exitGateStartLocalMs);

         // Clean tick wait on first attempt (up to 3000 ms)
         if(g_exitFailAttempts == 0 && (spread <= 0.0 || tick.bid >= tick.ask || tickAgeMs > 2000.0) && elapsedGateMs < 3000.0)
         {
            g_exitGateWaitedMs = elapsedGateMs;
            return;
         }

         g_exitGateWaitedMs = elapsedGateMs;
         bool isOrphan = (g_state == STATE_ORPHAN_CLEANUP);
         bool closed = ExecuteExit(openSymbol, symIdx, openTicket, isOrphan);

         if(closed)
         {
            PrintFormat("[EXIT CONFIRMED] Position %I64d liquidated successfully.", openTicket);
            g_exitFailAttempts = 0;

            string reason = "";
            bool safetyOk = CheckEntrySafetyLimits(reason);
            if(!safetyOk && (g_circuitBreakerTripped || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR))
            {
               PrintFormat("[TRADING HALTED AFTER CLOSE] %s", reason);
               SetProbeState(STATE_HALTED, reason);
            }
            else
            {
               SetProbeState(STATE_IDLE, "Position liquidated; probe transitioned to IDLE");
               g_nextCycleLocalMs = nowLocal + ((ulong)InpCycleIntervalMin * 60 * 1000);
            }
         }
         else
         {
            // Rule 2: Exponential backoff (250 ms to 5000 ms), unlimited retries, CRITICAL after 5
            g_exitFailAttempts++;
            // 250, 500, 1000, 2000, 4000, 5000, 5000, ... (exponent capped at 5, clamped to the 5000 ms ceiling)
            ulong backoffMs = 250 * (ulong)MathPow(2, MathMin(g_exitFailAttempts - 1, 5));
            if(backoffMs > 5000) backoffMs = 5000;

            if(g_exitFailAttempts >= 5)
            {
               string critMsg = StringFormat("[CRITICAL] Exit failed %d consecutive attempts for %s (%I64d)! Retrying in %I64d ms...",
                                             g_exitFailAttempts, openSymbol, openTicket, backoffMs);
               Print(critMsg);
               if(g_exitFailAttempts % 5 == 0)
                  Alert(critMsg);
            }
            else
            {
               PrintFormat("[EXIT RETRY] Attempt %d failed. Retrying in %I64d ms...", g_exitFailAttempts, backoffMs);
            }

            g_nextExitAttemptLocalMs = nowLocal + backoffMs;
            SetProbeState(STATE_EXIT_RETRY, "Close rejected; waiting for backoff retry");
         }
      }
      return; // Do not proceed to entry path while position is open
   }

   // =================================================================
   // Patch Set 1: EXTERNAL CLOSE RECOVERY LOOP
   // If openTicket == 0 while FSM is in an in-position or exit state,
   // the position was closed externally (manual/TP/SL/margin cut).
   // =================================================================
   if(g_state == STATE_IN_POSITION || g_state == STATE_EXIT_PENDING ||
      g_state == STATE_EXIT_RETRY || g_state == STATE_ORPHAN_CLEANUP)
   {
      PrintFormat("[EXTERNAL CLOSE DETECTED] Position %I64d disappeared while in state %d! Scanning history...",
                  g_currentPositionTicket, g_state);

      datetime fromTime = TimeCurrent() - 3600;
      double extClosePrice = 0.0;
      datetime extCloseTime = 0;
      double extProfit = 0.0;
      bool foundCloseDeal = false;

      if(HistorySelect(fromTime, TimeCurrent()))
      {
         int dTotal = HistoryDealsTotal();
         for(int i = dTotal - 1; i >= 0; i--)
         {
            ulong dt = HistoryDealGetTicket(i);
            if(dt > 0 && HistoryDealGetInteger(dt, DEAL_MAGIC) == InpMagicNumber &&
               HistoryDealGetInteger(dt, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
               if(g_currentPositionTicket == 0 || (ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID) == g_currentPositionTicket)
               {
                  foundCloseDeal = true;
                  extClosePrice = HistoryDealGetDouble(dt, DEAL_PRICE);
                  extCloseTime  = (datetime)HistoryDealGetInteger(dt, DEAL_TIME);
                  extProfit     = HistoryDealGetDouble(dt, DEAL_PROFIT);
                  break;
               }
            }
         }
      }

      string details = StringFormat("ticket=%I64d, close_price=%.5f, close_time=%s, profit=%.2f",
                                    g_currentPositionTicket, extClosePrice,
                                    TimeToString(extCloseTime), extProfit);
      QueueSkip(g_currentSymbol, "orphan_external_close", details);
      PrintFormat("[ORPHAN EXTERNAL CLOSE LOGGED] %s | %s", g_currentSymbol, details);

      SetInFlightLock(false);
      ClearHoldState();
      g_currentPositionTicket = 0;
      g_exitFailAttempts = 0;

      string reason = "";
      bool safetyOk = CheckEntrySafetyLimits(reason);
      if(!safetyOk && (g_circuitBreakerTripped || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR))
      {
         PrintFormat("[TRADING HALTED AFTER EXTERNAL CLOSE] %s", reason);
         SetProbeState(STATE_HALTED, reason);
      }
      else
      {
         SetProbeState(STATE_IDLE, "External close reconciled; probe returned to IDLE");
         g_nextCycleLocalMs = nowLocal + ((ulong)InpCycleIntervalMin * 60 * 1000);
      }
      return;
   }

   // =================================================================
   // IDLE STATE & LOG FLUSHING (Rule 7: Disk I/O strictly in IDLE)
   // =================================================================
   if(g_state == STATE_IDLE)
   {
      FlushQueuesToDisk();
   }

   if(g_state == STATE_HALTED)
      return;

   // =================================================================
   // ENTRY SAFETY GATES (Rules 2, 5)
   // =================================================================
   string entryReason = "";
   if(!CheckEntrySafetyLimits(entryReason))
   {
      static ulong lastSafetyLog = 0;
      if(nowLocal - lastSafetyLog > 10000)
      {
         PrintFormat("[ENTRY GATED] %s", entryReason);
         lastSafetyLog = nowLocal;
      }
      if(g_circuitBreakerTripped || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR)
      {
         SetProbeState(STATE_HALTED, entryReason);
      }
      return;
   }

   // =================================================================
   // IDLE CYCLE TRIGGER
   // =================================================================
   if(g_state == STATE_IDLE)
   {
      if(nowLocal >= g_nextCycleLocalMs)
      {
         int symIdx = g_symbolIndex % 2;
         g_currentSymbol = g_activeSymbols[symIdx];
         g_symbolIndex++;

         PrintFormat("[CYCLE TRIGGER] Initiating round-trip probe on %s...", g_currentSymbol);
         bool ok = ExecuteEntry(g_currentSymbol, symIdx);
         if(!ok)
         {
            g_nextCycleLocalMs = nowLocal + 120000; // Retry in 2 minutes on skip/fail
         }
      }
   }
}
//+------------------------------------------------------------------+
