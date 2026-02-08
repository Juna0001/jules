//+------------------------------------------------------------------+
//|                                              PairTrading_GSR.mq5 |
//|                                  Copyright 2024, Your Company.   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Your Company."
#property link      "https://www.mql5.com"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

//--- Input parameters
input int      InpMagicNumber = 123456;      // Magic Number
input string   InpSymbolXAU   = "XAUUSD";    // Gold Symbol
input string   InpSymbolXAG   = "XAGUSD";    // Silver Symbol
input double   InpBaseLotXAU  = 0.01;        // Base Lot for XAUUSD
input int      InpMAPeriod    = 20;          // MA Period for GSR (Closed Bars)
input double   InpBBDeviation = 2.0;         // Bollinger Bands Deviation
input double   InpMaxDeviation= 4.0;         // Max Deviation (Stop Loss)
input int      InpSlippage    = 3;           // Slippage

//--- Global variables
CTrade         trade;
double         xau_point, xag_point;
int            xau_digits, xag_digits;

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
//--- Check if new bar (optional for performance, but we use OnTick logic here)
//--- Calculate GSR Statistics (Mean, StdDev) using Closed Bars (Index 1 to Period)
   double gsr_mean, gsr_stddev;
   if(!CalculateGSRStats(gsr_mean, gsr_stddev))
      return;

//--- Get Current Prices
   double xau_ask = SymbolInfoDouble(InpSymbolXAU, SYMBOL_ASK);
   double xau_bid = SymbolInfoDouble(InpSymbolXAU, SYMBOL_BID);
   double xag_ask = SymbolInfoDouble(InpSymbolXAG, SYMBOL_ASK);
   double xag_bid = SymbolInfoDouble(InpSymbolXAG, SYMBOL_BID);

   if(xag_bid == 0 || xag_ask == 0) return; // Prevent division by zero

   double current_gsr = (xau_bid + xau_ask) / 2.0 / ((xag_bid + xag_ask) / 2.0); // Use Mid price for Realtime GSR

//--- Define Bands
   double upper_band = gsr_mean + (gsr_stddev * InpBBDeviation);
   double lower_band = gsr_mean - (gsr_stddev * InpBBDeviation);
   double stop_upper = gsr_mean + (gsr_stddev * InpMaxDeviation);
   double stop_lower = gsr_mean - (gsr_stddev * InpMaxDeviation);

//--- Check Existing Positions
   bool pos_long_gsr = false; // Long Gold, Short Silver (Betting on GSR UP)
   bool pos_short_gsr = false; // Short Gold, Long Silver (Betting on GSR DOWN)
   int xau_pos_count = 0;
   int xag_pos_count = 0;
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
            if(type == POSITION_TYPE_BUY) pos_long_gsr = true; // Bought Gold
            if(type == POSITION_TYPE_SELL) pos_short_gsr = true; // Sold Gold
           }
         else if(symbol == InpSymbolXAG)
           {
            xag_pos_count++;
            // Note: In a pair trade, Long GSR implies Short Silver.
            // If we have Long Silver, that implies Short GSR.
           }
        }
     }

   // Detect Orphan Positions (Only Gold or Only Silver)
   if(xau_pos_count != xag_pos_count)
     {
      // Simplistic handling: Do not enter new trades. Ideally, close orphans or alert user.
      // For this version, we prevent new entries.
      return;
     }

//--- Entry Logic
   if(xau_pos_count == 0 && xag_pos_count == 0) // No positions at all
     {
      // Sell Signal (GSR High -> Sell Gold, Buy Silver)
      if(current_gsr > upper_band)
        {
         double lot_xag = CalculateSilverLots(InpBaseLotXAU, xau_bid, xag_ask);
         if(lot_xag > 0)
           {
            if(trade.Sell(InpBaseLotXAU, InpSymbolXAU, xau_bid, 0, 0, "GSR Short Entry (Sell Gold)"))
              {
               if(!trade.Buy(lot_xag, InpSymbolXAG, xag_ask, 0, 0, "GSR Short Entry (Buy Silver)"))
                 {
                  Print("Error opening Silver leg! Close Gold manually.");
                  // Advanced: Close XAU immediately to avoid orphan
                 }
              }
           }
        }
      // Buy Signal (GSR Low -> Buy Gold, Sell Silver)
      else if(current_gsr < lower_band)
        {
         double lot_xag = CalculateSilverLots(InpBaseLotXAU, xau_ask, xag_bid);
         if(lot_xag > 0)
           {
            if(trade.Buy(InpBaseLotXAU, InpSymbolXAU, xau_ask, 0, 0, "GSR Long Entry (Buy Gold)"))
              {
               if(!trade.Sell(lot_xag, InpSymbolXAG, xag_bid, 0, 0, "GSR Long Entry (Sell Silver)"))
                 {
                  Print("Error opening Silver leg! Close Gold manually.");
                  // Advanced: Close XAU immediately to avoid orphan
                 }
              }
           }
        }
     }

//--- Exit Logic
   // Logic assumes paired positions exist. If orphans exist, this might still trigger if conditions met.

   if(pos_short_gsr) // We are Short GSR (Short Gold, Long Silver)
     {
      // Take Profit (Mean Reversion) OR Stop Loss (Divergence Expanded)
      if(current_gsr <= gsr_mean || current_gsr >= stop_upper)
        {
         CloseAllPositions();
        }
     }

   if(pos_long_gsr) // We are Long GSR (Long Gold, Short Silver)
     {
      // Take Profit (Mean Reversion) OR Stop Loss (Divergence Expanded)
      if(current_gsr >= gsr_mean || current_gsr <= stop_lower)
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

   // Get historical XAU Data (Close and Time) for Period + 1 (to skip index 0)
   int bars_needed = InpMAPeriod + 1;

   int copied_xau = CopyClose(InpSymbolXAU, PERIOD_CURRENT, 0, bars_needed, xau_close);
   int copied_time = CopyTime(InpSymbolXAU, PERIOD_CURRENT, 0, bars_needed, xau_time);

   if(copied_xau < bars_needed || copied_time < bars_needed)
      return(false);

   double sum = 0.0;
   double ratios[];
   ArrayResize(ratios, InpMAPeriod);
   int count = 0;

   // Iterate from index 1 (last closed bar) to InpMAPeriod
   for(int i = 1; i <= InpMAPeriod; i++)
     {
      // For each XAU bar time, get the corresponding XAG Close
      double xag_close_val[1];
      // Use CopyClose with start_time and count=1
      if(CopyClose(InpSymbolXAG, PERIOD_CURRENT, xau_time[i], 1, xag_close_val) != 1)
        {
         // If XAG data is missing for this timestamp, skip this sample
         // This reduces the sample size slightly but maintains time alignment
         continue;
        }

      if(xag_close_val[0] == 0) continue;

      ratios[count] = xau_close[i] / xag_close_val[0];
      sum += ratios[count];
      count++;
     }

   if(count < InpMAPeriod / 2) return(false); // Too few valid data points

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

   // Get Contract Sizes
   double contract_size_xau = SymbolInfoDouble(InpSymbolXAU, SYMBOL_TRADE_CONTRACT_SIZE);
   double contract_size_xag = SymbolInfoDouble(InpSymbolXAG, SYMBOL_TRADE_CONTRACT_SIZE);

   // Calculate Notional Value of Gold Position
   double gold_value = gold_lots * gold_price * contract_size_xau;

   // Calculate Required Silver Lots
   double raw_silver_lots = gold_value / (silver_price * contract_size_xag);

   // Normalize to Lot Step
   double step = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_STEP);
   double min_vol = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(InpSymbolXAG, SYMBOL_VOLUME_MAX);

   double normalized_lots = MathFloor(raw_silver_lots / step) * step;

   if(normalized_lots < min_vol) normalized_lots = min_vol;
   if(normalized_lots > max_vol) normalized_lots = max_vol;

   return(normalized_lots);
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
