//+------------------------------------------------------------------+
//|                                                    SpreadLog.mq5 |
//|                                  MT5 M1 Spread Observation Logger|
//|                                                                  |
//| Standalone Passive Telemetry Logger for Pre-Start Baseline (§3.3)|
//| Strictly read-only: Zero orders dispatched                       |
//+------------------------------------------------------------------+
#property copyright "Pre-Start Spread Measurement Protocol"
#property link      ""
#property version   "1.02"
#property strict

//--- Input Parameters
input group "=== Logger Parameters ==="
input string InpSymbols      = "EURUSD,USDJPY"; // Target symbols (comma separated)
input string InpLogFilename  = "spread_log.csv"; // Output filename in Common\Files

//--- Internal State
string   g_symbols[];
int      g_symbolCount = 0;
datetime g_lastBarTimes[];
int      g_fileHandle = INVALID_HANDLE;

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
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[SPREAD_LOG] Initializing passive spread telemetry logger...");

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
   ArrayResize(g_lastBarTimes, g_symbolCount);

   for(int i = 0; i < g_symbolCount; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
      g_symbols[i] = parts[i];
      g_lastBarTimes[i] = 0;

      if(!SymbolSelect(g_symbols[i], true))
      {
         PrintFormat("[SPREAD_LOG] WARNING: Failed to select symbol %s in MarketWatch.", g_symbols[i]);
      }
   }

   // Open append-only CSV in Common\Files
   bool exists = FileIsExist(InpLogFilename, FILE_COMMON);
   g_fileHandle = FileOpen(InpLogFilename, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
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
      FileWrite(g_fileHandle, "time_utc", "symbol", "spread_pips");
      FileFlush(g_fileHandle);
   }

   EventSetTimer(1);
   PrintFormat("[SPREAD_LOG] Active. Logging to Common\\Files\\%s at completed M1 bars in session.", InpLogFilename);
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
   PrintFormat("[SPREAD_LOG] Deinitialized (reason: %d)", reason);
}

//+------------------------------------------------------------------+
//| Periodic poll timer                                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime gmtNow = TimeGMT();
   if(!IsInSession(gmtNow)) return;

   for(int i = 0; i < g_symbolCount; i++)
   {
      string sym = g_symbols[i];
      datetime curBarTime = iTime(sym, PERIOD_M1, 0);
      if(curBarTime == 0) continue;

      if(g_lastBarTimes[i] == 0)
      {
         g_lastBarTimes[i] = curBarTime;
         continue;
      }

      // Completed M1 bar detected when current bar time advances
      if(curBarTime != g_lastBarTimes[i])
      {
         g_lastBarTimes[i] = curBarTime;

         MqlTick tick;
         if(!SymbolInfoTick(sym, tick)) continue;
         if(tick.ask <= 0 || tick.bid <= 0) continue;

         double pip = PipSize(sym);
         double spreadPips = (tick.ask - tick.bid) / pip;

         MqlDateTime dt;
         TimeToStruct(gmtNow, dt);
         string timeStr = StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                                       dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);

         FileWrite(g_fileHandle, timeStr, sym, DoubleToString(spreadPips, 3));
         FileFlush(g_fileHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTick handler                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   OnTimer();
}
//+------------------------------------------------------------------+
