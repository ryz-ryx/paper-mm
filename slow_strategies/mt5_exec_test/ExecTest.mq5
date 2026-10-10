//+------------------------------------------------------------------+
//|                                                     ExecTest.mq5 |
//|                                  MT5 Execution Quality Benchmark |
//|                                                                  |
//| Port of slow_strategies/mt5_exec_test/exec_test.py to native MQL5|
//+------------------------------------------------------------------+
#property copyright "Execution Quality Benchmark"
#property link      ""
#property version   "1.00"

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

// State Machine
enum ETestState
{
   STATE_IDLE,
   STATE_HOLDING,
   STATE_WAIT_EXIT_GATE,
   STATE_CYCLE_SLEEP,
   STATE_ABORTED
};

ETestState     g_state = STATE_IDLE;
string         g_currentSymbol = "";
ulong          g_currentPositionTicket = 0;
datetime       g_positionOpenTime = 0;

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
datetime       g_entryTimeServer = 0;
string         g_entrySession = "";

// Exit gate variables
datetime       g_exitGateStartTime = 0;
double         g_exitGateWaitedMs = 0.0;
bool           g_exitZeroSpread = false;

datetime       g_nextCycleTime = 0;

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
         FileWriteString(h, "timestamp_utc,session,symbol,side,volume,request_price,fill_price,bid_before,ask_before,spread_before,retcode,latency_ms,deviation,comment,engine\r\n");
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
              uint retcode, double latency_ms, ulong deviation, string comment)
{
   datetime nowUtc = TimeGMT();
   string session = GetCurrentSession(nowUtc);
   string tsStr = FormatUtcTime(nowUtc);

   int h = FileOpen(FILE_TRADES, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileSeek(h, 0, SEEK_END);
      string line = StringFormat("%s,%s,%s,%s,%.2f,%f,%f,%f,%f,%f,%u,%.1f,%I64u,%s,mql5\r\n",
                                 tsStr, session, symbol, side, volume, req_price, fill_price,
                                 bid_b, ask_b, spread_b, retcode, latency_ms, deviation, comment);
      FileWriteString(h, line);
      FileClose(h);
   }
   g_dailyOrderCount++;
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

   // 3. Equity drawdown limit
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((g_initialEquity - currentEquity) >= InpMaxDrawdownEUR)
   {
      reason = StringFormat("Equity drop %.2f EUR >= %.2f EUR stop",
                            (g_initialEquity - currentEquity), InpMaxDrawdownEUR);
      return false;
   }

   // 4. Consecutive errors circuit breaker
   if(g_consecutiveErrors >= 3)
   {
      reason = StringFormat("Circuit breaker tripped: %d consecutive errors", g_consecutiveErrors);
      return false;
   }

   // 5. Max orders per day limit
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   if(g_currentDayUtc != todayStart)
   {
      g_currentDayUtc = todayStart;
      g_dailyOrderCount = 0;
   }

   if(g_dailyOrderCount >= InpMaxOrdersPerDay)
   {
      reason = StringFormat("Daily limit reached: %d/%d orders today",
                            g_dailyOrderCount, InpMaxOrdersPerDay);
      return false;
   }

   // 6. Max 1 open position across account
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
bool ExecuteEntry(string symbol)
{
   // Check market status
   datetime nowUtc = TimeGMT();
   if(IsMarketClosed(nowUtc))
   {
      LogSkip(symbol, "market_closed", "Forex market is closed for weekend");
      return false;
   }

   // Fresh tick check
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
   {
      LogSkip(symbol, "no_tick", "SymbolInfoTick returned invalid or zero quote");
      return false;
   }

   // Gate 1: Spread > 0
   double spread = tick.ask - tick.bid;
   if(spread <= 0.0)
   {
      LogSkip(symbol, "zero_spread", StringFormat("Reported spread is %.5f <= 0", spread));
      return false;
   }

   // Gate 2: Server-time tick age <= 500 ms (0.5s)
   long serverTimeMsc = (long)TimeCurrent() * 1000;
   long tickAgeMs = serverTimeMsc - (long)tick.time_msc;
   if(tickAgeMs > 500)
   {
      LogSkip(symbol, "stale_tick", StringFormat("Tick age %d ms > 500 ms threshold", tickAgeMs));
      return false;
   }
   if(tickAgeMs < 0) tickAgeMs = 0; // clock sync variation

   // Cache entry snapshot metrics
   g_entrySnapshotTick = tick;
   g_entrySnapAgeMs = (double)tickAgeMs;
   g_entryReqPrice = tick.ask;
   g_entrySpreadPts = spread / SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_entryMid = (tick.bid + tick.ask) / 2.0;
   g_entrySession = GetCurrentSession(nowUtc);
   g_entryTimeServer = TimeCurrent();

   // Immediate tick check right before order send
   MqlTick tickBeforeSend;
   SymbolInfoTick(symbol, tickBeforeSend);

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
               tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment());
      g_consecutiveErrors++;
      return false;
   }

   g_entryFillPrice = fillPrice;
   g_currentPositionTicket = m_trade.ResultOrder();
   g_positionOpenTime = TimeCurrent();
   g_consecutiveErrors = 0;

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
            tick.bid, tick.ask, spread, retcode, g_entryLatencyMs, InpDeviation, m_trade.ResultComment());

   PrintFormat("[%s ENTRY FILLED] [%s] BUY %.2f @ %f (Req: %f) | Latency: %.1f ms | ExecSlip: %+.2f pt | Drift: %+.2f pt",
               symbol, g_entrySession, InpVolume, g_entryFillPrice, g_entryReqPrice,
               g_entryLatencyMs, g_entryExecSlipPts, g_entryDriftPts);

   return true;
}

//+------------------------------------------------------------------+
//| Execute Position Close (SELL Exit) & Log Roundtrip               |
//+------------------------------------------------------------------+
bool ExecuteExit(string symbol)
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
   MqlTick tick;
   SymbolInfoTick(symbol, tick);
   double spread = tick.ask - tick.bid;
   long serverTimeMsc = (long)TimeCurrent() * 1000;
   long tickAgeMs = serverTimeMsc - (long)tick.time_msc;

   g_exitZeroSpread = (spread <= 0.0);
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
               tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment());
      g_consecutiveErrors++;
      return false;
   }

   g_consecutiveErrors = 0;

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
            tick.bid, tick.ask, spread, retcode, exitLatencyMs, InpDeviation, m_trade.ResultComment());

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
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=================================================");
   Print("INITIALIZING MT5 EXECUTION QUALITY EA (ExecTest)");
   Print("=================================================");

   // Hard safety rule 1: DEMO account verification
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Alert("FATAL: Account is NOT DEMO! Refusing to initialize ExecTest EA.");
      return INIT_FAILED;
   }

   g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   g_currentDayUtc = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   g_dailyOrderCount = 0;
   g_consecutiveErrors = 0;

   // Select symbols
   for(int i = 0; i < 2; i++)
   {
      SymbolSelect(g_activeSymbols[i], true);
      m_symbols[i].Name(g_activeSymbols[i]);
   }

   // Initialize CSV files in Common\Files
   InitCsvFiles();

   // Set timer for 1 second polling
   EventSetTimer(1);

   g_state = STATE_IDLE;
   g_nextCycleTime = TimeCurrent() + 5; // Start in 5 seconds

   PrintFormat("[SAFETY VERIFIED] Demo Account: %I64d | Starting Equity: %.2f EUR | Max Orders/Day: %d",
               AccountInfoInteger(ACCOUNT_LOGIN), g_initialEquity, InpMaxOrdersPerDay);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("[SHUTDOWN] ExecTest EA deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| Expert timer function: State Machine Driven                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   string reason = "";
   if(!CheckSafetyLimits(reason))
   {
      PrintFormat("[SAFETY ABORT/PAUSE] %s", reason);
      if(g_consecutiveErrors >= 3 || (g_initialEquity - AccountInfoDouble(ACCOUNT_EQUITY)) >= InpMaxDrawdownEUR)
      {
         g_state = STATE_ABORTED;
         EventKillTimer();
      }
      return;
   }

   datetime nowServer = TimeCurrent();

   switch(g_state)
   {
      case STATE_IDLE:
      {
         if(nowServer >= g_nextCycleTime)
         {
            // Pick next active symbol round-robin
            g_currentSymbol = g_activeSymbols[g_symbolIndex % 2];
            g_symbolIndex++;

            PrintFormat("[CYCLE TRIGGER] Attempting round-trip on %s...", g_currentSymbol);
            bool ok = ExecuteEntry(g_currentSymbol);
            if(ok)
            {
               g_state = STATE_HOLDING;
            }
            else
            {
               // Retry in 2 minutes if entry skipped or failed
               g_nextCycleTime = nowServer + 120;
               g_state = STATE_CYCLE_SLEEP;
            }
         }
         break;
      }

      case STATE_HOLDING:
      {
         // Wait for 60 seconds position hold duration
         if((nowServer - g_positionOpenTime) >= InpHoldSeconds)
         {
            g_state = STATE_WAIT_EXIT_GATE;
            g_exitGateStartTime = nowServer;
            g_exitGateWaitedMs = 0.0;
         }
         break;
      }

      case STATE_WAIT_EXIT_GATE:
      {
         // Exit gate: if bid >= ask or tick age > 2 s, wait up to 3 s for valid tick
         MqlTick tick;
         SymbolInfoTick(g_currentSymbol, tick);
         double spread = tick.ask - tick.bid;
         long serverTimeMsc = (long)TimeCurrent() * 1000;
         long tickAgeMs = serverTimeMsc - (long)tick.time_msc;
         double elapsedGateSec = (double)(nowServer - g_exitGateStartTime);

         if((spread <= 0.0 || tickAgeMs > 2000) && elapsedGateSec < 3.0)
         {
            // Wait up to 3 s
            g_exitGateWaitedMs = elapsedGateSec * 1000.0;
            return;
         }

         g_exitGateWaitedMs = elapsedGateSec * 1000.0;
         bool ok = ExecuteExit(g_currentSymbol);

         // Schedule next trade cycle (40 orders/day = 20 round-trips -> ~36 min interval)
         g_nextCycleTime = nowServer + (InpCycleIntervalMin * 60);
         g_state = STATE_CYCLE_SLEEP;
         break;
      }

      case STATE_CYCLE_SLEEP:
      {
         if(nowServer >= g_nextCycleTime)
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
