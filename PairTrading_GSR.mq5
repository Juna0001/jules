//+------------------------------------------------------------------+
//|                                              PairTrading_GSR.mq5 |
//|                                  Copyright 2024, Your Company.   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Company."
#property link      "https://www.mql5.com"
#property version   "1.03"
#property strict

#include <Trade/Trade.mqh>

//--- Input parameters
input int      InpMagicNumber = 123456;      // Magic Number
input string   InpSymbolXAU   = "XAUUSD";    // Gold Symbol
input string   InpSymbolXAG   = "XAGUSD";    // Silver Symbol
input double   InpBaseLotXAU  = 0.01;        // Base Lot for XAUUSD
input int      InpMAPeriod    = 100;         // MA Period for GSR (Closed Bars)
input double   InpBBDeviation = 2.2;         // Bollinger Bands Deviation
input double   InpMaxDeviation= 4.0;         // Max Deviation (Stop Loss)
input int      InpSlippage    = 3;           // Slippage
input int      InpMaxRetries  = 5;           // Max Retries for 2nd Leg
input int      InpRetryDelay  = 500;         // Delay between retries (ms)

//--- Global variables
CTrade         trade;
double         xau_point, xag_point;
int            xau_digits, xag_digits;
datetime       last_bar_time = 0;
double         g_gsr_mean = 0.0;
double         g_gsr_stddev = 0.0;

//--- Execution Control
datetime       last_trade_attempt_time = 0;
const int      TRADE_COOLDOWN_SEC = 60; // 1 minute cooldown after failure

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Verify symbols exist
   if(!SymbolSelect(InpSymbolXAU, true))
     {
      Print("Error: Symbol ", InpSymbolXAU, " not found.");
      return(INIT_FAILED);
     }
   if(!SymbolSelect(InpSymbolXAG, true))
     {
      Print("Error: Symbol ", InpSymbolXAG, " not found.");
      return(INIT_FAILED);
     }

//--- Get symbol properties
   xau_point = SymbolInfoDouble(InpSymbolXAU, SYMBOL_POINT);
   xau_digits = (int)SymbolInfoInteger(InpSymbolXAU, SYMBOL_DIGITS);
   xag_point = SymbolInfoDouble(InpSymbolXAG, SYMBOL_POINT);
   xag_digits = (int)SymbolInfoInteger(InpSymbolXAG, SYMBOL_DIGITS);

//--- Set Magic Number
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Check for New Bar to update statistics
   datetime current_time = iTime(InpSymbolXAU, PERIOD_CURRENT, 0);
   if(last_bar_time != current_time)
     {
      if(CalculateGSRStats(g_gsr_mean, g_gsr_stddev))
        {
         last_bar_time = current_time;
         Print("Updated GSR Stats: Mean=", g_gsr_mean, " StdDev=", g_gsr_stddev);
        }
      else
        {
         return; // Data not ready
        }
     }

   if(g_gsr_mean == 0.0) return; // Stats not calculated yet

//--- Get Current Prices
   double xau_ask = SymbolInfoDouble(InpSymbolXAU, SYMBOL_ASK);
   double xau_bid = SymbolInfoDouble(InpSymbolXAU, SYMBOL_BID);
   double xag_ask = SymbolInfoDouble(InpSymbolXAG, SYMBOL_ASK);
   double xag_bid = SymbolInfoDouble(InpSymbolXAG, SYMBOL_BID);

   if(xag_bid == 0 || xag_ask == 0) return;

   // Calculate GSR based on Execution Prices (Spread Aware)
   // For Selling Ratio: Sell Gold (Bid) / Buy Silver (Ask)
   double gsr_sell = xau_bid / xag_ask;
   // For Buying Ratio: Buy Gold (Ask) / Sell Silver (Bid)
   double gsr_buy = xau_ask / xag_bid;

   // Mid Price GSR for Mean Reversion Check
   double mid_gsr = ((xau_bid + xau_ask) / 2.0) / ((xag_bid + xag_ask) / 2.0);

//--- Define Bands
   double upper_band = g_gsr_mean + (g_gsr_stddev * InpBBDeviation);
   double lower_band = g_gsr_mean - (g_gsr_stddev * InpBBDeviation);
   double stop_upper = g_gsr_mean + (g_gsr_stddev * InpMaxDeviation);
   double stop_lower = g_gsr_mean - (g_gsr_stddev * InpMaxDeviation);

//--- Check Existing Positions
   bool pos_long_gsr = false; // Long Gold, Short Silver
   bool pos_short_gsr = false; // Short Gold, Long Silver
   int xau_pos_count = 0;
   int xag_pos_count = 0;
   ulong xau_ticket = 0; // To track orphan ticket
   ulong xag_ticket = 0;
   int positions_count = PositionsTotal();

   for(int i = positions_count - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         long type = PositionGetInteger(POSITION_TYPE);

         if(symbol == InpSymbolXAU)
           {
            xau_pos_count++;
            xau_ticket = ticket;
            if(type == POSITION_TYPE_BUY) pos_long_gsr = true;
            if(type == POSITION_TYPE_SELL) pos_short_gsr = true;
           }
         else if(symbol == InpSymbolXAG)
           {
            xag_pos_count++;
            xag_ticket = ticket;
           }
        }
     }

   // Handle Orphans (If count mismatch)
   if(xau_pos_count != xag_pos_count)
     {
      // Simple Fail-Safe: Close the orphan position immediately
      Print("Orphan Position Detected! Closing to neutralize risk.");
      if(xau_pos_count > 0) trade.PositionClose(xau_ticket);
      if(xag_pos_count > 0) trade.PositionClose(xag_ticket);

      // Set Cooldown to prevent immediate retry
      last_trade_attempt_time = TimeCurrent();
      return;
     }

//--- Entry Logic
   // Check Cooldown
   if(TimeCurrent() < last_trade_attempt_time + TRADE_COOLDOWN_SEC) return;

   if(xau_pos_count == 0 && xag_pos_count == 0)
     {
      // Sell Signal (GSR High -> Sell Gold, Buy Silver)
      // Use gsr_sell (Bid/Ask) to account for spread cost
      if(gsr_sell > upper_band)
        {
         double lot_xag = CalculateSilverLots(InpBaseLotXAU, xau_bid, xag_ask);

         // Strict Check before execution
         if(CheckVolumeRequirements(InpSymbolXAG, lot_xag))
           {
            // Execute Leg 1: Sell Gold
            if(trade.Sell(InpBaseLotXAU, InpSymbolXAU, xau_bid, 0, 0, "GSR Short Entry (Sell Gold)"))
              {
               ulong ticket1 = trade.ResultOrder(); // Get ticket of first leg
               bool leg2_success = false;

               // Retry Logic for Leg 2: Buy Silver
               for(int r=0; r<InpMaxRetries; r++)
                 {
                  double current_ask = SymbolInfoDouble(InpSymbolXAG, SYMBOL_ASK);
                  if(trade.Buy(lot_xag, InpSymbolXAG, current_ask, 0, 0, "GSR Short Entry (Buy Silver)"))
                    {
                     leg2_success = true;
                     break;
                    }
                  Sleep(InpRetryDelay);
                 }

               // Fail-Safe: If Leg 2 failed after retries, Close Leg 1
               if(!leg2_success)
                 {
                  Print("Leg 2 Failed! Closing Leg 1 immediately. Error: ", GetLastError());
                  trade.PositionClose(ticket1);
                  last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
                 }
              }
             else
              {
               Print("Leg 1 Failed. Error: ", GetLastError());
               last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
              }
           }
         else
           {
            Print("Invalid Volume for Silver: ", lot_xag);
            last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
           }
        }
      // Buy Signal (GSR Low -> Buy Gold, Sell Silver)
      // Use gsr_buy (Ask/Bid)
      else if(gsr_buy < lower_band)
        {
         double lot_xag = CalculateSilverLots(InpBaseLotXAU, xau_ask, xag_bid);

         if(CheckVolumeRequirements(InpSymbolXAG, lot_xag))
           {
            // Execute Leg 1: Buy Gold
            if(trade.Buy(InpBaseLotXAU, InpSymbolXAU, xau_ask, 0, 0, "GSR Long Entry (Buy Gold)"))
              {
               ulong ticket1 = trade.ResultOrder();
               bool leg2_success = false;

               // Retry Logic for Leg 2: Sell Silver
               for(int r=0; r<InpMaxRetries; r++)
                 {
                  double current_bid = SymbolInfoDouble(InpSymbolXAG, SYMBOL_BID);
                  if(trade.Sell(lot_xag, InpSymbolXAG, current_bid, 0, 0, "GSR Long Entry (Sell Silver)"))
                    {
                     leg2_success = true;
                     break;
                    }
                  Sleep(InpRetryDelay);
                 }

               // Fail-Safe
               if(!leg2_success)
                 {
                  Print("Leg 2 Failed! Closing Leg 1 immediately. Error: ", GetLastError());
                  trade.PositionClose(ticket1);
                  last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
                 }
              }
             else
              {
               Print("Leg 1 Failed. Error: ", GetLastError());
               last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
              }
           }
         else
           {
            Print("Invalid Volume for Silver: ", lot_xag);
            last_trade_attempt_time = TimeCurrent(); // Activate Cooldown
           }
        }
     }

//--- Exit Logic
   // Use Mid-Price GSR for Mean Reversion to avoid premature exit due to spread widening

   if(pos_short_gsr) // Short Gold, Long Silver
     {
      if(mid_gsr <= g_gsr_mean || mid_gsr >= stop_upper)
        {
         CloseAllPositions();
        }
     }

   if(pos_long_gsr) // Long Gold, Short Silver
     {
      if(mid_gsr >= g_gsr_mean || mid_gsr <= stop_lower)
        {
         CloseAllPositions();
        }
     }
  }

//+------------------------------------------------------------------+
//| Calculate MA and StdDev of GSR based on Close Prices             |
//+------------------------------------------------------------------+
bool CalculateGSRStats(double &mean, double &stddev)
  {
   double xau_close[];
   datetime xau_time[];

   ArraySetAsSeries(xau_close, true);
   ArraySetAsSeries(xau_time, true);

   int bars_needed = InpMAPeriod + 1;

   int copied_xau = CopyClose(InpSymbolXAU, PERIOD_CURRENT, 0, bars_needed, xau_close);
   int copied_time = CopyTime(InpSymbolXAU, PERIOD_CURRENT, 0, bars_needed, xau_time);

   if(copied_xau < bars_needed || copied_time < bars_needed)
      return(false);

   double sum = 0.0;
   double ratios[];
   ArrayResize(ratios, InpMAPeriod);
   int count = 0;

   for(int i = 1; i <= InpMAPeriod; i++)
     {
      double xag_close_val[1];
      if(CopyClose(InpSymbolXAG, PERIOD_CURRENT, xau_time[i], 1, xag_close_val) != 1)
        {
         continue;
        }

      if(xag_close_val[0] == 0) continue;

      ratios[count] = xau_close[i] / xag_close_val[0];
      sum += ratios[count];
      count++;
     }

   if(count < InpMAPeriod / 2) return(false);

   mean = sum / count;

   double sum_sq_diff = 0.0;
   for(int i = 0; i < count; i++)
     {
      sum_sq_diff += MathPow(ratios[i] - mean, 2);
     }

   stddev = MathSqrt(sum_sq_diff / count);
   return(true);
  }

//+------------------------------------------------------------------+
//| Calculate Silver Lots for Dollar Neutrality                      |
//+------------------------------------------------------------------+
double CalculateSilverLots(double gold_lots, double gold_price, double silver_price)
  {
   if(silver_price == 0) return(0.0);

   double contract_size_xau = SymbolInfoDouble(InpSymbolXAU, SYMBOL_TRADE_CONTRACT_SIZE);
   double contract_size_xag = SymbolInfoDouble(InpSymbolXAG, SYMBOL_TRADE_CONTRACT_SIZE);

   double gold_value = gold_lots * gold_price * contract_size_xau;
   double raw_silver_lots = gold_value / (silver_price * contract_size_xag);

   double step = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_STEP);
   double min_vol = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_MAX);

   double normalized_lots = MathFloor(raw_silver_lots / step) * step;

   if(normalized_lots < min_vol) normalized_lots = min_vol;
   if(normalized_lots > max_vol) normalized_lots = max_vol;

   return(normalized_lots);
  }

//+------------------------------------------------------------------+
//| Check Volume Requirements                                        |
//+------------------------------------------------------------------+
bool CheckVolumeRequirements(string symbol, double volume)
  {
   double min_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(volume < min_vol) return(false);
   if(volume > max_vol) return(false);

   // Check if volume is multiple of step
   // if(MathMod(volume, step_vol) > 0.000001) return(false); // Can be strict

   return(true);
  }

//+------------------------------------------------------------------+
//| Close All Positions with Magic Number                            |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         trade.PositionClose(ticket);
        }
     }
  }
