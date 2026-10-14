//+------------------------------------------------------------------+
//|                                                    ScalperEA.mq5 |
//|                                  MT5 M1 Breakout Confirmatory EA |
//|                                                                  |
//| Conforms strictly to PREREG.md v1.02                             |
//| Multi-Symbol Engine: EURUSD, USDJPY                              |
//| Magic: 20261014 | Volume: 0.01 Lot | Global Concurrency: 1       |
//+------------------------------------------------------------------+
#property copyright "Confirmatory Breakout Scalper"
#property link      ""
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Hard Constants (PREREG §2.1)
const double MAX_VOLUME       = 0.01;
const ulong  SCALPER_MAGIC    = 20261014;
const int    LOOKBACK_BARS    = 20;
const int    TIME_STOP_SEC    = 300;
const double TARGET_BRACKET   = 5.0; // +/-5.0 pips TP/SL
const int    MAX_CONSEC_ERRS  = 5;
const double DAILY_LOSS_STOP  = -30.0; // -30 pips cumulative net per day
const int    MAX_TRADES_DAY   = 20;

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

//--- Input Parameters
input group "=== Scalper Configuration ==="
input bool     InpEvidential        = false;                 // True = Evidential Mode, False = Plumbing Mode
input string   InpExpectedServer    = "";                    // Expected Server Name (Evidential Mode)
input long     InpExpectedLogin     = 0;                     // Expected Account Login (Evidential Mode)
input string   InpAccountMdSha256   = "";                    // ACCOUNT.md SHA256 checksum (Evidential Mode)
input double   InpGateEURUSD        = 0.3;                   // Spread gate EURUSD in pips
input double   InpGateUSDJPY        = 0.3;                   // Spread gate USDJPY in pips
input string   InpNewsFile          = "news_calendar.csv";   // Economic calendar CSV in Common\Files
input ulong    InpMagic             = 20261014;              // Magic number (strictly 20261014)
input int      InpPollIntervalMs    = 50;                    // Polling interval in ms

//--- Global Variables Persistence Keys
#define GV_SCALPER_STATE        "SCALPER_STATE"
#define GV_SCALPER_IN_FLIGHT    "SCALPER_IN_FLIGHT"
#define GV_SCALPER_TICKET       "SCALPER_TICKET"
#define GV_SCALPER_SYMBOL       "SCALPER_SYMBOL"
#define GV_SCALPER_SIDE         "SCALPER_SIDE"
#define GV_SCALPER_OPEN_SERVER  "SCALPER_OPEN_SERVER"
#define GV_SCALPER_OPEN_LOCAL   "SCALPER_OPEN_LOCAL"
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
#define GV_INSTANCE_LOCK        "SCALPER_INSTANCE_LOCK"

//--- Telemetry Headers
#define HDR_TRADES      "timestamp_utc,evidential,window_id,ticket,symbol,side,volume,req_price,fill_price,spread_at_signal,spread_at_fill,slippage_pips,commission_pips,retcode,latency_ms,comment,t_tick_msc,tick_age_ms"
#define HDR_ROUNDTRIPS  "ticket,evidential,window_id,symbol,symbol_gate,side,signal_time_msc,dispatch_time_msc,fill_time_msc,signal_price,fill_price,spread_at_signal,spread_at_fill,slippage_pips,commission_pips,exit_fill_price,exit_reason,hold_ms,gross_pips,net_pips,restart"
#define HDR_SKIPS       "timestamp_utc,evidential,window_id,symbol,reason,details"

//--- CTrade & Helpers
CTrade            m_trade;
CPositionInfo     m_position;
CSymbolInfo       m_symInfo;

//--- State Machine & Internal Tracking
ENUM_SCALPER_STATE g_state = STATE_IDLE;
bool              g_inFlight = false;
bool              g_isEvidential = false;
int               g_gvBatchDepth = 0;
bool              g_gvDirty = false;

// Active Position Tracking
ulong             g_posTicket = 0;
string            g_posSymbol = "";
string            g_posSide = "";
datetime          g_posOpenServerTime = 0;
ulong             g_posOpenLocalMs = 0;
double            g_posReqPrice = 0.0;
double            g_posFillPrice = 0.0;
double            g_posSignalPrice = 0.0;
double            g_posSpreadAtSignal = 0.0;
double            g_posSpreadAtFill = 0.0;
long              g_posWindowId = 0;
ulong             g_signalTimeMsc = 0;
ulong             g_dispatchTimeMsc = 0;
ulong             g_fillTimeMsc = 0;
double            g_posSlippagePips = 0.0;
double            g_posCommissionPips = 0.0;

// Symbol Data
string            g_symbols[2] = {"EURUSD", "USDJPY"};
datetime          g_lastBarTimes[2] = {0, 0};
ulong             g_lastTickSeenUs[2] = {0, 0};
MqlTick           g_lastTicks[2];

// Risk & Throttling
long              g_lastDispatchedWindowId = -1;
int               g_consecutiveErrors = 0;
double            g_dailyNetPips = 0.0;
datetime          g_currentDayUtc = 0;
int               g_tradesTodayEUR = 0;
int               g_tradesTodayJPY = 0;
datetime          g_backoffUntil = 0;
datetime          g_lastNewsDegradedDay = 0;

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
//| Helper: Format Current UTC ISO Timestamp                         |
//+------------------------------------------------------------------+
string TimeUtcIso()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                       dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
}

//+------------------------------------------------------------------+
//| Helper: Pip size per symbol                                      |
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
   return 0.3;
}

//+------------------------------------------------------------------+
//| Append-Only CSV Logging to Common\Files                          |
//+------------------------------------------------------------------+
void AppendCsvLine(const string filename, const string header, const string line)
{
   bool exists = FileIsExist(filename, FILE_COMMON);
   int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(handle != INVALID_HANDLE)
   {
      if(exists && FileSize(handle) > 0)
      {
         FileSeek(handle, 0, SEEK_END);
      }
      else
      {
         FileWrite(handle, header);
      }
      FileWrite(handle, line);
      FileFlush(handle);
      FileClose(handle);
   }
   else
   {
      PrintFormat("[LOG ERROR] Could not open %s in Common\\Files. Err: %d", filename, GetLastError());
   }
}

void LogSkip(const string symbol, const string reason, const string details, long winId)
{
   string line = StringFormat("%s,%d,%d,%s,%s,\"%s\"",
                              TimeUtcIso(), g_isEvidential ? 1 : 0, winId, symbol, reason, details);
   AppendCsvLine("skips.csv", HDR_SKIPS, line);
   PrintFormat("[SKIP] %s | %s | %s | %s", symbol, reason, details, TimeUtcIso());
}

//+------------------------------------------------------------------+
//| Convert Deal Commission in Money to Pips                         |
//+------------------------------------------------------------------+
double CommissionToPips(const string symbol, double commMoney, double volume)
{
   if(commMoney == 0.0) return 0.0;
   double tickVal = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double pip = PipSize(symbol);
   if(tickSz <= 0 || tickVal <= 0) return 0.0;

   double pipVal = tickVal * (pip / tickSz);
   if(pipVal <= 0.0) return 0.0;

   return MathAbs(commMoney) / pipVal;
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
      int h = FileOpen(InpNewsFile, FILE_READ | FILE_CSV | FILE_COMMON, ',');
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
                  if(MathAbs((long)gmtNow - (long)evtDt) <= 600) // +/- 10 min
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
//| External Kill Switch Check (PREREG §6.4)                         |
//+------------------------------------------------------------------+
bool CheckKillSwitch()
{
   if(FileIsExist("kill_switch.txt", FILE_COMMON))
   {
      Print("[KILL SWITCH] Detected kill_switch.txt in Common\\Files. Halting trading immediately.");
      if(g_posTicket > 0 && PositionSelectByTicket(g_posTicket))
      {
         m_trade.PositionClose(g_posTicket);
      }
      g_state = STATE_HALTED;
      GvSet(GV_SCALPER_STATE, (double)STATE_HALTED);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Update Tick Watcher & Measure Tick Age                           |
//+------------------------------------------------------------------+
void UpdateTickWatcher(int symIdx)
{
   string sym = g_symbols[symIdx];
   MqlTick tick;
   if(SymbolInfoTick(sym, tick))
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

//+------------------------------------------------------------------+
//| Evaluate M1 Breakout Signal (PREREG §2.2)                        |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE CheckBreakoutSignal(int symIdx, double &outSignalPrice)
{
   string sym = g_symbols[symIdx];
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   // We need bar 1 (completed) and the 20 completed bars before it (bars 2 to 21)
   if(CopyRates(sym, PERIOD_M1, 1, 21, rates) < 21)
   {
      return SIGNAL_NONE;
   }

   // rates[0] is bar 1 (t-1)
   // rates[1..20] are bars 2..21 (t-2 to t-21)
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

//+------------------------------------------------------------------+
//| Configure Symbol Filling Mode                                    |
//+------------------------------------------------------------------+
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
//| Reset Daily Tracking on UTC Boundary                             |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime gmtNow = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmtNow, dt);
   datetime todayUtc = (datetime)((long)gmtNow - (long)(dt.hour * 3600 + dt.min * 60 + dt.sec));

   if(g_currentDayUtc != todayUtc)
   {
      g_currentDayUtc = todayUtc;
      g_dailyNetPips = 0.0;
      g_tradesTodayEUR = 0;
      g_tradesTodayJPY = 0;

      GvBegin();
      GvSet(GV_SCALPER_DAILY_DATE, (double)g_currentDayUtc);
      GvSet(GV_SCALPER_DAILY_NET, 0.0);
      GvSet(GV_SCALPER_TRADES_EUR, 0.0);
      GvSet(GV_SCALPER_TRADES_JPY, 0.0);

      // If halted strictly due to daily loss, unhalt on new UTC day
      if(g_state == STATE_HALTED && g_consecutiveErrors < MAX_CONSEC_ERRS && !FileIsExist("kill_switch.txt", FILE_COMMON))
      {
         g_state = STATE_IDLE;
         GvSet(GV_SCALPER_STATE, (double)STATE_IDLE);
         PrintFormat("[DAILY RESET] New UTC Day %04d-%02d-%02d. Resuming STATE_IDLE.", dt.year, dt.mon, dt.day);
      }
      GvEnd();
   }
}

//+------------------------------------------------------------------+
//| Dispatch Order & Handle SL/TP Bracket (PREREG §2.4)              |
//+------------------------------------------------------------------+
bool DispatchOrder(int symIdx, ENUM_SIGNAL_TYPE sigType, double signalPrice, long winId)
{
   string sym = g_symbols[symIdx];
   ConfigureFilling(sym);
   double pip = PipSize(sym);

   // Pre-dispatch check: spread & tick age
   UpdateTickWatcher(symIdx);
   MqlTick tick = g_lastTicks[symIdx];
   double ageMs = GetTickAgeMs(symIdx);
   double spreadPips = (tick.ask - tick.bid) / pip;
   double gate = SymbolGate(sym);

   if(ageMs > 500.0)
   {
      LogSkip(sym, "stale_tick", StringFormat("Tick age %.1f ms > 500 ms", ageMs), winId);
      g_backoffUntil = TimeCurrent() + 120;
      return false;
   }
   if(spreadPips <= 0.0)
   {
      LogSkip(sym, "zero_spread", "Spread <= 0", winId);
      g_backoffUntil = TimeCurrent() + 120;
      return false;
   }
   if(spreadPips > gate)
   {
      LogSkip(sym, "spread_gate", StringFormat("Spread %.3f > gate %.3f", spreadPips, gate), winId);
      return false;
   }

   // Set state to ENTRY_PENDING
   g_state = STATE_ENTRY_PENDING;
   g_inFlight = true;
   GvBegin();
   GvSet(GV_SCALPER_STATE, (double)STATE_ENTRY_PENDING);
   GvSet(GV_SCALPER_IN_FLIGHT, 1.0);
   GvEnd();

   ENUM_ORDER_TYPE ordType = (sigType == SIGNAL_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double reqPrice = (sigType == SIGNAL_BUY) ? tick.ask : tick.bid;
   g_dispatchTimeMsc = (ulong)TimeCurrent() * 1000;
   ulong dispatchUs = GetMicrosecondCount();

   bool sent = (sigType == SIGNAL_BUY) ?
      m_trade.Buy(MAX_VOLUME, sym, reqPrice, 0.0, 0.0, "Scalper v1.02") :
      m_trade.Sell(MAX_VOLUME, sym, reqPrice, 0.0, 0.0, "Scalper v1.02");

   ulong rttUs = GetMicrosecondCount() - dispatchUs;
   uint retcode = m_trade.ResultRetcode();

   if(!sent || retcode != TRADE_RETCODE_DONE)
   {
      g_consecutiveErrors++;
      GvSet(GV_SCALPER_CONSEC_ERR, (double)g_consecutiveErrors);
      PrintFormat("[ORDER REJECT] Retcode: %d, Err: %d, Consec: %d", retcode, GetLastError(), g_consecutiveErrors);

      // Log failure row in trades.csv
      string tradeLine = StringFormat("%s,%d,%d,0,%s,%s,%.2f,%.5f,0.0,%.3f,%.3f,0.0,0.0,%d,%.1f,\"%s\",%I64d,%.1f",
                                      TimeUtcIso(), g_isEvidential ? 1 : 0, winId, sym,
                                      (sigType == SIGNAL_BUY ? "BUY" : "SELL"), MAX_VOLUME,
                                      reqPrice, (signalPrice - (sigType == SIGNAL_BUY ? tick.bid : tick.ask))/pip,
                                      spreadPips, retcode, (double)rttUs/1000.0, m_trade.ResultComment(),
                                      (long)tick.time_msc, ageMs);
      AppendCsvLine("trades.csv", HDR_TRADES, tradeLine);

      g_state = STATE_IDLE;
      g_inFlight = false;
      GvBegin();
      GvSet(GV_SCALPER_STATE, (double)STATE_IDLE);
      GvSet(GV_SCALPER_IN_FLIGHT, 0.0);
      GvEnd();

      if(g_consecutiveErrors >= MAX_CONSEC_ERRS)
      {
         g_state = STATE_HALTED;
         GvSet(GV_SCALPER_STATE, (double)STATE_HALTED);
         PrintFormat("[CIRCUIT BREAKER] %d consecutive order errors. STATE_HALTED.", g_consecutiveErrors);
      }
      return false;
   }

   // Order Successful
   g_consecutiveErrors = 0;
   GvSet(GV_SCALPER_CONSEC_ERR, 0.0);

   ulong dealTicket = m_trade.ResultDeal();
   ulong posId = m_trade.ResultOrder();
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
   {
      ulong histPosId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(histPosId > 0) posId = histPosId;
   }

   double fillPrice = m_trade.ResultPrice();
   g_fillTimeMsc = (ulong)TimeCurrent() * 1000;
   double commMoney = (dealTicket > 0) ? HistoryDealGetDouble(dealTicket, DEAL_COMMISSION) : 0.0;
   double commPips = CommissionToPips(sym, commMoney, MAX_VOLUME);

   // Slippage vs dispatch quote
   double slipPips = (sigType == SIGNAL_BUY) ? (fillPrice - reqPrice) / pip : (reqPrice - fillPrice) / pip;

   // Save State
   g_posTicket = posId;
   g_posSymbol = sym;
   g_posSide = (sigType == SIGNAL_BUY) ? "BUY" : "SELL";
   g_posOpenServerTime = TimeCurrent();
   g_posOpenLocalMs = GetTickCount64();
   g_posReqPrice = reqPrice;
   g_posFillPrice = fillPrice;
   g_posSignalPrice = signalPrice;
   g_posSpreadAtSignal = (sigType == SIGNAL_BUY) ? (signalPrice - tick.bid) / pip : (tick.ask - signalPrice) / pip;
   g_posSpreadAtFill = spreadPips;
   g_posWindowId = winId;
   g_lastDispatchedWindowId = winId;
   g_posSlippagePips = slipPips;
   g_posCommissionPips = commPips;

   // Persist Open Position
   GvBegin();
   GvSet(GV_SCALPER_TICKET, (double)g_posTicket);
   GvSet(GV_SCALPER_SYMBOL, (double)symIdx);
   GvSet(GV_SCALPER_SIDE, (sigType == SIGNAL_BUY) ? 1.0 : -1.0);
   GvSet(GV_SCALPER_OPEN_SERVER, (double)g_posOpenServerTime);
   GvSet(GV_SCALPER_OPEN_LOCAL, (double)g_posOpenLocalMs);
   GvSet(GV_SCALPER_REQ_PRICE, g_posReqPrice);
   GvSet(GV_SCALPER_FILL_PRICE, g_posFillPrice);
   GvSet(GV_SCALPER_SIGNAL_PRICE, g_posSignalPrice);
   GvSet(GV_SCALPER_SPREAD_SIG, g_posSpreadAtSignal);
   GvSet(GV_SCALPER_SPREAD_FILL, g_posSpreadAtFill);
   GvSet(GV_SCALPER_WINDOW_ID, (double)g_posWindowId);
   GvSet(GV_SCALPER_LAST_WIN_ID, (double)g_lastDispatchedWindowId);
   g_state = STATE_IN_POSITION;
   GvSet(GV_SCALPER_STATE, (double)STATE_IN_POSITION);
   g_inFlight = false;
   GvSet(GV_SCALPER_IN_FLIGHT, 0.0);
   GvEnd();

   // Log Fill to trades.csv
   string fillLine = StringFormat("%s,%d,%d,%I64d,%s,%s,%.2f,%.5f,%.5f,%.3f,%.3f,%.3f,%.3f,%d,%.1f,\"%s\",%I64d,%.1f",
                                  TimeUtcIso(), g_isEvidential ? 1 : 0, winId, g_posTicket, sym,
                                  g_posSide, MAX_VOLUME, reqPrice, fillPrice,
                                  g_posSpreadAtSignal, g_posSpreadAtFill, slipPips, commPips,
                                  retcode, (double)rttUs/1000.0, "fill_entry", (long)tick.time_msc, ageMs);
   AppendCsvLine("trades.csv", HDR_TRADES, fillLine);

   // Modify Position to Set SL/TP at +/- 5.0 pips from actual fill price (PREREG §2.4)
   double sl = (sigType == SIGNAL_BUY) ? fillPrice - TARGET_BRACKET * pip : fillPrice + TARGET_BRACKET * pip;
   double tp = (sigType == SIGNAL_BUY) ? fillPrice + TARGET_BRACKET * pip : fillPrice - TARGET_BRACKET * pip;
   sl = NormalizeDouble(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   tp = NormalizeDouble(tp, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));

   if(!m_trade.PositionModify(g_posTicket, sl, tp))
   {
      PrintFormat("[POSITION MODIFY WARNING] Ticket %I64d SL/TP modify failed: %d", g_posTicket, GetLastError());
   }
   else
   {
      PrintFormat("[POSITION MODIFY OK] Ticket %I64d SL/TP set at +/-5.0 pips from fill %.5f (SL: %.5f, TP: %.5f)",
                  g_posTicket, fillPrice, sl, tp);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Reconcile Closed Roundtrip & Log Telemetry                       |
//+------------------------------------------------------------------+
void HandlePositionClosed(double exitFillPrice, string exitReason, bool isRestart)
{
   string sym = g_posSymbol;
   double pip = PipSize(sym);

   // Gross PnL
   double grossPips = (g_posSide == "BUY") ? (exitFillPrice - g_posFillPrice) / pip :
                                             (g_posFillPrice - exitFillPrice) / pip;

   // Net PnL = gross - 2 * commission_pips (PREREG §2.5)
   double netPips = grossPips - 2.0 * g_posCommissionPips;

   ulong holdMs = GetTickCount64() - g_posOpenLocalMs;

   // Update Daily Net PnL and trade counts
   g_dailyNetPips += netPips;
   if(sym == "EURUSD") g_tradesTodayEUR++;
   if(sym == "USDJPY") g_tradesTodayJPY++;

   GvBegin();
   GvSet(GV_SCALPER_DAILY_NET, g_dailyNetPips);
   GvSet(GV_SCALPER_TRADES_EUR, (double)g_tradesTodayEUR);
   GvSet(GV_SCALPER_TRADES_JPY, (double)g_tradesTodayJPY);

   // Clear active position keys
   GvDel(GV_SCALPER_TICKET);
   GvDel(GV_SCALPER_SYMBOL);
   GvDel(GV_SCALPER_SIDE);
   GvDel(GV_SCALPER_OPEN_SERVER);
   GvDel(GV_SCALPER_OPEN_LOCAL);
   GvDel(GV_SCALPER_REQ_PRICE);
   GvDel(GV_SCALPER_FILL_PRICE);
   GvDel(GV_SCALPER_SIGNAL_PRICE);
   GvDel(GV_SCALPER_SPREAD_SIG);
   GvDel(GV_SCALPER_SPREAD_FILL);
   GvDel(GV_SCALPER_WINDOW_ID);
   GvEnd();

   // Log to roundtrips.csv
   string rtLine = StringFormat("%I64d,%d,%d,%s,%.3f,%s,%I64d,%I64d,%I64d,%.5f,%.5f,%.3f,%.3f,%.3f,%.3f,%.5f,%s,%I64d,%.3f,%.3f,%d",
                                g_posTicket, g_isEvidential ? 1 : 0, g_posWindowId, sym, SymbolGate(sym),
                                g_posSide, (long)g_signalTimeMsc, (long)g_dispatchTimeMsc, (long)g_fillTimeMsc,
                                g_posSignalPrice, g_posFillPrice, g_posSpreadAtSignal, g_posSpreadAtFill,
                                g_posSlippagePips, g_posCommissionPips, exitFillPrice, exitReason,
                                (long)holdMs, grossPips, netPips, isRestart ? 1 : 0);
   AppendCsvLine("roundtrips.csv", HDR_ROUNDTRIPS, rtLine);

   PrintFormat("[ROUNDTRIP COMPLETE] Ticket %I64d | %s %s | Gross: %.2f | Net: %.2f pips | Exit: %s | DailyNet: %.2f",
               g_posTicket, sym, g_posSide, grossPips, netPips, exitReason, g_dailyNetPips);

   // Reset in-memory position state
   g_posTicket = 0;
   g_posSymbol = "";
   g_posSide = "";

   // Check Daily Loss Stop (PREREG §6.2: -30.0 pips)
   if(g_dailyNetPips <= DAILY_LOSS_STOP)
   {
      g_state = STATE_HALTED;
      GvSet(GV_SCALPER_STATE, (double)STATE_HALTED);
      PrintFormat("[DAILY LOSS STOP HIT] Cumulative daily net pips %.2f <= %.2f. Halting until next UTC day.",
                  g_dailyNetPips, DAILY_LOSS_STOP);
   }
   else
   {
      g_state = STATE_IDLE;
      GvSet(GV_SCALPER_STATE, (double)STATE_IDLE);
   }
}

//+------------------------------------------------------------------+
//| Monitor Active Position & Time Stop (300 s)                      |
//+------------------------------------------------------------------+
void MonitorPosition()
{
   if(g_posTicket == 0) return;

   // Check if position still exists
   if(PositionSelectByTicket(g_posTicket))
   {
      // Position is still open. Check time stop: 300 s (PREREG §2.4)
      long elapsedSec = (long)TimeCurrent() - (long)g_posOpenServerTime;
      if(elapsedSec >= TIME_STOP_SEC)
      {
         PrintFormat("[TIME STOP] 300 seconds elapsed on ticket %I64d. Closing at market...", g_posTicket);
         g_state = STATE_EXIT_PENDING;
         GvSet(GV_SCALPER_STATE, (double)STATE_EXIT_PENDING);

         if(m_trade.PositionClose(g_posTicket))
         {
            ulong dealTicket = m_trade.ResultDeal();
            double exitPrice = m_trade.ResultPrice();
            HandlePositionClosed(exitPrice, "TIME_STOP", false);
         }
         else
         {
            PrintFormat("[TIME STOP ERROR] Close failed on %I64d: %d", g_posTicket, GetLastError());
            g_state = STATE_IN_POSITION;
            GvSet(GV_SCALPER_STATE, (double)STATE_IN_POSITION);
         }
      }
   }
   else
   {
      // Position was closed externally (TP or SL)
      datetime fromTime = (datetime)(g_posOpenServerTime - 10);
      datetime toTime = TimeCurrent() + 10;
      HistorySelect(fromTime, toTime);

      double exitPrice = g_posFillPrice;
      string exitReason = "STOP_LOSS"; // fallback

      int totalDeals = HistoryDealsTotal();
      for(int i = totalDeals - 1; i >= 0; i--)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket > 0)
         {
            ulong pId = (ulong)HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dTicket, DEAL_ENTRY);
            if(pId == g_posTicket && entry == DEAL_ENTRY_OUT)
            {
               exitPrice = HistoryDealGetDouble(dTicket, DEAL_PRICE);
               ENUM_DEAL_REASON rsn = (ENUM_DEAL_REASON)HistoryDealGetInteger(dTicket, DEAL_REASON);
               string comm = HistoryDealGetString(dTicket, DEAL_COMMENT);

               if(rsn == DEAL_REASON_TP || StringFind(comm, "tp") >= 0)
                  exitReason = "TAKE_PROFIT";
               else if(rsn == DEAL_REASON_SL || StringFind(comm, "sl") >= 0)
                  exitReason = "STOP_LOSS";
               else
                  exitReason = "TIME_STOP";
               break;
            }
         }
      }

      HandlePositionClosed(exitPrice, exitReason, false);
   }
}

//+------------------------------------------------------------------+
//| EA Initialization                                                |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[INIT] Initializing ScalperEA v1.02...");

   // 1. One-Instance Lock per terminal
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

   // 2. Validate Mode (Plumbing vs Evidential)
   if(InpEvidential)
   {
      string srv = AccountInfoString(ACCOUNT_SERVER);
      long logn = AccountInfoInteger(ACCOUNT_LOGIN);
      ENUM_ACCOUNT_TRADE_MODE mode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);

      if(srv != InpExpectedServer)
      {
         PrintFormat("[EVIDENTIAL REFUSED] Server mismatch: expected '%s', got '%s'", InpExpectedServer, srv);
         return INIT_FAILED;
      }
      if(logn != InpExpectedLogin)
      {
         PrintFormat("[EVIDENTIAL REFUSED] Login mismatch: expected %I64d, got %I64d", InpExpectedLogin, logn);
         return INIT_FAILED;
      }
      if(StringFind(srv, "MetaQuotes") >= 0)
      {
         Print("[EVIDENTIAL REFUSED] Server contains MetaQuotes (synthetic feed forbidden)");
         return INIT_FAILED;
      }
      if(mode != ACCOUNT_TRADE_MODE_DEMO)
      {
         Print("[EVIDENTIAL REFUSED] Account must be a true demo account");
         return INIT_FAILED;
      }
      if(StringLen(InpAccountMdSha256) < 64)
      {
         Print("[EVIDENTIAL REFUSED] Missing valid InpAccountMdSha256");
         return INIT_FAILED;
      }

      g_isEvidential = true;
      PrintFormat("[EVIDENTIAL OK] Confirmatory Mode Active. Srv: %s, Login: %I64d, AccountMdSha256: %s",
                  srv, logn, InpAccountMdSha256);
   }
   else
   {
      g_isEvidential = false;
      Print("[PLUMBING MODE - NON-EVIDENTIAL] Every row logged with evidential=0.");
   }

   // 3. Configure Trade Object
   m_trade.SetExpertMagicNumber(SCALPER_MAGIC);
   m_trade.SetDeviationInPoints(20);

   // 4. Select Symbols
   for(int i = 0; i < 2; i++)
   {
      if(!SymbolSelect(g_symbols[i], true))
      {
         PrintFormat("[INIT WARNING] Failed to select %s in MarketWatch", g_symbols[i]);
      }
      g_lastBarTimes[i] = iTime(g_symbols[i], PERIOD_M1, 0);
   }

   // 5. Restore Persistent State (Recovery Pattern)
   if(GlobalVariableCheck(GV_SCALPER_LAST_WIN_ID))
      g_lastDispatchedWindowId = (long)GlobalVariableGet(GV_SCALPER_LAST_WIN_ID);
   if(GlobalVariableCheck(GV_SCALPER_DAILY_NET))
      g_dailyNetPips = GlobalVariableGet(GV_SCALPER_DAILY_NET);
   if(GlobalVariableCheck(GV_SCALPER_CONSEC_ERR))
      g_consecutiveErrors = (int)GlobalVariableGet(GV_SCALPER_CONSEC_ERR);
   if(GlobalVariableCheck(GV_SCALPER_DAILY_DATE))
      g_currentDayUtc = (datetime)GlobalVariableGet(GV_SCALPER_DAILY_DATE);
   if(GlobalVariableCheck(GV_SCALPER_TRADES_EUR))
      g_tradesTodayEUR = (int)GlobalVariableGet(GV_SCALPER_TRADES_EUR);
   if(GlobalVariableCheck(GV_SCALPER_TRADES_JPY))
      g_tradesTodayJPY = (int)GlobalVariableGet(GV_SCALPER_TRADES_JPY);

   // Restore Position State
   if(GlobalVariableCheck(GV_SCALPER_TICKET))
   {
      ulong savedTicket = (ulong)GlobalVariableGet(GV_SCALPER_TICKET);
      if(PositionSelectByTicket(savedTicket))
      {
         // Position is still live in MT5
         g_posTicket = savedTicket;
         int sIdx = (int)GlobalVariableGet(GV_SCALPER_SYMBOL);
         g_posSymbol = g_symbols[sIdx];
         g_posSide = (GlobalVariableGet(GV_SCALPER_SIDE) > 0) ? "BUY" : "SELL";
         g_posOpenServerTime = (datetime)GlobalVariableGet(GV_SCALPER_OPEN_SERVER);
         g_posOpenLocalMs = (ulong)GlobalVariableGet(GV_SCALPER_OPEN_LOCAL);
         g_posReqPrice = GlobalVariableGet(GV_SCALPER_REQ_PRICE);
         g_posFillPrice = GlobalVariableGet(GV_SCALPER_FILL_PRICE);
         g_posSignalPrice = GlobalVariableGet(GV_SCALPER_SIGNAL_PRICE);
         g_posSpreadAtSignal = GlobalVariableGet(GV_SCALPER_SPREAD_SIG);
         g_posSpreadAtFill = GlobalVariableGet(GV_SCALPER_SPREAD_FILL);
         g_posWindowId = (long)GlobalVariableGet(GV_SCALPER_WINDOW_ID);
         g_state = STATE_IN_POSITION;

         PrintFormat("[RESTART RECOVERY] Restored live open position ticket %I64d on %s (%s). Hold timer continuing.",
                     g_posTicket, g_posSymbol, g_posSide);
      }
      else
      {
         // Position closed while EA was stopped
         PrintFormat("[RESTART RECOVERY] Position %I64d closed while EA was inactive. Reconciling...", savedTicket);
         g_posTicket = savedTicket;
         int sIdx = (int)GlobalVariableGet(GV_SCALPER_SYMBOL);
         g_posSymbol = g_symbols[sIdx];
         g_posSide = (GlobalVariableGet(GV_SCALPER_SIDE) > 0) ? "BUY" : "SELL";
         g_posFillPrice = GlobalVariableGet(GV_SCALPER_FILL_PRICE);
         g_posOpenLocalMs = (ulong)GlobalVariableGet(GV_SCALPER_OPEN_LOCAL);
         g_posWindowId = (long)GlobalVariableGet(GV_SCALPER_WINDOW_ID);

         HandlePositionClosed(g_posFillPrice, "RESTART_RECONCILED", true);
      }
   }
   else if(GlobalVariableCheck(GV_SCALPER_STATE))
   {
      g_state = (ENUM_SCALPER_STATE)(int)GlobalVariableGet(GV_SCALPER_STATE);
   }

   CheckDailyReset();
   EventSetMillisecondTimer(InpPollIntervalMs);
   Print("[INIT] ScalperEA initialization complete.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EA Deinitialization                                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(GlobalVariableCheck(GV_INSTANCE_LOCK) && GlobalVariableGet(GV_INSTANCE_LOCK) == InstanceKey(ChartID()))
   {
      GlobalVariableDel(GV_INSTANCE_LOCK);
   }
   GlobalVariablesFlush();
   PrintFormat("[DEINIT] ScalperEA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| Periodic Main Loop (OnTimer)                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 1. Check Kill Switch
   if(CheckKillSwitch()) return;

   // 2. Daily Reset Check
   CheckDailyReset();

   // 3. Update Tick Cache
   for(int i = 0; i < 2; i++)
   {
      UpdateTickWatcher(i);
   }

   // 4. In-Position Monitoring
   if(g_state == STATE_IN_POSITION)
   {
      MonitorPosition();
      return;
   }

   // 5. If Halted or not Idle, do nothing
   if(g_state != STATE_IDLE) return;

   // 6. Check Backoff
   datetime nowServer = TimeCurrent();
   if(nowServer < g_backoffUntil) return;

   // 7. Check Trading Session
   datetime gmtNow = TimeGMT();
   if(!IsInSession(gmtNow)) return;

   // 8. 5-Minute Window Throttling Check
   long curWindowId = (long)(gmtNow / 300);
   if(curWindowId <= g_lastDispatchedWindowId) return;

   // 9. Evaluate Breakout Signal Across Symbols (First Signal Wins)
   for(int s = 0; s < 2; s++)
   {
      string sym = g_symbols[s];

      // Volume cap per symbol: 20 trades/day
      int tradesToday = (sym == "EURUSD") ? g_tradesTodayEUR : g_tradesTodayJPY;
      if(tradesToday >= MAX_TRADES_DAY) continue;

      // News check
      if(IsNewsBlocked(sym, gmtNow)) continue;

      // Check for completed M1 bar
      datetime curBarTime = iTime(sym, PERIOD_M1, 0);
      if(curBarTime == 0) continue;
      if(g_lastBarTimes[s] == 0) { g_lastBarTimes[s] = curBarTime; continue; }

      if(curBarTime != g_lastBarTimes[s])
      {
         g_lastBarTimes[s] = curBarTime;
         g_signalTimeMsc = (ulong)TimeCurrent() * 1000;

         double sigPrice = 0.0;
         ENUM_SIGNAL_TYPE sig = CheckBreakoutSignal(s, sigPrice);

         if(sig != SIGNAL_NONE)
         {
            PrintFormat("[SIGNAL DETECTED] %s %s at %.5f (window_id: %d)",
                        sym, (sig == SIGNAL_BUY ? "BUY" : "SELL"), sigPrice, curWindowId);

            if(DispatchOrder(s, sig, sigPrice, curWindowId))
            {
               // First signal dispatched -> stop evaluating other symbols for this window
               break;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick Handler                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   OnTimer();
}
//+------------------------------------------------------------------+
