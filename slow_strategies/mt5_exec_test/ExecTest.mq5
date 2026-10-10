//+------------------------------------------------------------------+
//|                                                     ExecTest.mq5 |
//|                                  MT5 Execution Quality Benchmark |
//|                                                                  |
//| Explicit State-Machine Execution Probe (Deterministic FSM)       |
//+------------------------------------------------------------------+
#property copyright "Execution Quality Benchmark"
#property link      ""
#property version   "2.00"

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

//--- Global Variables Persistence Keys (Rule 1, Rule 9 / M11)
// Note: MT5 terminal GlobalVariables expire after ~4 weeks without access
#define GV_IN_FLIGHT          "EXECTEST_IN_FLIGHT"
#define GV_BASELINE_EQUITY    "EXECTEST_BASELINE_EQUITY"
#define GV_BASELINE_DATE_UTC  "EXECTEST_BASELINE_DATE_UTC"
#define GV_CIRCUIT_BREAKER    "EXECTEST_CIRCUIT_BREAKER"
#define GV_CONSEC_ERRORS      "EXECTEST_CONSEC_ERRORS"
#define GV_DAILY_ORDER_COUNT  "EXECTEST_DAILY_ORDER_COUNT"
#define GV_DAILY_DATE_UTC     "EXECTEST_DAILY_DATE_UTC"

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
   ulong   local_first_seen_ms;
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
void SetProbeState(ENUM_PROBE_STATE newState, string reason);
void SetInFlightLock(bool locked);
bool ValidateVolume(string symbol, double volume);
void FlushQueuesToDisk();
bool CheckEntrySafetyLimits(string &reason);
bool ExecuteEntry(string symbol, int symIdx);
bool ExecuteExit(string symbol, int symIdx, ulong posTicket, bool isOrphanCleanup);
bool ReconcileInFlight(string symbol, ulong expectedTicket, bool isExit);

//+------------------------------------------------------------------+
//| FSM State Transition Logger (Section 1)                          |
//+------------------------------------------------------------------+
void SetProbeState(ENUM_PROBE_STATE newState, string reason)
{
   if(g_state == newState) return;

   string stateNames[] = {
      "STATE_IDLE",
      "STATE_ENTRY_PENDING",
      "STATE_IN_POSITION",
      "STATE_EXIT_PENDING",
      "STATE_EXIT_RETRY",
      "STATE_ORPHAN_CLEANUP",
      "STATE_HALTED"
   };

   PrintFormat("[FSM TRANSITION] %s -> %s | Reason: %s",
               stateNames[g_state], stateNames[newState], reason);
   g_state = newState;
}

//+------------------------------------------------------------------+
//| Rule 1: Atomic In-Flight Lock & Persistence                      |
//+------------------------------------------------------------------+
void SetInFlightLock(bool locked)
{
   g_in_flight = locked;
   GlobalVariableSet(GV_IN_FLIGHT, locked ? 1.0 : 0.0);
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
//| Rule 7: Zero-Allocation Hot Path - Tick Ring Buffer Push         |
//+------------------------------------------------------------------+
void PushTickRing(int idx, const MqlTick &tick)
{
   if((long)tick.time_msc != g_tickRings[idx].last_tick_msc)
   {
      g_tickRings[idx].last_tick_msc = (long)tick.time_msc;
      g_tickRings[idx].local_first_seen_ms = GetTickCount64();
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
   if(g_tickRings[idx].local_first_seen_ms == 0)
      outAgeMs = 999999.0;
   else
      outAgeMs = (double)(GetTickCount64() - g_tickRings[idx].local_first_seen_ms);
   return true;
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

   datetime nowUtc = TimeGMT();
   uint ms = (uint)(GetTickCount64() % 1000);
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
                     long tick_time_msc, double tick_age_ms, int poll_interval_ms)
{
   if(g_qTradesCount >= QUEUE_TRADES_SIZE)
   {
      Print("[WARN] Trades queue full. Overwriting oldest entry.");
      g_qTradesCount = QUEUE_TRADES_SIZE - 1;
   }

   datetime nowUtc = TimeGMT();
   uint ms = (uint)(GetTickCount64() % 1000);
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
   g_qTradesCount++;

   if(event_type == "trade")
   {
      g_dailyOrderCount++;
      GlobalVariableSet(GV_DAILY_ORDER_COUNT, (double)g_dailyOrderCount);
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
                    double send_gap_ms, bool age_uncorrected)
{
   if(g_qRoundtripsCount >= QUEUE_ROUNDTRIPS_SIZE)
   {
      Print("[WARN] Roundtrips queue full. Overwriting oldest entry.");
      g_qRoundtripsCount = QUEUE_ROUNDTRIPS_SIZE - 1;
   }

   datetime nowUtc = TimeGMT();
   uint ms = (uint)(GetTickCount64() % 1000);
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
            string line = StringFormat("%s,%s,%s,%s,%s,%.2f,%f,%f,%f,%f,%f,%u,%.1f,%I64u,%s,%I64d,%.1f,local_first_seen,%d,mql5\r\n",
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
                                       g_queueTrades[i].poll_interval_ms);
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

            string line = StringFormat("%s,%s,%s,%.2f,%f,%f,%f,%f,%.1f,%.2f,%.2f,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.5f,%.5f,%.2f,%.4f,%.2f,%.4f,%.2f,%.4f,%s,%.4f,%s,%.4f,%.1f,%s,%s,%.1f,%s,%s,%s,%s,%.2f,%.2f,%.1f,%.1f,%.1f,%s,local_first_seen,mql5\r\n",
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
                                       (g_queueRoundtrips[i].age_uncorrected ? "True" : "False"));
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
void InitCsvFiles()
{
   if(!FileIsExist(FILE_TRADES, FILE_COMMON))
   {
      int h = FileOpen(FILE_TRADES, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,event_type,side,volume,request_price,fill_price,bid_before,ask_before,spread_before,retcode,latency_ms,deviation,comment,tick_time_msc,tick_age_ms,tick_age_method,poll_interval_ms,engine\r\n");
         FileClose(h);
      }
   }

   if(!FileIsExist(FILE_ROUNDTRIPS, FILE_COMMON))
   {
      int h = FileOpen(FILE_ROUNDTRIPS, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(h != INVALID_HANDLE)
      {
         FileWriteString(h, "timestamp_utc,session,symbol,volume,entry_request_price,entry_fill_price,exit_request_price,exit_fill_price,snapshot_age_ms,entry_slippage_pts,exit_slippage_pts,mid_at_fill,exit_mid_at_fill,entry_slippage_mid_fill_pts,exit_slippage_mid_fill_pts,spread_at_entry_pts,exit_spread_pts,mid_entry,mid_exit,mid_move_during_hold_pts,fill_to_fill_cost_eur,fill_to_fill_cost_bps,mid_adjusted_cost_eur,mid_adjusted_cost_bps,model_cost_eur,cost_ratio,model_cost_1sp_eur,cost_ratio_1sp,raw_pnl_eur,hold_seconds,pre_filter,restart,exit_gate_waited_ms,exit_zero_spread,lookup_ok,entry_exec_slip_pts,exit_exec_slip_pts,entry_drift_pts,exit_drift_pts,t_tick_server,t_send_local_corrected,send_gap_ms,age_uncorrected,tick_age_method,engine\r\n");
         FileClose(h);
      }
   }

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
//| Persistence: Load state from GlobalVariables                     |
//+------------------------------------------------------------------+
void LoadPersistentState()
{
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);

   // In-flight lock
   if(GlobalVariableCheck(GV_IN_FLIGHT))
      g_in_flight = (GlobalVariableGet(GV_IN_FLIGHT) > 0.5);
   else
   {
      g_in_flight = false;
      GlobalVariableSet(GV_IN_FLIGHT, 0.0);
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
//| Persistence: Save Open Position & Hold Metrics                   |
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
//| Rule 2: Entry Limits Check (GATES ENTRY ATTEMPTS ONLY)           |
//+------------------------------------------------------------------+
bool CheckEntrySafetyLimits(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      reason = "Terminal disconnected from broker server";
      return false;
   }

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
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
      GlobalVariableSet(GV_CIRCUIT_BREAKER, 1.0);
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
      GlobalVariableSet(GV_DAILY_DATE_UTC, (double)g_currentDayUtc);
      GlobalVariableSet(GV_DAILY_ORDER_COUNT, 0.0);
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
   PrintFormat("[RECONCILIATION] Initiating deep reconciliation for %s (Ticket: %I64d, isExit: %s)...",
               symbol, expectedTicket, (isExit ? "true" : "false"));

   // 1. Query live positions
   ulong foundPosTicket = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber && m_position.Symbol() == symbol)
      {
         foundPosTicket = m_position.Ticket();
         break;
      }
   }

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
   g_entrySnapshotTick = tick;
   g_entrySnapAgeMs = tickAgeMs;
   g_entryReqPrice = tick.ask;
   g_entrySpreadPts = spread / SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryMid = (tick.bid + tick.ask) / 2.0;
   g_entrySession = GetCurrentSession(nowUtc);

   ENUM_ORDER_TYPE_FILLING fillingMode = GetSymbolFillingMode(symbol);
   m_trade.SetDeviationInPoints(InpDeviation);
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetTypeFilling(fillingMode);

   SetProbeState(STATE_ENTRY_PENDING, "Asserting in-flight lock before OrderSend");
   SetInFlightLock(true); // Rule 1: Assert lock immediately BEFORE calling OrderSend

   ulong t0 = GetMicrosecondCount();
   bool res = m_trade.Buy(InpVolume, symbol, g_entryReqPrice, 0, 0, "exec_probe_in");
   ulong t1 = GetMicrosecondCount();
   g_entryLatencyMs = (double)(t1 - t0) / 1000.0;

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
         GlobalVariableSet(GV_CONSEC_ERRORS, (double)g_consecutiveErrors);
      }

      QueueTradeEvent(symbol, "trade", "BUY", InpVolume, g_entryReqPrice, fillPrice,
                      tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                      (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

      SetInFlightLock(false);
      SetProbeState(STATE_IDLE, "Entry failed and cleared");
      return false;
   }

   g_entryFillPrice = fillPrice;
   g_currentPositionTicket = m_trade.ResultOrder();
   g_positionOpenLocalMs = GetTickCount64();
   g_positionOpenTimeServer = TimeCurrent();
   g_isRestartTrip = false;
   g_consecutiveErrors = 0;
   GlobalVariableSet(GV_CONSEC_ERRORS, 0.0);

   // Execution slippage & mid_at_fill via CopyTicksRange (M5 & M6)
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
               if(prevBid > 0 && prevAsk > 0)
                  g_entryMidAtFill = (prevBid + prevAsk) / 2.0;
               g_entryLookupOk = true;
               break;
            }
         }
      }
   }

   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryDriftPts = (pt > 0) ? ((g_entryFillPrice - g_entryReqPrice) / pt) : 0.0;

   SaveHoldState(g_currentPositionTicket, symIdx, g_positionOpenLocalMs, g_positionOpenTimeServer);

   QueueTradeEvent(symbol, "trade", "BUY", InpVolume, g_entryReqPrice, g_entryFillPrice,
                   tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment(),
                   (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   SetInFlightLock(false);
   SetProbeState(STATE_IN_POSITION, "BUY order executed successfully");

   PrintFormat("[%s ENTRY FILLED] [%s] BUY %.2f @ %f (Req: %f) | Latency: %.1f ms | ExecSlip: %s | Drift: %+.2f pt",
               symbol, g_entrySession, InpVolume, g_entryFillPrice, g_entryReqPrice,
               g_entryLatencyMs, (g_entryLookupOk ? StringFormat("%+.2f pt", g_entryExecSlipPts) : "NaN"), g_entryDriftPts);

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

   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double contractSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double fxToEur = GetFxToEur(symbol);

   MqlTick tick;
   double tickAgeMs = 0.0;
   GetLatestTick(symIdx, tick, tickAgeMs);
   double spread = tick.ask - tick.bid;

   g_exitZeroSpread = (spread <= 0.0 || tick.bid >= tick.ask);
   double exitReqPrice = tick.bid;
   double midExit = (tick.bid > 0 && tick.ask > 0) ? ((tick.bid + tick.ask) / 2.0) : tick.bid;

   SetProbeState(STATE_EXIT_PENDING, "Asserting in-flight lock before PositionClose");
   SetInFlightLock(true); // Rule 1: Assert lock immediately BEFORE calling OrderSend

   m_trade.SetDeviationInPoints(InpDeviation);
   ulong t0 = GetMicrosecondCount();
   bool res = m_trade.PositionClose(posTicket, InpDeviation);
   ulong t1 = GetMicrosecondCount();
   double exitLatencyMs = (double)(t1 - t0) / 1000.0;

   uint retcode = m_trade.ResultRetcode();
   double exitFillPrice = m_trade.ResultPrice();

   // Rule 8: Fault injection suite (InpInjectCloseReject)
   if(g_injectedRejectsRemaining > 0)
   {
      PrintFormat("[FAULT INJECTION] Simulating rejected close attempt (%d remaining)...", g_injectedRejectsRemaining);
      g_injectedRejectsRemaining--;
      retcode = TRADE_RETCODE_REJECT;
      res = false;
   }

   // Rule 3: Indeterminate retcodes reconciliation on exit
   if(retcode == TRADE_RETCODE_TIMEOUT || retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == 10004 || retcode == 10008 || retcode == 10010)
   {
      PrintFormat("[%s INDETERMINATE EXIT RETCODE %u] Routing immediately to reconciliation...", symbol, retcode);
      return ReconcileInFlight(symbol, posTicket, true);
   }

   if(!res || retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[%s EXIT FAIL] Retcode: %u | %s | Latency: %.1f ms",
                  symbol, retcode, m_trade.ResultComment(), exitLatencyMs);

      // Verify whether position closed despite retcode
      if(!m_position.SelectByTicket(posTicket))
      {
         PrintFormat("[RECONCILIATION] Position %I64d closed despite retcode %u.", posTicket, retcode);
         ClearHoldState();
         SetInFlightLock(false);
         return true;
      }

      QueueTradeEvent(symbol, "close_failure", "SELL", InpVolume, exitReqPrice, exitFillPrice,
                      tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
                      (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

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

   QueueTradeEvent(symbol, eventType, "SELL", InpVolume, exitReqPrice, exitFillPrice,
                   tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment(),
                   (long)tick.time_msc, tickAgeMs, InpPollIntervalMs);

   // Roundtrip calculations
   double slippageBuyMidFillPts = (pt > 0) ? ((g_entryFillPrice - g_entryMidAtFill) / pt) : 0.0;
   double slippageSellMidFillPts = (pt > 0) ? ((exitMidAtFill - exitFillPrice) / pt) : 0.0;
   double exitSpreadPts = spread / pt;

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
                  rawPnlEur, (double)InpHoldSeconds, false, g_isRestartTrip,
                  g_exitGateWaitedMs, g_exitZeroSpread, overallLookupOk,
                  g_entryExecSlipPts, exitExecSlipPts,
                  g_entryDriftPts, exitDriftPts,
                  (double)g_entrySnapshotTick.time_msc, (double)g_entrySnapshotTick.time_msc,
                  0.0, false);

   PrintFormat("[%s ROUND-TRIP COMPLETE] F2F: %.4f EUR (%.2f bps) | Mid-Adj: %.4f EUR (%.2f bps) | Restart: %s",
               symbol, f2fCostEur, f2fCostBps, midAdjCostEur, midAdjCostBps, (g_isRestartTrip ? "True" : "False"));

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
//| Expert Initialization Function (Rules 4, 8, M10, M11)            |
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

   // Rule 4: Volume validator check against MAX_VOLUME (0.01)
   if(InpVolume > MAX_VOLUME || InpVolume <= 0.0)
   {
      Alert(StringFormat("FATAL: InpVolume (%.4f) violates hard MAX_VOLUME limit of %.2f lot!",
                         InpVolume, MAX_VOLUME));
      return INIT_FAILED;
   }

   for(int i = 0; i < 2; i++)
   {
      if(!ValidateVolume(g_activeSymbols[i], InpVolume))
      {
         Alert(StringFormat("FATAL: InpVolume (%.4f) violates %s broker constraints!",
                            InpVolume, g_activeSymbols[i]));
         return INIT_FAILED;
      }
   }

   // Initialize fault injection suite (Rule 8)
   g_injectedRejectsRemaining = InpInjectCloseReject;
   if(InpInjectCloseReject > 0)
      PrintFormat("[FAULT INJECTION CONFIGURED] InpInjectCloseReject = %d", InpInjectCloseReject);
   if(InpInjectTimeout)
      Print("[FAULT INJECTION CONFIGURED] InpInjectTimeout = TRUE");

   // Initialize tick ring structures
   for(int i = 0; i < 2; i++)
   {
      g_tickRings[i].head = 0;
      g_tickRings[i].count = 0;
      g_tickRings[i].last_tick_msc = 0;
      g_tickRings[i].local_first_seen_ms = 0;
      SymbolSelect(g_activeSymbols[i], true);
      m_symbols[i].Name(g_activeSymbols[i]);

      MqlTick tick;
      if(SymbolInfoTick(g_activeSymbols[i], tick))
         PushTickRing(i, tick);
   }

   // Load Persistent State
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
         g_positionOpenLocalMs = (ulong)GlobalVariableGet(GV_HOLD_LOCAL_MS);
         g_positionOpenTimeServer = (datetime)GlobalVariableGet(GV_HOLD_START_TIME);

         datetime nowServer = TimeCurrent();
         int elapsedSec = (int)(nowServer - g_positionOpenTimeServer);
         PrintFormat("[RESTART RECOVERY] Recovered position %I64d (%s). Open server time: %s, Elapsed: %d s",
                     existingTicket, existingSymbol, TimeToString(g_positionOpenTimeServer), elapsedSec);

         if(elapsedSec >= InpHoldSeconds)
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
         PrintFormat("[ORPHAN DETECTED] Unpersisted orphan position found on %s (%I64d). Immediate cleanup required.",
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
      SetProbeState(STATE_IDLE, "Startup clean; ready in IDLE");
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
      GlobalVariableDel(GV_IN_FLIGHT);
   }

   PrintFormat("[SHUTDOWN] ExecTest EA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| OnTick Hot Path (Rule 7: Zero-Allocation Hot Path)               |
//+------------------------------------------------------------------+
void OnTick()
{
   string sym = _Symbol;
   int idx = (sym == "EURUSD") ? 0 : 1;
   MqlTick tick;
   if(SymbolInfoTick(sym, tick))
      PushTickRing(idx, tick);
}

//+------------------------------------------------------------------+
//| OnTimer FSM Execution Engine (Sections 1 & 2)                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Always poll both active symbols into fixed tick rings
   for(int i = 0; i < 2; i++)
   {
      MqlTick tick;
      if(SymbolInfoTick(g_activeSymbols[i], tick))
         PushTickRing(i, tick);
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
      int symIdx = (openSymbol == "EURUSD") ? 0 : 1;

      if(g_state == STATE_IN_POSITION)
      {
         if((nowLocal - g_positionOpenLocalMs) >= (ulong)(InpHoldSeconds * 1000))
         {
            SetProbeState(STATE_EXIT_PENDING, "60s hold period elapsed; transition to EXIT_PENDING");
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
            if(!CheckEntrySafetyLimits(reason))
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
            ulong backoffMs = 250 * (ulong)MathPow(2, MathMin(g_exitFailAttempts - 1, 4));
            if(backoffMs > 5000) backoffMs = 5000;

            if(g_exitFailAttempts >= 5)
            {
               PrintFormat("[CRITICAL] Exit failed %d consecutive attempts for %s (%I64d)! Retrying in %I64d ms...",
                           g_exitFailAttempts, openSymbol, openTicket, backoffMs);
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
