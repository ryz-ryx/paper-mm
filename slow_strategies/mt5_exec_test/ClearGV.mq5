//+------------------------------------------------------------------+
//|                                                      ClearGV.mq5 |
//|                                      ExecTest GlobalVariable Cleaner |
//|                             Deletes all EXECTEST_* Global Variables |
//+------------------------------------------------------------------+
#property copyright "ExecTest Rig"
#property link      ""
#property version   "1.00"
#property script_show_inputs false

void OnStart()
{
   Print("=== [ClearGV] Starting GlobalVariable Cleanup ===");
   int total_before = GlobalVariablesTotal();
   PrintFormat("[ClearGV] Total global variables before scan: %d", total_before);

   // 1. Scan and print all EXECTEST_* variables before deletion
   int match_count = 0;
   for(int i = 0; i < total_before; i++)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "EXECTEST_") == 0)
      {
         double val = GlobalVariableGet(name);
         datetime last_time = (datetime)GlobalVariableCheck(name);
         PrintFormat("  [BEFORE] Found: %s = %.4f (Last Modified: %s)", 
                     name, val, TimeToString(last_time, TIME_DATE|TIME_SECONDS));
         match_count++;
      }
   }
   PrintFormat("[ClearGV] Total EXECTEST_* variables identified: %d", match_count);

   // 2. Delete all EXECTEST_* variables
   // Note: When deleting by name, iterate backward or re-check count
   int deleted_count = 0;
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "EXECTEST_") == 0)
      {
         if(GlobalVariableDel(name))
         {
            PrintFormat("  [DELETED] %s successfully removed.", name);
            deleted_count++;
         }
         else
         {
            PrintFormat("  [ERROR] Failed to delete %s. Error code: %d", name, GetLastError());
         }
      }
   }

   // Persist the deletions now; otherwise they only reach gvariables.dat on a graceful terminal shutdown
   GlobalVariablesFlush();

   // 3. Confirm after-state
   int total_after = GlobalVariablesTotal();
   int remaining_matches = 0;
   for(int i = 0; i < total_after; i++)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "EXECTEST_") == 0)
      {
         double val = GlobalVariableGet(name);
         PrintFormat("  [AFTER - WARNING REMAINING] %s = %.4f", name, val);
         remaining_matches++;
      }
   }

   PrintFormat("=== [ClearGV] Summary: %d deleted, %d remaining matching. Total GVs: %d -> %d ===",
               deleted_count, remaining_matches, total_before, total_after);
}
//+------------------------------------------------------------------+
