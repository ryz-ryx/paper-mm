//+------------------------------------------------------------------+
//|                                                    SpreadLog.mq5 |
//|                                  MT5 M1 Spread Observation Logger|
//|                                                                  |
//| Standalone Passive Telemetry Logger for Pre-Start Baseline (§3.3)|
//| Strictly read-only: no trade functions are referenced            |
//| Conforms to PREREG v1.05/v1.06 §3.3                              |
//+------------------------------------------------------------------+
#property copyright "Pre-Start Spread Measurement Protocol"
#property link      ""
#property version   "1.06"
#property strict

//--- Input Parameters
input group "=== Logger Parameters ==="
input string InpSymbols        = "EURUSD,USDJPY";               // Target symbols (comma separated)
input string InpLogFilename    = "spread_log.csv";              // Output filename in Common\Files
input string InpHeartbeatFile  = "spread_log_heartbeat.txt";    // Liveness file in Common\Files (rewritten every 60 s)
input int    InpPollIntervalMs = 50;                            // Same poll period as ScalperEA (PREREG §2.3.2 tick-age method)

//--- Internal State
string   g_symbols[];
int      g_symbolCount = 0;
ulong    g_lastTickSeenUs[];
MqlTick  g_lastTicks[];
int      g_fileHandle = INVALID_HANDLE;
long     g_lastMinute = -1;        // UTC minute index (TimeGMT()/60) of the last processed bar close
datetime g_lastHeartbeat = 0;
long     g_rowsWritten = 0;

//+------------------------------------------------------------------+
//| Helper: Pip size calculation                                     |
//+------------------------------------------------------------------+
double PipSize(const string symbol)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5) return 10.0 * pt;
   return pt;
}

//+------------------------------------------------------------------+
//| Check session window: 07:00:00 - 16:00:00 UTC Mon-Fri            |
//+------------------------------------------------------------------+
bool IsInSession(datetime gmtTime)
{
   MqlDateTime dt;
   TimeToStruct(gmtTime, dt);

   // Monday=1 ... Friday=5
   if(dt.day_of_week < 1 || dt.day_of_week > 5) return false;

   int secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;
   if(secOfDay < 7 * 3600 || secOfDay >= 16 * 3600) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Update Tick Watcher & Measure Tick Age                           |
//| Age = local time since the current tick was first observed by    |
//| this poller (same method and poll period as ScalperEA).          |
//+------------------------------------------------------------------+
void UpdateTickWatcher(int idx)
{
   string sym = g_symbols[idx];
   MqlTick tick;
   if(SymbolInfoTick(sym, tick))
   {
      if(g_lastTickSeenUs[idx] == 0 ||
         tick.time_msc != g_lastTicks[idx].time_msc ||
         tick.bid != g_lastTicks[idx].bid ||
         tick.ask != g_lastTicks[idx].ask)
      {
         g_lastTicks[idx] = tick;
         g_lastTickSeenUs[idx] = GetMicrosecondCount();
      }
   }
}

double GetTickAgeMs(int idx)
{
   if(g_lastTickSeenUs[idx] == 0) return 999999.0;
   return (double)(GetMicrosecondCount() - g_lastTickSeenUs[idx]) / 1000.0;
}

//+------------------------------------------------------------------+
//| Server-time offset from UTC, rounded to 15 min (whole-hour DST)  |
//+------------------------------------------------------------------+
long ServerOffsetSec()
{
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (long)MathRound(diff / 900.0) * 900;
}

//+------------------------------------------------------------------+
//| Liveness heartbeat (FileClose puts it on disk immediately)       |
//+------------------------------------------------------------------+
void WriteHeartbeat(datetime gmtNow)
{
   int h = FileOpen(InpHeartbeatFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, StringFormat("%s,rows=%I64d,connected=%d\r\n",
                                   TimeToString(gmtNow, TIME_DATE | TIME_SECONDS), g_rowsWritten,
                                   (int)TerminalInfoInteger(TERMINAL_CONNECTED)));
   FileClose(h);
   g_lastHeartbeat = gmtNow;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[SPREAD_LOG] Initializing passive spread telemetry logger (PREREG §3.3)...");

   // Parse symbols
   string parts[];
   int count = StringSplit(InpSymbols, ',', parts);
   if(count <= 0)
   {
      Print("[SPREAD_LOG] ERROR: No valid symbols provided.");
      return INIT_FAILED;
   }

   g_symbolCount = count;
   ArrayResize(g_symbols, g_symbolCount);
   ArrayResize(g_lastTickSeenUs, g_symbolCount);
   ArrayResize(g_lastTicks, g_symbolCount);

   for(int i = 0; i < g_symbolCount; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      g_symbols[i] = parts[i];
      g_lastTickSeenUs[i] = 0;

      if(!SymbolSelect(g_symbols[i], true))
      {
         PrintFormat("[SPREAD_LOG] WARNING: Failed to select symbol %s in MarketWatch.", g_symbols[i]);
      }
      UpdateTickWatcher(i);
   }

   // Append-only ANSI CSV in Common\Files (FILE_ANSI: the Python readers expect 8-bit text)
   bool exists = FileIsExist(InpLogFilename, FILE_COMMON);
   g_fileHandle = FileOpen(InpLogFilename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ, ',');
   if(g_fileHandle == INVALID_HANDLE)
   {
      PrintFormat("[SPREAD_LOG] ERROR: Failed to open %s in Common\\Files. Err: %d", InpLogFilename, GetLastError());
      return INIT_FAILED;
   }

   if(exists && FileSize(g_fileHandle) > 0)
   {
      FileSeek(g_fileHandle, 0, SEEK_END);
   }
   else
   {
      FileWrite(g_fileHandle, "time_utc", "symbol", "spread_pips", "zero_spread", "tick_age_ms", "ticks_in_prev_60s");
      FileFlush(g_fileHandle);
   }

   // Do not log the minute already in progress at start: the first row is the next bar close.
   g_lastMinute = (long)TimeGMT() / 60;

   EventSetMillisecondTimer(InpPollIntervalMs);
   WriteHeartbeat(TimeGMT());
   PrintFormat("[SPREAD_LOG] Active. Logging to Common\\Files\\%s at every M1 bar close in session (poll %d ms).",
               InpLogFilename, InpPollIntervalMs);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_fileHandle != INVALID_HANDLE)
   {
      FileFlush(g_fileHandle);
      FileClose(g_fileHandle);
      g_fileHandle = INVALID_HANDLE;
   }
   PrintFormat("[SPREAD_LOG] Deinitialized (reason: %d, rows written this session: %I64d)", reason, g_rowsWritten);
}

//+------------------------------------------------------------------+
//| Periodic poll timer                                              |
//| A bar close is the UTC minute boundary (M1 bars of all symbols   |
//| close there; server time differs from UTC by whole hours), so a  |
//| row is written every minute even when the closing bar had few or |
//| no ticks. Quote and tick age are those prevailing at the close.  |
//+------------------------------------------------------------------+
void OnTimer()
{
   for(int i = 0; i < g_symbolCount; i++)
   {
      UpdateTickWatcher(i);
   }

   datetime gmtNow = TimeGMT();
   if(gmtNow - g_lastHeartbeat >= 60) WriteHeartbeat(gmtNow);

   long minuteNow = (long)gmtNow / 60;
   if(minuteNow == g_lastMinute) return;
   g_lastMinute = minuteNow;

   datetime closeUtc = (datetime)(minuteNow * 60);   // bar close instant (UTC)
   if(!IsInSession(closeUtc)) return;

   long offset = ServerOffsetSec();
   ulong toMsc = (ulong)(((long)closeUtc + offset) * 1000);   // tick history uses server-time ms
   ulong fromMsc = (toMsc >= 60000) ? (toMsc - 60000) : 0;

   MqlDateTime dt;
   TimeToStruct(closeUtc, dt);
   string timeStr = StringFormat("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);

   for(int i = 0; i < g_symbolCount; i++)
   {
      string sym = g_symbols[i];
      MqlTick tick = g_lastTicks[i];
      if(tick.ask <= 0 || tick.bid <= 0) continue;

      double pip = PipSize(sym);
      double spreadPips = (tick.ask - tick.bid) / pip;
      int zeroSpread = (spreadPips <= 0.0) ? 1 : 0;
      double tickAgeMs = GetTickAgeMs(i);

      // Distinct ticks received in the 60 s before the bar close; empty field if history is unavailable
      MqlTick ticksRange[];
      int ticksCount = CopyTicksRange(sym, ticksRange, COPY_TICKS_ALL, fromMsc, toMsc - 1);
      string ticksStr = (ticksCount >= 0) ? IntegerToString(ticksCount) : "";

      FileWrite(g_fileHandle, timeStr, sym, DoubleToString(spreadPips, 3), IntegerToString(zeroSpread),
                DoubleToString(tickAgeMs, 1), ticksStr);
      g_rowsWritten++;
   }
   FileFlush(g_fileHandle);
}

//+------------------------------------------------------------------+
//| OnTick handler                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   for(int i = 0; i < g_symbolCount; i++)
   {
      UpdateTickWatcher(i);
   }
}
//+------------------------------------------------------------------+
