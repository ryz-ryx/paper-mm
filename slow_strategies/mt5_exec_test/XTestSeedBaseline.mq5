//+------------------------------------------------------------------+
//|                                            XTestSeedBaseline.mq5 |
//|                                      ExecTest smoke-harness tool |
//| Seeds ExecTest's daily equity baseline ABOVE current equity, so  |
//| ExecTest's LoadPersistentState() loads it and the entry gate     |
//| halts on its first pass (T5A). Places no orders.                 |
//+------------------------------------------------------------------+
#property copyright "ExecTest Rig"
#property link      ""
#property version   "1.00"
#property script_show_inputs false

input double InpBaselineOffsetEUR = 5.0;   // seeded baseline = current equity + offset

// Same keys and the same UTC-midnight rule as ExecTest.mq5 LoadPersistentState():
//   todayStart = TimeGMT() - (hour*3600 + min*60 + sec); the baseline is used only if
//   EXECTEST_BASELINE_DATE_UTC == todayStart and EXECTEST_BASELINE_EQUITY exists.
#define GV_BASELINE_EQUITY    "EXECTEST_BASELINE_EQUITY"
#define GV_BASELINE_DATE_UTC  "EXECTEST_BASELINE_DATE_UTC"
#define SEED_MARKER_FILE      "xtest_seed_baseline.txt"   // Common\Files, read by run_smoke_tests.ps1

void OnStart()
{
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("[SEED BASELINE] REFUSED: account is not a demo account");
      return;
   }

   // The script can start before the account is authorized; wait up to 30 s for equity
   for(int i = 0; i < 150 && (!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoDouble(ACCOUNT_EQUITY) <= 0.0); i++)
      Sleep(200);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0)
   {
      Print("[SEED BASELINE] FAILED: account equity unavailable after 30 s");
      return;
   }

   datetime nowUtc = TimeGMT();
   MqlDateTime mdt;
   TimeToStruct(nowUtc, mdt);
   datetime todayStart = nowUtc - (mdt.hour * 3600 + mdt.min * 60 + mdt.sec);
   double baseline = equity + InpBaselineOffsetEUR;

   GlobalVariableSet(GV_BASELINE_DATE_UTC, (double)todayStart);
   GlobalVariableSet(GV_BASELINE_EQUITY, baseline);
   GlobalVariablesFlush();

   double rbEquity = GlobalVariableGet(GV_BASELINE_EQUITY);
   datetime rbDate = (datetime)GlobalVariableGet(GV_BASELINE_DATE_UTC);
   bool ok = (MathAbs(rbEquity - baseline) < 0.005 && rbDate == todayStart);

   string result = StringFormat("[SEED BASELINE] %s equity=%.2f baseline=%.2f offset=%.2f date_utc=%I64d (%s) readback=%.2f/%I64d",
                                ok ? "OK" : "FAILED", equity, baseline, InpBaselineOffsetEUR, (long)todayStart,
                                TimeToString(todayStart, TIME_DATE), rbEquity, (long)rbDate);
   Print(result);

   // The terminal buffers Experts-log writes (the 2026-10-13 run: this line was not on disk ~88 s later),
   // so the harness waits on this marker file instead; FileClose puts it on disk immediately.
   int h = FileOpen(SEED_MARKER_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, result + "\r\n");
      FileClose(h);
   }
   else
      PrintFormat("[SEED BASELINE] marker file %s could not be written (error %d)", SEED_MARKER_FILE, GetLastError());
}
//+------------------------------------------------------------------+
