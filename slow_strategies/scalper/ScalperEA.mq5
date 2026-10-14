//+------------------------------------------------------------------+
//|                                                    ScalperEA.mq5 |
//|                                  MT5 M1 Breakout Confirmatory EA |
//|                                                                  |
//| Conforms to PREREG v1.05 (registered on branch scalper-prereg)   |
//| Multi-Symbol Engine: EURUSD, USDJPY                              |
//| Magic: 20261014 | Volume: 0.01 Lot | Global Concurrency: 1       |
//+------------------------------------------------------------------+
#property copyright "Confirmatory Breakout Scalper"
#property link      ""
#property version   "1.05"
#property strict

#include <Trade\Trade.mqh>

//--- Hard Constants (PREREG §2.1, §2.3, §2.4, §6)
const double MAX_VOLUME       = 0.01;
const ulong  SCALPER_MAGIC    = 20261014;
const int    TIME_STOP_SEC    = 300;
const double TARGET_BRACKET   = 5.0;      // +/-5.0 pips TP/SL
const int    MAX_CONSEC_ERRS  = 5;
const double DAILY_LOSS_STOP  = -30.0;    // -30 pips cumulative net per day (realised + floating)
const int    MAX_TRADES_DAY   = 20;
const double TICK_MAX_AGE_MS  = 3000.0;   // PREREG §2.3.2: connectivity-based gate
const double GATE_CAP         = 0.3;      // PREREG §3.3: gate = min(0.3, p60) <= 0.3
const double GATE_EPS         = 1e-9;     // "<= gate" comparison tolerance (B1-5c)
const int    EXIT_DEAL_WAIT_SEC = 30;     // OUT deal must appear in history within 30 s
const string REG_SERVER       = "ICMarketsEU-Demo";  // ACCOUNT.md section 1
const long   REG_LOGIN        = 53098320;            // ACCOUNT.md section 1
const string ACCOUNT_FILE     = "ACCOUNT.md";        // copied by the operator to Common\Files
const string FILE_TRADES      = "scalper_trades.csv";
const string FILE_ROUNDTRIPS  = "scalper_roundtrips.csv";
const string FILE_SKIPS       = "scalper_skips.csv";
const string KILL_FILE        = "kill_switch.txt";

//--- FSM State Definitions
enum ENUM_SCALPER_STATE
{
   STATE_IDLE,
   STATE_ENTRY_PENDING,
   STATE_IN_POSITION,
   STATE_EXIT_PENDING,
   STATE_HALTED
};

enum ENUM_SIGNAL_TYPE
{
   SIGNAL_NONE,
   SIGNAL_BUY,
   SIGNAL_SELL
};

enum ENUM_HALT_REASON
{
   HALT_NONE = 0,
   HALT_DAILY = 1,        // auto-clears at the next UTC day
   HALT_ERRORS = 2,       // operator investigation required
   HALT_KILL = 3,         // kill switch
   HALT_OPERATIONAL = 4   // missing exit deal, external close, log failure: operator review
};

enum ENUM_EXIT_INTENT
{
   INTENT_NONE = 0,
   INTENT_TIME_STOP = 1,
   INTENT_KILL = 2,
   INTENT_DAILY = 3
};

//--- Input Parameters
input group "=== Scalper Configuration ==="
input bool     InpEvidential        = false;                 // True = Evidential Mode, False = Plumbing Mode
input string   InpRunId             = "";                    // Run identifier (required in Evidential Mode)
input string   InpAccountMdSha256   = "";                    // SHA256 of committed ACCOUNT.md (LF-normalised), 64 lowercase hex
input double   InpGateEURUSD        = 0.3;                   // Spread gate EURUSD in pips (0 < gate <= 0.3)
input double   InpGateUSDJPY        = 0.3;                   // Spread gate USDJPY in pips (0 < gate <= 0.3)
input string   InpNewsFile          = "news_calendar.csv";   // Economic calendar CSV in Common\Files
input ulong    InpMagic             = 20261014;              // Magic number (must equal 20261014)
input int      InpPollIntervalMs    = 50;                    // Polling interval in ms

//--- Global Variables Persistence Keys
#define GV_SCALPER_STATE        "SCALPER_STATE"
#define GV_SCALPER_IN_FLIGHT    "SCALPER_IN_FLIGHT"
#define GV_SCALPER_TICKET       "SCALPER_TICKET"
#define GV_SCALPER_SYMBOL       "SCALPER_SYMBOL"
#define GV_SCALPER_SIDE         "SCALPER_SIDE"
#define GV_SCALPER_OPEN_SERVER  "SCALPER_OPEN_SERVER"
#define GV_SCALPER_REQ_PRICE    "SCALPER_REQ_PRICE"
#define GV_SCALPER_FILL_PRICE   "SCALPER_FILL_PRICE"
#define GV_SCALPER_SIGNAL_PRICE "SCALPER_SIGNAL_PRICE"
#define GV_SCALPER_SPREAD_SIG   "SCALPER_SPREAD_SIG"
#define GV_SCALPER_SPREAD_FILL  "SCALPER_SPREAD_FILL"
#define GV_SCALPER_WINDOW_ID    "SCALPER_WINDOW_ID"
#define GV_SCALPER_LAST_WIN_ID  "SCALPER_LAST_WIN_ID"
#define GV_SCALPER_DAILY_DATE   "SCALPER_DAILY_DATE"
#define GV_SCALPER_DAILY_NET    "SCALPER_DAILY_NET"
#define GV_SCALPER_TRADES_EUR   "SCALPER_TRADES_EUR"
#define GV_SCALPER_TRADES_JPY   "SCALPER_TRADES_JPY"
#define GV_SCALPER_CONSEC_ERR   "SCALPER_CONSEC_ERR"
#define GV_SCALPER_SLIPPAGE     "SCALPER_SLIPPAGE"
#define GV_SCALPER_COMM_ENTRY   "SCALPER_COMM_ENTRY"
#define GV_SCALPER_COMM_OK      "SCALPER_COMM_OK"
#define GV_SCALPER_VOLUME       "SCALPER_VOLUME"
#define GV_SCALPER_SIGNAL_MSC   "SCALPER_SIGNAL_MSC"
#define GV_SCALPER_DISPATCH_MSC "SCALPER_DISPATCH_MSC"
#define GV_SCALPER_FILL_MSC     "SCALPER_FILL_MSC"
#define GV_SCALPER_FILL_SRV_MSC "SCALPER_FILL_SRV_MSC"
#define GV_SCALPER_EVID         "SCALPER_EVID"
#define GV_SCALPER_INTENT       "SCALPER_INTENT"
#define GV_SCALPER_HALT_REASON  "SCALPER_HALT_REASON"
#define GV_SCALPER_RUN_HASH     "SCALPER_RUN_HASH"
#define GV_INSTANCE_LOCK        "SCALPER_INSTANCE_LOCK"

//--- Telemetry Headers (every row carries run_id and account_md_sha256)
#define HDR_TRADES      "run_id,account_md_sha256,timestamp_utc,evidential,window_id,ticket,symbol,side,volume,req_price,fill_price,spread_at_signal,spread_at_fill,slippage_pips,commission_pips,retcode,latency_ms,comment,t_tick_msc,tick_age_ms"
#define HDR_ROUNDTRIPS  "run_id,account_md_sha256,ticket,evidential,window_id,symbol,symbol_gate,side,volume,signal_time_msc,dispatch_time_msc,fill_time_msc,signal_price,fill_price,spread_at_signal,spread_at_fill,slippage_pips,commission_pips,exit_fill_price,exit_reason,hold_ms,gross_pips,net_pips,restart"
#define HDR_SKIPS       "run_id,account_md_sha256,timestamp_utc,evidential,window_id,symbol,reason,details"

//--- Position under management (one global position at most)
struct ScalperPos
{
   ulong    ticket;
   int      symIdx;
   string   symbol;
   string   side;
   datetime openServer;      // entry deal time, trade-server seconds (time-stop clock, D9)
   double   volume;
   double   reqPrice;
   double   fillPrice;
   double   signalPrice;
   double   spreadSig;
   double   spreadFill;
   double   slipPips;
   double   commEntryPips;
   long     windowId;
   ulong    signalMsc;       // UTC epoch ms: close time of the signal bar
   ulong    dispatchMsc;     // UTC epoch ms immediately before OrderSend
   ulong    fillMsc;         // UTC epoch ms of the entry deal
   ulong    fillSrvMsc;      // trade-server epoch ms of the entry deal
   bool     evidential;      // trade-level flag: false once any data anomaly is recorded
   bool     commOk;          // entry commission was read from deal history
   bool     restart;         // trade was recovered after an EA restart
   int      intent;          // ENUM_EXIT_INTENT
   ulong    exitWaitStartMs; // GetTickCount64() when the position was first seen closed
};

struct ExitInfo
{
   double   price;
   double   commMoney;
   bool     commOk;
   ulong    timeSrvMsc;
   ulong    volume;          // unused placeholder kept zero (volume is tracked in ScalperPos)
   int      dealReason;      // ENUM_DEAL_REASON
};

//--- CTrade & State
CTrade             m_trade;
ScalperPos         g_pos;
ENUM_SCALPER_STATE g_state = STATE_IDLE;
int                g_haltReason = HALT_NONE;
bool               g_isEvidential = false;
bool               g_csvFailed = false;
bool               g_killSeen = false;
string             g_runId = "";
string             g_accountSha = "";
int                g_gvBatchDepth = 0;
bool               g_gvDirty = false;

// Symbol Data
string            g_symbols[2] = {"EURUSD", "USDJPY"};
datetime          g_lastBarTimes[2] = {0, 0};
bool              g_rolled[2] = {false, false};
datetime          g_rollBarTime[2] = {0, 0};
ulong             g_lastTickSeenUs[2] = {0, 0};
MqlTick           g_lastTicks[2];

// Risk & Throttling
long              g_lastDispatchedWindowId = -1;
int               g_consecutiveErrors = 0;
double            g_dailyNetPips = 0.0;
datetime          g_currentDayUtc = 0;
int               g_tradesTodayEUR = 0;
int               g_tradesTodayJPY = 0;
datetime          g_lastNewsDegradedDay = 0;
ulong             g_lastBracketTryMs = 0;
ulong             g_lastCloseMsgMs = 0;

// UTC millisecond clock (TimeGMT() has 1 s resolution; sub-second part anchored by the 50 ms poll)
long              g_utcAnchorSec = 0;
ulong             g_utcAnchorTick = 0;

//+------------------------------------------------------------------+
//| GlobalVariable Durability Helpers                                |
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
double GvGet(const string name, double fallback)
{
   if(GlobalVariableCheck(name)) return GlobalVariableGet(name);
   return fallback;
}

//+------------------------------------------------------------------+
//| Instance Lock Helpers (ExecTest Pattern)                         |
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
//| Time helpers (all *_msc telemetry is UTC epoch milliseconds, D20)|
//+------------------------------------------------------------------+
string TimeUtcIso()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                       dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
}

ulong UtcNowMsc()
{
   long s = (long)TimeGMT();
   ulong t = GetTickCount64();
   if(s != g_utcAnchorSec)
   {
      g_utcAnchorSec = s;
      g_utcAnchorTick = t;
   }
   ulong frac = t - g_utcAnchorTick;
   if(frac > 999) frac = 999;
   return (ulong)s * 1000 + frac;
}

long ServerUtcOffsetSec()
{
   double d = (double)((long)TimeTradeServer() - (long)TimeGMT());
   return (long)MathRound(d / 900.0) * 900;
}

ulong ServerMscToUtcMsc(const ulong srvMsc)
{
   return (ulong)((long)srvMsc - ServerUtcOffsetSec() * 1000);
}

//+------------------------------------------------------------------+
//| Symbol helpers                                                   |
//+------------------------------------------------------------------+
double PipSize(const string symbol)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return 10.0 * pt;
   return pt;
}

double SymbolGate(const string symbol)
{
   if(symbol == "EURUSD") return InpGateEURUSD;
   if(symbol == "USDJPY") return InpGateUSDJPY;
   return GATE_CAP;
}

int SymIndex(const string symbol)
{
   for(int i = 0; i < 2; i++)
      if(g_symbols[i] == symbol) return i;
   return -1;
}

// Commission money -> pips at the traded volume (B2-13). Returns -1.0 if the pip value is unavailable.
double CommissionToPips(const string symbol, const double commMoney, const double volume)
{
   if(commMoney == 0.0) return 0.0;
   double tickVal = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSz <= 0.0 || tickVal <= 0.0 || volume <= 0.0) return -1.0;
   double pipValue = tickVal * (PipSize(symbol) / tickSz) * volume;
   if(pipValue <= 0.0) return -1.0;
   return MathAbs(commMoney) / pipValue;
}

//+------------------------------------------------------------------+
//| Append-Only CSV Logging to Common\Files (ANSI, shared read)      |
//+------------------------------------------------------------------+
bool AppendCsvLine(const string filename, const string header, const string line)
{
   int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON |
                                   FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("[LOG ERROR] Could not open %s in Common\\Files. Err: %d", filename, GetLastError());
      PrintFormat("[LOG LOST] %s | %s", filename, line);
      if(g_isEvidential) g_csvFailed = true;   // evidential run halts: no silent loss
      return false;
   }
   if(FileSize(handle) == 0) FileWriteString(handle, header + "\n");
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\n");
   FileFlush(handle);
   FileClose(handle);
   return true;
}

string RunCols()
{
   return StringFormat("%s,%s", g_runId, g_accountSha);
}

void LogSkip(const string symbol, const string reason, const string details, long winId)
{
   string line = StringFormat("%s,%s,%d,%I64d,%s,%s,\"%s\"",
                              RunCols(), TimeUtcIso(), g_isEvidential ? 1 : 0, winId, symbol, reason, details);
   AppendCsvLine(FILE_SKIPS, HDR_SKIPS, line);
   PrintFormat("[SKIP] %s | %s | %s | %s", symbol, reason, details, TimeUtcIso());
}

//+------------------------------------------------------------------+
//| Halting                                                          |
//+------------------------------------------------------------------+
void HaltWith(const int reasonCode, const string msg)
{
   g_state = STATE_HALTED;
   g_haltReason = reasonCode;
   GvBegin();
   GvSet(GV_SCALPER_STATE, (double)STATE_HALTED);
   GvSet(GV_SCALPER_HALT_REASON, (double)reasonCode);
   GvEnd();
   PrintFormat("[HALTED] reason=%d %s", reasonCode, msg);
}

void SetIdle()
{
   g_state = STATE_IDLE;
   g_haltReason = HALT_NONE;
   GvBegin();
   GvSet(GV_SCALPER_STATE, (double)STATE_IDLE);
   GvSet(GV_SCALPER_HALT_REASON, 0.0);
   GvEnd();
}

//+------------------------------------------------------------------+
//| Check Trading Session (PREREG §2.3.3)                            |
//+------------------------------------------------------------------+
bool IsInSession(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);
   if(dt.day_of_week < 1 || dt.day_of_week > 5) return false;
   int secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;
   return (secOfDay >= 7 * 3600 && secOfDay < 16 * 3600);
}

//+------------------------------------------------------------------+
//| Check News Exclusion (PREREG §2.3.4)                             |
//+------------------------------------------------------------------+
bool IsNewsBlocked(const string symbol, datetime gmtNow)
{
   if(FileIsExist(InpNewsFile, FILE_COMMON))
   {
      int h = FileOpen(InpNewsFile, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ, ',');
      if(h != INVALID_HANDLE)
      {
         while(!FileIsEnding(h))
         {
            string tsStr = FileReadString(h);
            string symStr = FileReadString(h);
            if(tsStr == "" || tsStr == "utc_time") continue;

            datetime evtDt = StringToTime(tsStr);
            if(evtDt > 0)
            {
               StringToUpper(symStr);
               if(symStr == "ALL" || symStr == symbol)
               {
                  if(MathAbs((long)gmtNow - (long)evtDt) <= 600) // +/- 10 min, inclusive
                  {
                     FileClose(h);
                     return true;
                  }
               }
            }
         }
         FileClose(h);
         return false;
      }
   }

   // Degraded Fallback Mode: 12:25-12:40 & 13:25-13:40 UTC
   MqlDateTime dt;
   TimeToStruct(gmtNow, dt);
   datetime todayUtc = (datetime)((long)gmtNow - (long)(dt.hour * 3600 + dt.min * 60 + dt.sec));
   if(g_lastNewsDegradedDay != todayUtc)
   {
      g_lastNewsDegradedDay = todayUtc;
      Print("[NEWS DEGRADED] Operating in degraded news filter mode (fixed windows 12:25-12:40 & 13:25-13:40 UTC)");
   }

   if(dt.hour == 12 && dt.min >= 25 && dt.min < 40) return true;
   if(dt.hour == 13 && dt.min >= 25 && dt.min < 40) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Tick Watcher & Tick Age (local observation time, PREREG §2.3.2)  |
//+------------------------------------------------------------------+
void UpdateTickWatcher(int symIdx)
{
   MqlTick tick;
   if(SymbolInfoTick(g_symbols[symIdx], tick))
   {
      if(tick.time_msc != g_lastTicks[symIdx].time_msc ||
         tick.bid != g_lastTicks[symIdx].bid ||
         tick.ask != g_lastTicks[symIdx].ask)
      {
         g_lastTicks[symIdx] = tick;
         g_lastTickSeenUs[symIdx] = GetMicrosecondCount();
      }
   }
}

double GetTickAgeMs(int symIdx)
{
   if(g_lastTickSeenUs[symIdx] == 0) return 999999.0;
   return (double)(GetMicrosecondCount() - g_lastTickSeenUs[symIdx]) / 1000.0;
}

// Bar-roll tracking runs before any early return so a signal bar is evaluated at most once (D4)
void TrackBarRolls()
{
   for(int s = 0; s < 2; s++)
   {
      g_rolled[s] = false;
      datetime curBar = iTime(g_symbols[s], PERIOD_M1, 0);
      if(curBar == 0) continue;
      if(g_lastBarTimes[s] != 0 && curBar != g_lastBarTimes[s])
      {
         g_rolled[s] = true;
         g_rollBarTime[s] = curBar;
      }
      g_lastBarTimes[s] = curBar;
   }
}

//+------------------------------------------------------------------+
//| Evaluate M1 Breakout Signal (PREREG §2.2)                        |
//+------------------------------------------------------------------+
// D1: the registered window [t-20, t-1] with C_{t-1} > max H_{t-i}, i=1..20 is self-contradictory
// (C_{t-1} > H_{t-1} cannot hold). The implemented reading: signal bar t-1 (last completed bar)
// against the 20 completed bars before it (t-2..t-21). Flagged for a PREREG v1.06 clarification.
ENUM_SIGNAL_TYPE CheckBreakoutSignal(int symIdx, double &outSignalPrice)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   // rates[0] is bar 1 (signal bar), rates[1..20] are bars 2..21
   if(CopyRates(g_symbols[symIdx], PERIOD_M1, 1, 21, rates) < 21)
      return SIGNAL_NONE;

   double maxHigh = -DBL_MAX;
   double minLow = DBL_MAX;
   for(int b = 1; b <= 20; b++)
   {
      if(rates[b].high > maxHigh) maxHigh = rates[b].high;
      if(rates[b].low < minLow)   minLow = rates[b].low;
   }

   double closeBar1 = rates[0].close;
   MqlTick tick = g_lastTicks[symIdx];

   if(closeBar1 > maxHigh)
   {
      outSignalPrice = tick.ask;
      return SIGNAL_BUY;
   }
   if(closeBar1 < minLow)
   {
      outSignalPrice = tick.bid;
      return SIGNAL_SELL;
   }
   return SIGNAL_NONE;
}

void ConfigureFilling(const string symbol)
{
   uint filling = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Position state: reset / persist / restore                        |
//+------------------------------------------------------------------+
void ResetPos()
{
   g_pos.ticket = 0;
   g_pos.symIdx = -1;
   g_pos.symbol = "";
   g_pos.side = "";
   g_pos.openServer = 0;
   g_pos.volume = 0.0;
   g_pos.reqPrice = 0.0;
   g_pos.fillPrice = 0.0;
   g_pos.signalPrice = 0.0;
   g_pos.spreadSig = 0.0;
   g_pos.spreadFill = 0.0;
   g_pos.slipPips = 0.0;
   g_pos.commEntryPips = 0.0;
   g_pos.windowId = 0;
   g_pos.signalMsc = 0;
   g_pos.dispatchMsc = 0;
   g_pos.fillMsc = 0;
   g_pos.fillSrvMsc = 0;
   g_pos.evidential = true;
   g_pos.commOk = true;
   g_pos.restart = false;
   g_pos.intent = INTENT_NONE;
   g_pos.exitWaitStartMs = 0;
}

void PersistPosition()
{
   GvBegin();
   GvSet(GV_SCALPER_TICKET, (double)g_pos.ticket);
   GvSet(GV_SCALPER_SYMBOL, (double)g_pos.symIdx);
   GvSet(GV_SCALPER_SIDE, (g_pos.side == "BUY") ? 1.0 : -1.0);
   GvSet(GV_SCALPER_OPEN_SERVER, (double)g_pos.openServer);
   GvSet(GV_SCALPER_VOLUME, g_pos.volume);
   GvSet(GV_SCALPER_REQ_PRICE, g_pos.reqPrice);
   GvSet(GV_SCALPER_FILL_PRICE, g_pos.fillPrice);
   GvSet(GV_SCALPER_SIGNAL_PRICE, g_pos.signalPrice);
   GvSet(GV_SCALPER_SPREAD_SIG, g_pos.spreadSig);
   GvSet(GV_SCALPER_SPREAD_FILL, g_pos.spreadFill);
   GvSet(GV_SCALPER_SLIPPAGE, g_pos.slipPips);
   GvSet(GV_SCALPER_COMM_ENTRY, g_pos.commEntryPips);
   GvSet(GV_SCALPER_COMM_OK, g_pos.commOk ? 1.0 : 0.0);
   GvSet(GV_SCALPER_WINDOW_ID, (double)g_pos.windowId);
   GvSet(GV_SCALPER_SIGNAL_MSC, (double)g_pos.signalMsc);
   GvSet(GV_SCALPER_DISPATCH_MSC, (double)g_pos.dispatchMsc);
   GvSet(GV_SCALPER_FILL_MSC, (double)g_pos.fillMsc);
   GvSet(GV_SCALPER_FILL_SRV_MSC, (double)g_pos.fillSrvMsc);
   GvSet(GV_SCALPER_EVID, g_pos.evidential ? 1.0 : 0.0);
   GvSet(GV_SCALPER_INTENT, (double)g_pos.intent);
   GvEnd();
}

void ClearPositionGvs()
{
   GvBegin();
   GvDel(GV_SCALPER_TICKET);
   GvDel(GV_SCALPER_SYMBOL);
   GvDel(GV_SCALPER_SIDE);
   GvDel(GV_SCALPER_OPEN_SERVER);
   GvDel(GV_SCALPER_VOLUME);
   GvDel(GV_SCALPER_REQ_PRICE);
   GvDel(GV_SCALPER_FILL_PRICE);
   GvDel(GV_SCALPER_SIGNAL_PRICE);
   GvDel(GV_SCALPER_SPREAD_SIG);
   GvDel(GV_SCALPER_SPREAD_FILL);
   GvDel(GV_SCALPER_SLIPPAGE);
   GvDel(GV_SCALPER_COMM_ENTRY);
   GvDel(GV_SCALPER_COMM_OK);
   GvDel(GV_SCALPER_WINDOW_ID);
   GvDel(GV_SCALPER_SIGNAL_MSC);
   GvDel(GV_SCALPER_DISPATCH_MSC);
   GvDel(GV_SCALPER_FILL_MSC);
   GvDel(GV_SCALPER_FILL_SRV_MSC);
   GvDel(GV_SCALPER_EVID);
   GvDel(GV_SCALPER_INTENT);
   GvDel(GV_SCALPER_IN_FLIGHT);
   GvEnd();
}

void RestorePositionFromGvs(const ulong ticket)
{
   ResetPos();
   g_pos.ticket = ticket;
   g_pos.symIdx = (int)GvGet(GV_SCALPER_SYMBOL, -1.0);
   if(g_pos.symIdx >= 0 && g_pos.symIdx < 2) g_pos.symbol = g_symbols[g_pos.symIdx];
   g_pos.side = (GvGet(GV_SCALPER_SIDE, 1.0) > 0.0) ? "BUY" : "SELL";
   g_pos.openServer = (datetime)GvGet(GV_SCALPER_OPEN_SERVER, 0.0);
   g_pos.volume = GvGet(GV_SCALPER_VOLUME, MAX_VOLUME);
   g_pos.reqPrice = GvGet(GV_SCALPER_REQ_PRICE, 0.0);
   g_pos.fillPrice = GvGet(GV_SCALPER_FILL_PRICE, 0.0);
   g_pos.signalPrice = GvGet(GV_SCALPER_SIGNAL_PRICE, 0.0);
   g_pos.spreadSig = GvGet(GV_SCALPER_SPREAD_SIG, 0.0);
   g_pos.spreadFill = GvGet(GV_SCALPER_SPREAD_FILL, 0.0);
   g_pos.slipPips = GvGet(GV_SCALPER_SLIPPAGE, 0.0);
   g_pos.commEntryPips = GvGet(GV_SCALPER_COMM_ENTRY, 0.0);
   g_pos.commOk = (GvGet(GV_SCALPER_COMM_OK, 0.0) > 0.5);
   g_pos.windowId = (long)GvGet(GV_SCALPER_WINDOW_ID, 0.0);
   g_pos.signalMsc = (ulong)GvGet(GV_SCALPER_SIGNAL_MSC, 0.0);
   g_pos.dispatchMsc = (ulong)GvGet(GV_SCALPER_DISPATCH_MSC, 0.0);
   g_pos.fillMsc = (ulong)GvGet(GV_SCALPER_FILL_MSC, 0.0);
   g_pos.fillSrvMsc = (ulong)GvGet(GV_SCALPER_FILL_SRV_MSC, 0.0);
   g_pos.evidential = (GvGet(GV_SCALPER_EVID, 1.0) > 0.5);
   g_pos.intent = (int)GvGet(GV_SCALPER_INTENT, 0.0);
   g_pos.restart = true;
}

//+------------------------------------------------------------------+
//| History helpers (entry deal, exit deal)                          |
//+------------------------------------------------------------------+
bool LoadDeal(const ulong dealTicket)
{
   for(int i = 0; i < 10; i++)
   {
      if(HistoryDealSelect(dealTicket)) return true;
      Sleep(50);
   }
   return false;
}

// Spread (pips) of the last tick at or before the fill time; falls back to the dispatch spread (D20)
double SpreadAtFill(const string sym, const ulong fillSrvMsc, const double fallbackPips)
{
   MqlTick ticks[];
   ulong fromMsc = (fillSrvMsc > 5000) ? fillSrvMsc - 5000 : 0;
   int n = CopyTicksRange(sym, ticks, COPY_TICKS_ALL, fromMsc, fillSrvMsc);
   for(int i = n - 1; i >= 0; i--)
   {
      if((ulong)ticks[i].time_msc <= fillSrvMsc && ticks[i].ask > 0.0 && ticks[i].bid > 0.0)
         return (ticks[i].ask - ticks[i].bid) / PipSize(sym);
   }
   return fallbackPips;
}

// Reads the selected entry deal into g_pos (price, time, volume, commission)
void ReadEntryDeal(const ulong dealTicket)
{
   g_pos.fillPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   g_pos.volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   g_pos.fillSrvMsc = (ulong)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
   g_pos.fillMsc = ServerMscToUtcMsc(g_pos.fillSrvMsc);
   g_pos.openServer = (datetime)(g_pos.fillSrvMsc / 1000);
   double commMoney = 0.0;
   g_pos.commOk = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION, commMoney);
   double cp = g_pos.commOk ? CommissionToPips(g_pos.symbol, commMoney, g_pos.volume) : -1.0;
   if(cp < 0.0)
   {
      g_pos.commOk = false;
      cp = 0.0;
   }
   g_pos.commEntryPips = cp;
}

// Finds the OUT deal of a closed position via its position id (D11: never fabricate exits)
bool FindExitDeal(const ulong posId, ExitInfo &x)
{
   if(!HistorySelectByPosition(posId)) return false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT) continue;
      x.price = HistoryDealGetDouble(d, DEAL_PRICE);
      x.timeSrvMsc = (ulong)HistoryDealGetInteger(d, DEAL_TIME_MSC);
      x.dealReason = (int)HistoryDealGetInteger(d, DEAL_REASON);
      x.volume = 0;
      x.commOk = HistoryDealGetDouble(d, DEAL_COMMISSION, x.commMoney);
      return true;
   }
   return false;
}

// Position ticket of the only open position carrying our magic (0 if none, ULONG_MAX if several)
int ScanMagicPositions(ulong &tickets[])
{
   ArrayResize(tickets, 0);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != SCALPER_MAGIC) continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = t;
   }
   return ArraySize(tickets);
}

//+------------------------------------------------------------------+
//| Reconcile Closed Roundtrip & Log Telemetry                       |
//+------------------------------------------------------------------+
string ClassifyExit(const ExitInfo &x)
{
   if(x.dealReason == DEAL_REASON_TP) return "TAKE_PROFIT";
   if(x.dealReason == DEAL_REASON_SL) return "STOP_LOSS";
   if(x.dealReason == DEAL_REASON_EXPERT)
   {
      if(g_pos.intent == INTENT_TIME_STOP) return "TIME_STOP";
      if(g_pos.intent == INTENT_KILL)      return "KILL_SWITCH";
      if(g_pos.intent == INTENT_DAILY)     return "DAILY_STOP";
   }
   return "EXTERNAL";
}

bool IsRegisteredExit(const string reason)
{
   return (reason == "TAKE_PROFIT" || reason == "STOP_LOSS" || reason == "TIME_STOP");
}

void ClearPositionAfterClose()
{
   GvBegin();
   GvSet(GV_SCALPER_DAILY_NET, g_dailyNetPips);
   GvSet(GV_SCALPER_TRADES_EUR, (double)g_tradesTodayEUR);
   GvSet(GV_SCALPER_TRADES_JPY, (double)g_tradesTodayJPY);
   ClearPositionGvs();
   GvEnd();
}

void FinalizeClose(const ExitInfo &x)
{
   string sym = g_pos.symbol;
   double pip = PipSize(sym);
   string reason = ClassifyExit(x);

   double exitCommPips = x.commOk ? CommissionToPips(sym, x.commMoney, g_pos.volume) : -1.0;
   bool commKnown = g_pos.commOk && (exitCommPips >= 0.0);
   if(exitCommPips < 0.0) exitCommPips = 0.0;

   double grossPips = (g_pos.side == "BUY") ? (x.price - g_pos.fillPrice) / pip : (g_pos.fillPrice - x.price) / pip;
   double commPips = (g_pos.commEntryPips + exitCommPips) / 2.0;     // mean per-side commission (D6)
   double netPips = grossPips - 2.0 * commPips;                       // PREREG §2.5
   ulong exitMsc = ServerMscToUtcMsc(x.timeSrvMsc);
   long holdMs = (long)x.timeSrvMsc - (long)g_pos.fillSrvMsc;

   bool evid = g_isEvidential && g_pos.evidential && commKnown && IsRegisteredExit(reason);
   g_dailyNetPips += netPips;
   if(sym == "EURUSD") g_tradesTodayEUR++;
   if(sym == "USDJPY") g_tradesTodayJPY++;
   ClearPositionAfterClose();

   string rtLine = StringFormat("%s,%I64u,%d,%I64d,%s,%.3f,%s,%.2f,%I64u,%I64u,%I64u,%.5f,%.5f,%.3f,%.3f,%.3f,%.5f,%.5f,%s,%I64d,%.3f,%.3f,%d",
                                RunCols(), g_pos.ticket, evid ? 1 : 0, g_pos.windowId, sym, SymbolGate(sym),
                                g_pos.side, g_pos.volume, g_pos.signalMsc, g_pos.dispatchMsc, g_pos.fillMsc,
                                g_pos.signalPrice, g_pos.fillPrice, g_pos.spreadSig, g_pos.spreadFill,
                                g_pos.slipPips, commPips, x.price, reason, holdMs, grossPips, netPips,
                                g_pos.restart ? 1 : 0);
   AppendCsvLine(FILE_ROUNDTRIPS, HDR_ROUNDTRIPS, rtLine);
   PrintFormat("[ROUNDTRIP COMPLETE] Ticket %I64u | %s %s | Gross: %.2f | Net: %.2f pips | Exit: %s | exit_utc_msc %I64u | DailyNet: %.2f",
               g_pos.ticket, sym, g_pos.side, grossPips, netPips, reason, exitMsc, g_dailyNetPips);
   if(!commKnown)
      LogSkip(sym, "commission_unavailable", "commission not readable from deal history; row written evidential=0", g_pos.windowId);

   int intent = g_pos.intent;
   ResetPos();
   ResolveStateAfterClose(reason, intent);
}

void ResolveStateAfterClose(const string reason, const int intent)
{
   if(reason == "KILL_SWITCH" || intent == INTENT_KILL) HaltWith(HALT_KILL, "kill switch liquidation complete");
   else if(reason == "EXTERNAL") HaltWith(HALT_OPERATIONAL, "external close (stop-out/manual): operator review");
   else if(reason == "DAILY_STOP" || g_dailyNetPips <= DAILY_LOSS_STOP)
      HaltWith(HALT_DAILY, StringFormat("daily net %.2f <= %.2f, halted until next UTC day", g_dailyNetPips, DAILY_LOSS_STOP));
   else SetIdle();
}

//+------------------------------------------------------------------+
//| SL/TP bracket (PREREG §2.4), retried and re-applied (D8)         |
//+------------------------------------------------------------------+
bool ApplyBracket()
{
   string sym = g_pos.symbol;
   double pip = PipSize(sym);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   bool buy = (g_pos.side == "BUY");
   double sl = NormalizeDouble(buy ? g_pos.fillPrice - TARGET_BRACKET * pip : g_pos.fillPrice + TARGET_BRACKET * pip, digits);
   double tp = NormalizeDouble(buy ? g_pos.fillPrice + TARGET_BRACKET * pip : g_pos.fillPrice - TARGET_BRACKET * pip, digits);

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      m_trade.PositionModify(g_pos.ticket, sl, tp);
      uint rc = m_trade.ResultRetcode();
      if(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_NO_CHANGES)
      {
         PrintFormat("[POSITION MODIFY OK] Ticket %I64u SL/TP at +/-5.0 pips from fill %.5f (SL: %.5f, TP: %.5f)",
                     g_pos.ticket, g_pos.fillPrice, sl, tp);
         return true;
      }
      PrintFormat("[POSITION MODIFY WARNING] Ticket %I64u attempt %d retcode %d", g_pos.ticket, attempt, rc);
      Sleep(100);
   }
   return false;
}

// Re-applies SL/TP when the live position has none (after a failed modify or a restart), at most once per second
void EnsureBracket()
{
   if(PositionGetDouble(POSITION_SL) > 0.0 && PositionGetDouble(POSITION_TP) > 0.0) return;
   ulong nowMs = GetTickCount64();
   if(nowMs - g_lastBracketTryMs < 1000) return;
   g_lastBracketTryMs = nowMs;
   ApplyBracket();
}

//+------------------------------------------------------------------+
//| Position monitoring: time stop, daily stop, exits                |
//+------------------------------------------------------------------+
double FloatingNetPips()
{
   MqlTick t;
   if(!SymbolInfoTick(g_pos.symbol, t)) return 0.0;
   double pip = PipSize(g_pos.symbol);
   double gross = (g_pos.side == "BUY") ? (t.bid - g_pos.fillPrice) / pip : (g_pos.fillPrice - t.ask) / pip;
   return gross - 2.0 * g_pos.commEntryPips;
}

void SetIntent(const int intent)
{
   g_pos.intent = intent;
   g_state = STATE_EXIT_PENDING;
   GvBegin();
   GvSet(GV_SCALPER_INTENT, (double)intent);
   GvSet(GV_SCALPER_STATE, (double)STATE_EXIT_PENDING);
   GvEnd();
}

// PositionClose is only a success if retcode is DONE and the position is gone (D10)
void AttemptClose()
{
   ConfigureFilling(g_pos.symbol);
   m_trade.PositionClose(g_pos.ticket);
   uint rc = m_trade.ResultRetcode();
   if(rc == TRADE_RETCODE_DONE && !PositionSelectByTicket(g_pos.ticket))
   {
      HandleClosedPosition();
      return;
   }
   ulong nowMs = GetTickCount64();
   if(nowMs - g_lastCloseMsgMs >= 1000)
   {
      g_lastCloseMsgMs = nowMs;
      PrintFormat("[CLOSE RETRY] ticket %I64u retcode %d, retrying next poll", g_pos.ticket, rc);
   }
}

void MonitorOpenPosition()
{
   EnsureBracket();
   if(g_pos.intent == INTENT_NONE)
   {
      if(g_dailyNetPips + FloatingNetPips() <= DAILY_LOSS_STOP)
      {
         PrintFormat("[DAILY STOP] realised %.2f + floating <= %.2f: liquidating ticket %I64u", g_dailyNetPips, DAILY_LOSS_STOP, g_pos.ticket);
         SetIntent(INTENT_DAILY);
      }
      else if((long)(TimeTradeServer() - g_pos.openServer) >= TIME_STOP_SEC)
      {
         PrintFormat("[TIME STOP] %d s since entry deal on ticket %I64u: closing at market", TIME_STOP_SEC, g_pos.ticket);
         SetIntent(INTENT_TIME_STOP);
      }
   }
   if(g_pos.intent != INTENT_NONE) AttemptClose();
}

void HandleClosedPosition()
{
   ExitInfo x;
   x.price = 0.0; x.commMoney = 0.0; x.commOk = false; x.timeSrvMsc = 0; x.volume = 0; x.dealReason = 0;
   if(FindExitDeal(g_pos.ticket, x))
   {
      FinalizeClose(x);
      return;
   }
   if(g_pos.exitWaitStartMs == 0) g_pos.exitWaitStartMs = GetTickCount64();
   if(GetTickCount64() - g_pos.exitWaitStartMs >= (ulong)EXIT_DEAL_WAIT_SEC * 1000)
   {
      LogSkip(g_pos.symbol, "exit_deal_missing", StringFormat("no OUT deal for position %I64u after %d s", g_pos.ticket, EXIT_DEAL_WAIT_SEC), g_pos.windowId);
      HaltWith(HALT_OPERATIONAL, "exit deal missing: operational INVALID evidence");
   }
}

void MonitorPosition()
{
   if(g_pos.ticket == 0)
   {
      SetIdle();
      return;
   }
   if(PositionSelectByTicket(g_pos.ticket)) MonitorOpenPosition();
   else HandleClosedPosition();
}

//+------------------------------------------------------------------+
//| External Kill Switch Check (PREREG §6.4)                         |
//+------------------------------------------------------------------+
void CheckKillSwitch()
{
   if(!FileIsExist(KILL_FILE, FILE_COMMON)) return;
   if(g_killSeen) return;
   g_killSeen = true;
   Print("[KILL SWITCH] Detected kill_switch.txt in Common\\Files. Halting trading immediately.");
   if(g_pos.ticket > 0 && (g_state == STATE_IN_POSITION || g_state == STATE_EXIT_PENDING))
      SetIntent(INTENT_KILL);               // closed and logged by MonitorPosition, then HALTED
   else
      HaltWith(HALT_KILL, "kill_switch.txt present");
}

//+------------------------------------------------------------------+
//| Reset Daily Tracking on UTC Boundary                             |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime gmtNow = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmtNow, dt);
   datetime todayUtc = (datetime)((long)gmtNow - (long)(dt.hour * 3600 + dt.min * 60 + dt.sec));
   if(g_currentDayUtc == todayUtc) return;

   g_currentDayUtc = todayUtc;
   g_dailyNetPips = 0.0;
   g_tradesTodayEUR = 0;
   g_tradesTodayJPY = 0;
   GvBegin();
   GvSet(GV_SCALPER_DAILY_DATE, (double)g_currentDayUtc);
   GvSet(GV_SCALPER_DAILY_NET, 0.0);
   GvSet(GV_SCALPER_TRADES_EUR, 0.0);
   GvSet(GV_SCALPER_TRADES_JPY, 0.0);
   GvEnd();

   // Only a daily-loss halt clears at the UTC boundary; error/kill/operational halts need the operator
   if(g_state == STATE_HALTED && g_haltReason == HALT_DAILY && !FileIsExist(KILL_FILE, FILE_COMMON))
   {
      SetIdle();
      PrintFormat("[DAILY RESET] New UTC Day %04d-%02d-%02d. Resuming STATE_IDLE.", dt.year, dt.mon, dt.day);
   }
}

//+------------------------------------------------------------------+
//| Order dispatch                                                   |
//+------------------------------------------------------------------+
// Spread/tick gates shared by signal time and dispatch time (D2). Returns "" when all pass.
string GateFailure(const int symIdx, const MqlTick &tick, const double ageMs, double &spreadPips)
{
   string sym = g_symbols[symIdx];
   spreadPips = (tick.ask - tick.bid) / PipSize(sym);
   double gate = SymbolGate(sym);
   if(ageMs > TICK_MAX_AGE_MS)
      return StringFormat("stale_tick|tick age %.1f ms > %d ms", ageMs, (int)TICK_MAX_AGE_MS);
   if(spreadPips <= 0.0)
      return StringFormat("zero_spread|spread %.3f <= 0", spreadPips);
   if(spreadPips > gate + GATE_EPS)
      return StringFormat("spread_gate|spread %.3f > gate %.3f", spreadPips, gate);
   return "";
}

bool SkipOnGate(const int symIdx, const string failure, const long winId)
{
   if(failure == "") return false;
   string parts[];
   StringSplit(failure, '|', parts);
   LogSkip(g_symbols[symIdx], parts[0], (ArraySize(parts) > 1 ? parts[1] : ""), winId);
   return true;
}

void LogOrderReject(const int symIdx, const ENUM_SIGNAL_TYPE sigType, const double reqPrice, const double spreadSig,
                    const double spreadDispatch, const uint retcode, const double latencyMs, const MqlTick &tick,
                    const double ageMs, const long winId)
{
   string line = StringFormat("%s,%s,%d,%I64d,0,%s,%s,%.2f,%.5f,0.0,%.3f,%.3f,0.0,0.0,%d,%.1f,\"%s\",%I64d,%.1f",
                              RunCols(), TimeUtcIso(), g_isEvidential ? 1 : 0, winId, g_symbols[symIdx],
                              (sigType == SIGNAL_BUY ? "BUY" : "SELL"), MAX_VOLUME, reqPrice, spreadSig,
                              spreadDispatch, retcode, latencyMs, m_trade.ResultComment(), (long)tick.time_msc, ageMs);
   AppendCsvLine(FILE_TRADES, HDR_TRADES, line);
}

void HandleRejectedOrder(const int symIdx, const ENUM_SIGNAL_TYPE sigType, const double reqPrice, const double spreadSig,
                         const double spreadDispatch, const uint retcode, const double latencyMs, const MqlTick &tick,
                         const double ageMs, const long winId)
{
   g_consecutiveErrors++;
   GvSet(GV_SCALPER_CONSEC_ERR, (double)g_consecutiveErrors);
   PrintFormat("[ORDER REJECT] Retcode: %d, Err: %d, Consec: %d", retcode, GetLastError(), g_consecutiveErrors);
   LogOrderReject(symIdx, sigType, reqPrice, spreadSig, spreadDispatch, retcode, latencyMs, tick, ageMs, winId);
   ResetPos();
   GvDel(GV_SCALPER_IN_FLIGHT);
   if(g_consecutiveErrors >= MAX_CONSEC_ERRS)
      HaltWith(HALT_ERRORS, StringFormat("%d consecutive order errors", g_consecutiveErrors));
   else
      SetIdle();
}

// Locates the position id behind an accepted order when the entry deal cannot be read
ulong FindPositionByMagic(const string sym)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == SCALPER_MAGIC && PositionGetString(POSITION_SYMBOL) == sym) return t;
   }
   return 0;
}

// Reads the entry deal: price, time, volume, commission, position id (D6, D7). Anomalies clear g_pos.evidential.
void CaptureFill(const int symIdx, const double dispatchSpread)
{
   ulong dealTicket = m_trade.ResultDeal();
   g_pos.ticket = m_trade.ResultOrder();
   if(dealTicket > 0 && LoadDeal(dealTicket))
   {
      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId > 0) g_pos.ticket = posId;
      ReadEntryDeal(dealTicket);
   }
   else
   {
      g_pos.evidential = false;
      g_pos.commOk = false;
      g_pos.fillPrice = m_trade.ResultPrice();
      g_pos.volume = m_trade.ResultVolume();
      g_pos.fillMsc = g_pos.dispatchMsc;
      g_pos.fillSrvMsc = (ulong)TimeTradeServer() * 1000;
      g_pos.openServer = TimeTradeServer();
      ulong t = FindPositionByMagic(g_pos.symbol);
      if(t > 0) g_pos.ticket = t;
      LogSkip(g_pos.symbol, "entry_deal_missing", "entry deal not found in history; fill from ResultPrice, evidential=0", g_pos.windowId);
   }
   g_pos.spreadFill = SpreadAtFill(g_pos.symbol, g_pos.fillSrvMsc, dispatchSpread);
}

void LogEntryFill(const uint retcode, const double latencyMs, const MqlTick &tick, const double ageMs)
{
   string line = StringFormat("%s,%s,%d,%I64d,%I64u,%s,%s,%.2f,%.5f,%.5f,%.3f,%.3f,%.3f,%.3f,%d,%.1f,\"%s\",%I64d,%.1f",
                              RunCols(), TimeUtcIso(), (g_isEvidential && g_pos.evidential) ? 1 : 0, g_pos.windowId,
                              g_pos.ticket, g_pos.symbol, g_pos.side, g_pos.volume, g_pos.reqPrice, g_pos.fillPrice,
                              g_pos.spreadSig, g_pos.spreadFill, g_pos.slipPips, g_pos.commEntryPips, retcode,
                              latencyMs, "fill_entry", (long)tick.time_msc, ageMs);
   AppendCsvLine(FILE_TRADES, HDR_TRADES, line);
}

bool DispatchOrder(const int symIdx, const ENUM_SIGNAL_TYPE sigType, const double signalPrice,
                   const double spreadSig, const long winId, const ulong signalMsc)
{
   string sym = g_symbols[symIdx];
   ConfigureFilling(sym);
   double pip = PipSize(sym);

   // Dispatch-time gates (D2): same spread/tick tests as at signal time
   UpdateTickWatcher(symIdx);
   MqlTick tick = g_lastTicks[symIdx];
   double ageMs = GetTickAgeMs(symIdx);
   double spreadPips = 0.0;
   if(SkipOnGate(symIdx, GateFailure(symIdx, tick, ageMs, spreadPips), winId)) return false;

   // Consume the window BEFORE OrderSend, persisted: at most one OrderSend per window (D5)
   bool buy = (sigType == SIGNAL_BUY);
   double reqPrice = buy ? tick.ask : tick.bid;
   ResetPos();
   g_pos.symIdx = symIdx;
   g_pos.symbol = sym;
   g_pos.side = buy ? "BUY" : "SELL";
   g_pos.windowId = winId;
   g_pos.signalMsc = signalMsc;
   g_pos.signalPrice = signalPrice;
   g_pos.spreadSig = spreadSig;
   g_pos.reqPrice = reqPrice;
   g_pos.spreadFill = spreadPips;       // dispatch spread, replaced by the fill-time tick spread
   g_pos.volume = MAX_VOLUME;
   g_lastDispatchedWindowId = winId;
   g_state = STATE_ENTRY_PENDING;
   g_pos.dispatchMsc = UtcNowMsc();
   GvBegin();
   GvSet(GV_SCALPER_LAST_WIN_ID, (double)winId);
   GvSet(GV_SCALPER_STATE, (double)STATE_ENTRY_PENDING);
   GvSet(GV_SCALPER_IN_FLIGHT, 1.0);
   GvSet(GV_SCALPER_SYMBOL, (double)symIdx);
   GvSet(GV_SCALPER_SIDE, buy ? 1.0 : -1.0);
   GvSet(GV_SCALPER_REQ_PRICE, reqPrice);
   GvSet(GV_SCALPER_SIGNAL_PRICE, signalPrice);
   GvSet(GV_SCALPER_SPREAD_SIG, spreadSig);
   GvSet(GV_SCALPER_SPREAD_FILL, spreadPips);
   GvSet(GV_SCALPER_WINDOW_ID, (double)winId);
   GvSet(GV_SCALPER_SIGNAL_MSC, (double)signalMsc);
   GvSet(GV_SCALPER_DISPATCH_MSC, (double)g_pos.dispatchMsc);
   GvEnd();

   ulong dispatchStartMs = GetTickCount64();
   bool sent = buy ? m_trade.Buy(MAX_VOLUME, sym, reqPrice, 0.0, 0.0, "Scalper v1.05")
                   : m_trade.Sell(MAX_VOLUME, sym, reqPrice, 0.0, 0.0, "Scalper v1.05");
   double latencyMs = (double)(GetTickCount64() - dispatchStartMs);
   uint retcode = m_trade.ResultRetcode();

   bool accepted = (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL);
   if(!sent || !accepted)
   {
      HandleRejectedOrder(symIdx, sigType, reqPrice, spreadSig, spreadPips, retcode, latencyMs, tick, ageMs, winId);
      return false;
   }

   g_consecutiveErrors = 0;
   GvSet(GV_SCALPER_CONSEC_ERR, 0.0);
   CaptureFill(symIdx, spreadPips);
   g_pos.slipPips = buy ? (g_pos.fillPrice - reqPrice) / pip : (reqPrice - g_pos.fillPrice) / pip;
   if(retcode == TRADE_RETCODE_DONE_PARTIAL || g_pos.volume < MAX_VOLUME - 1e-9)
   {
      g_pos.evidential = false;     // D16: partial fill is tracked at its real volume, flagged for operator review
      LogSkip(sym, "partial_fill", StringFormat("filled volume %.2f of %.2f, retcode %d", g_pos.volume, MAX_VOLUME, retcode), winId);
   }

   g_state = STATE_IN_POSITION;
   PersistPosition();
   GvBegin();
   GvSet(GV_SCALPER_STATE, (double)STATE_IN_POSITION);
   GvSet(GV_SCALPER_IN_FLIGHT, 0.0);
   GvEnd();
   LogEntryFill(retcode, latencyMs, tick, ageMs);
   if(PositionSelectByTicket(g_pos.ticket)) ApplyBracket();
   return true;
}

//+------------------------------------------------------------------+
//| Signal handling at the bar roll                                  |
//+------------------------------------------------------------------+
bool TryDispatchSignal(const int s, const ENUM_SIGNAL_TYPE sig, const double sigPrice, const datetime gmtNow)
{
   string sym = g_symbols[s];
   // Signal time = close of the signal bar = open of the new bar, converted to UTC (D20)
   long signalSec = (long)g_rollBarTime[s] - ServerUtcOffsetSec();
   long winId = signalSec / 300;
   ulong signalMsc = (ulong)signalSec * 1000;
   PrintFormat("[SIGNAL DETECTED] %s %s at %.5f (window_id: %I64d, signal_msc: %I64u)",
               sym, (sig == SIGNAL_BUY ? "BUY" : "SELL"), sigPrice, winId, signalMsc);

   if(winId <= g_lastDispatchedWindowId)
   {
      LogSkip(sym, "window_consumed", "an order was already dispatched in this 5-minute window", winId);
      return false;
   }
   int tradesToday = (sym == "EURUSD") ? g_tradesTodayEUR : g_tradesTodayJPY;
   if(tradesToday >= MAX_TRADES_DAY)
   {
      LogSkip(sym, "daily_cap", StringFormat("%d trades today", tradesToday), winId);
      return false;
   }
   if(IsNewsBlocked(sym, gmtNow))
   {
      LogSkip(sym, "news_blocked", "high-impact news window", winId);
      return false;
   }

   // Signal-time gates (D2) on the signal-time tick
   UpdateTickWatcher(s);
   MqlTick sigTick = g_lastTicks[s];
   double spreadSig = 0.0;
   if(SkipOnGate(s, GateFailure(s, sigTick, GetTickAgeMs(s), spreadSig), winId)) return false;
   return DispatchOrder(s, sig, sigPrice, spreadSig, winId, signalMsc);
}

void EvaluateSignals(const datetime gmtNow)
{
   for(int s = 0; s < 2; s++)
   {
      if(!g_rolled[s]) continue;               // evaluate only on the poll where the M1 bar rolled (D4)
      double sigPrice = 0.0;
      ENUM_SIGNAL_TYPE sig = CheckBreakoutSignal(s, sigPrice);
      if(sig == SIGNAL_NONE) continue;
      if(TryDispatchSignal(s, sig, sigPrice, gmtNow)) break;
   }
}

//+------------------------------------------------------------------+
//| Evidential-mode validation (D17, D18)                            |
//+------------------------------------------------------------------+
bool IsHex64Lower(const string s)
{
   if(StringLen(s) != 64) return false;
   for(int i = 0; i < 64; i++)
   {
      ushort c = StringGetCharacter(s, i);
      bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      if(!ok) return false;
   }
   return true;
}

bool IsValidRunId(const string s)
{
   if(StringLen(s) == 0 || StringLen(s) > 64) return false;
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-' || c == '.';
      if(!ok) return false;
   }
   return true;
}

// SHA256 over the LF-normalised bytes of Common\Files\ACCOUNT.md (CRLF -> LF), lowercase hex
bool ComputeAccountSha(string &hexOut)
{
   int h = FileOpen(ACCOUNT_FILE, FILE_READ | FILE_BIN | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return false;
   int size = (int)FileSize(h);
   uchar raw[];
   ArrayResize(raw, size);
   uint got = FileReadArray(h, raw, 0, size);
   FileClose(h);
   if((int)got != size || size <= 0) return false;

   uchar norm[];
   ArrayResize(norm, size);
   int n = 0;
   for(int i = 0; i < size; i++)
   {
      if(raw[i] == 13 && i + 1 < size && raw[i + 1] == 10) continue;
      norm[n] = raw[i];
      n++;
   }
   ArrayResize(norm, n);

   uchar key[];
   uchar digest[];
   if(CryptEncode(CRYPT_HASH_SHA256, norm, key, digest) <= 0) return false;
   hexOut = "";
   for(int i = 0; i < ArraySize(digest); i++) hexOut += StringFormat("%02x", digest[i]);
   return true;
}

bool ValidateGates()
{
   double gates[2];
   gates[0] = InpGateEURUSD;
   gates[1] = InpGateUSDJPY;
   for(int i = 0; i < 2; i++)
   {
      if(!(gates[i] > 0.0 && gates[i] <= GATE_CAP + GATE_EPS))
      {
         PrintFormat("[EVIDENTIAL REFUSED] Gate %s = %.4f must satisfy 0 < gate <= %.1f", g_symbols[i], gates[i], GATE_CAP);
         return false;
      }
   }
   return true;
}

bool ValidateEvidential()
{
   string srv = AccountInfoString(ACCOUNT_SERVER);
   long logn = AccountInfoInteger(ACCOUNT_LOGIN);
   ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);

   if(srv != REG_SERVER || logn != REG_LOGIN)
   {
      PrintFormat("[EVIDENTIAL REFUSED] Account mismatch: expected %s / %I64d, got '%s' / %I64d", REG_SERVER, REG_LOGIN, srv, logn);
      return false;
   }
   if(StringFind(srv, "MetaQuotes") >= 0 || mode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("[EVIDENTIAL REFUSED] Account must be a true (non-MetaQuotes) demo account");
      return false;
   }
   if(!IsValidRunId(InpRunId))
   {
      Print("[EVIDENTIAL REFUSED] InpRunId is required (1-64 chars of A-Z a-z 0-9 _ - .)");
      return false;
   }
   if(!ValidateGates()) return false;
   if(!IsHex64Lower(InpAccountMdSha256))
   {
      Print("[EVIDENTIAL REFUSED] InpAccountMdSha256 must be 64 lowercase hex characters");
      return false;
   }
   string computed = "";
   if(!ComputeAccountSha(computed))
   {
      PrintFormat("[EVIDENTIAL REFUSED] Cannot read %s from Common\\Files (copy the committed ACCOUNT.md there)", ACCOUNT_FILE);
      return false;
   }
   PrintFormat("[ACCOUNT.md] computed SHA256 (LF-normalised): %s", computed);
   if(computed != InpAccountMdSha256)
   {
      Print("[EVIDENTIAL REFUSED] ACCOUNT.md SHA256 differs from InpAccountMdSha256");
      return false;
   }
   g_accountSha = computed;
   return true;
}

double RunHash(const string s)
{
   double h = 7.0;
   for(int i = 0; i < StringLen(s); i++) h = MathMod(h * 131.0 + (double)StringGetCharacter(s, i), 2147483629.0);
   return h;
}

//+------------------------------------------------------------------+
//| Restart recovery (D15)                                           |
//+------------------------------------------------------------------+
void RestoreCounters()
{
   g_lastDispatchedWindowId = (long)GvGet(GV_SCALPER_LAST_WIN_ID, -1.0);
   g_dailyNetPips = GvGet(GV_SCALPER_DAILY_NET, 0.0);
   g_consecutiveErrors = (int)GvGet(GV_SCALPER_CONSEC_ERR, 0.0);
   g_currentDayUtc = (datetime)GvGet(GV_SCALPER_DAILY_DATE, 0.0);
   g_tradesTodayEUR = (int)GvGet(GV_SCALPER_TRADES_EUR, 0.0);
   g_tradesTodayJPY = (int)GvGet(GV_SCALPER_TRADES_JPY, 0.0);
}

// Entry deal of a position opened by an order that was in flight when the EA stopped
bool ReconstructEntry(const ulong posId)
{
   if(!HistorySelectByPosition(posId)) return false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      ReadEntryDeal(d);
      g_pos.slipPips = (g_pos.side == "BUY") ? (g_pos.fillPrice - g_pos.reqPrice) / PipSize(g_pos.symbol)
                                             : (g_pos.reqPrice - g_pos.fillPrice) / PipSize(g_pos.symbol);
      g_pos.spreadFill = SpreadAtFill(g_pos.symbol, g_pos.fillSrvMsc, g_pos.spreadFill);
      return true;
   }
   return false;
}

// Looks for an entry deal (our magic) at or after the persisted dispatch time; returns its position id
ulong FindInFlightPositionId()
{
   ulong dispatchMsc = (ulong)GvGet(GV_SCALPER_DISPATCH_MSC, 0.0);
   datetime from = (datetime)((long)(dispatchMsc / 1000) + ServerUtcOffsetSec() - 120);
   if(!HistorySelect(from, TimeTradeServer() + 60)) return 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != SCALPER_MAGIC) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      return (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
   }
   return 0;
}

bool RecoverClosedPosition(const ulong ticket)
{
   ExitInfo x;
   x.price = 0.0; x.commMoney = 0.0; x.commOk = false; x.timeSrvMsc = 0; x.volume = 0; x.dealReason = 0;
   if(!FindExitDeal(ticket, x))
   {
      PrintFormat("[RESTART RECOVERY] FATAL: position %I64u is not open and no exit deal was found in history", ticket);
      return false;
   }
   PrintFormat("[RESTART RECOVERY] Position %I64u closed while EA was inactive: logging real exit (restart=1)", ticket);
   FinalizeClose(x);
   return true;
}

bool RecoverInFlight(const ulong &magicTickets[], const int nMagic)
{
   RestorePositionFromGvs(0);
   ulong posId = (nMagic == 1) ? magicTickets[0] : FindInFlightPositionId();
   if(posId == 0)
   {
      Print("[RESTART RECOVERY] In-flight order left no position: back to IDLE");
      ResetPos();
      GvDel(GV_SCALPER_IN_FLIGHT);
      SetIdle();
      return true;
   }
   g_pos.ticket = posId;
   if(!ReconstructEntry(posId))
   {
      PrintFormat("[RESTART RECOVERY] FATAL: cannot rebuild entry of position %I64u from history", posId);
      return false;
   }
   PersistPosition();
   GvDel(GV_SCALPER_IN_FLIGHT);
   if(nMagic == 1)
   {
      g_state = STATE_IN_POSITION;
      GvSet(GV_SCALPER_STATE, (double)STATE_IN_POSITION);
      return true;
   }
   return RecoverClosedPosition(posId);
}

bool RestoreState()
{
   RestoreCounters();
   ulong magicTickets[];
   int nMagic = ScanMagicPositions(magicTickets);
   bool hasTicket = GlobalVariableCheck(GV_SCALPER_TICKET);
   bool inFlight = (GvGet(GV_SCALPER_IN_FLIGHT, 0.0) > 0.5);
   ulong saved = hasTicket ? (ulong)GlobalVariableGet(GV_SCALPER_TICKET) : 0;
   g_haltReason = (int)GvGet(GV_SCALPER_HALT_REASON, 0.0);

   if(nMagic > 1 || (nMagic == 1 && hasTicket && magicTickets[0] != saved) || (nMagic == 1 && !hasTicket && !inFlight))
   {
      PrintFormat("[INIT FATAL] Orphaned open position(s) with magic %I64u (%d found, persisted ticket %I64u): operational INVALID",
                  SCALPER_MAGIC, nMagic, saved);
      return false;
   }
   if(hasTicket)
   {
      RestorePositionFromGvs(saved);
      if(nMagic == 1)
      {
         g_state = (g_pos.intent != INTENT_NONE) ? STATE_EXIT_PENDING : STATE_IN_POSITION;
         PrintFormat("[RESTART RECOVERY] Restored live position %I64u on %s (%s). Time-stop clock continues from the entry deal.",
                     g_pos.ticket, g_pos.symbol, g_pos.side);
         return true;
      }
      return RecoverClosedPosition(saved);
   }
   if(inFlight) return RecoverInFlight(magicTickets, nMagic);

   g_state = (ENUM_SCALPER_STATE)(int)GvGet(GV_SCALPER_STATE, (double)STATE_IDLE);
   if(g_state != STATE_HALTED) g_state = STATE_IDLE;
   return true;
}

//+------------------------------------------------------------------+
//| EA Initialization                                                |
//+------------------------------------------------------------------+
bool AcquireInstanceLock()
{
   double myKey = InstanceKey(ChartID());
   string prevLock = "none";
   if(GlobalVariableCheck(GV_INSTANCE_LOCK))
   {
      double heldKey = GlobalVariableGet(GV_INSTANCE_LOCK);
      if(heldKey != myKey)
      {
         if(InstanceOwnerAlive(heldKey))
         {
            Alert("FATAL: another ScalperEA instance is already running in this terminal.");
            PrintFormat("[INSTANCE LOCK] Duplicate instance refused (held by chart key %.0f)", heldKey);
            return false;
         }
         prevLock = StringFormat("stale key %.0f taken over", heldKey);
      }
      else
         prevLock = "own chart (re-init)";
   }
   GlobalVariableTemp(GV_INSTANCE_LOCK);
   GlobalVariableSet(GV_INSTANCE_LOCK, myKey);
   PrintFormat("[INSTANCE LOCK] acquired by chart key %.0f (previous: %s)", myKey, prevLock);
   return true;
}

int OnInit()
{
   Print("[INIT] Initializing ScalperEA v1.05...");
   ResetPos();
   if(!AcquireInstanceLock()) return INIT_FAILED;
   if(InpMagic != SCALPER_MAGIC)
   {
      PrintFormat("[INIT REFUSED] InpMagic %I64u must equal %I64u", InpMagic, SCALPER_MAGIC);
      return INIT_FAILED;
   }

   g_runId = InpRunId;
   if(InpEvidential)
   {
      if(!ValidateEvidential()) return INIT_FAILED;
      g_isEvidential = true;
      PrintFormat("[EVIDENTIAL OK] Confirmatory Mode Active. Run %s, AccountMdSha256: %s", g_runId, g_accountSha);
   }
   else
   {
      g_isEvidential = false;
      Print("[PLUMBING MODE - NON-EVIDENTIAL] Every row logged with evidential=0.");
   }

   if(GlobalVariableCheck(GV_SCALPER_RUN_HASH) && GlobalVariableCheck(GV_SCALPER_TICKET) &&
      GlobalVariableGet(GV_SCALPER_RUN_HASH) != RunHash(g_runId))
   {
      Print("[INIT FATAL] Persisted position belongs to a different InpRunId: refusing to mix runs");
      return INIT_FAILED;
   }
   GvSet(GV_SCALPER_RUN_HASH, RunHash(g_runId));

   m_trade.SetExpertMagicNumber(SCALPER_MAGIC);
   m_trade.SetDeviationInPoints(20);

   for(int i = 0; i < 2; i++)
   {
      if(!SymbolSelect(g_symbols[i], true))
         PrintFormat("[INIT WARNING] Failed to select %s in MarketWatch", g_symbols[i]);
      g_lastBarTimes[i] = iTime(g_symbols[i], PERIOD_M1, 0);
      UpdateTickWatcher(i);
   }

   if(!RestoreState()) return INIT_FAILED;
   CheckDailyReset();
   EventSetMillisecondTimer(InpPollIntervalMs);
   Print("[INIT] ScalperEA initialization complete.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(GlobalVariableCheck(GV_INSTANCE_LOCK) && GlobalVariableGet(GV_INSTANCE_LOCK) == InstanceKey(ChartID()))
      GlobalVariableDel(GV_INSTANCE_LOCK);
   GlobalVariablesFlush();
   PrintFormat("[DEINIT] ScalperEA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| Periodic Main Loop (OnTimer, 50 ms)                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   UtcNowMsc();                       // keeps the sub-second anchor within one poll of the second boundary
   CheckKillSwitch();
   CheckDailyReset();
   for(int i = 0; i < 2; i++) UpdateTickWatcher(i);
   TrackBarRolls();                   // before every early return (D4)

   if(g_state == STATE_IN_POSITION || g_state == STATE_EXIT_PENDING)
   {
      MonitorPosition();
      return;
   }
   if(g_state == STATE_IDLE && g_csvFailed)
      HaltWith(HALT_OPERATIONAL, "CSV log unavailable in evidential mode (no silent loss)");
   if(g_state != STATE_IDLE) return;

   datetime gmtNow = TimeGMT();
   if(!IsInSession(gmtNow)) return;
   EvaluateSignals(gmtNow);
}
//+------------------------------------------------------------------+
