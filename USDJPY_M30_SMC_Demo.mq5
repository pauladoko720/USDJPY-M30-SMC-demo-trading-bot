
#property strict
#property version "0.10"
#property description "USDJPY M30 SMC-style DEMO starter"

#include <Trade/Trade.mqh>
CTrade trade;

input double RiskPercent = 1.0;
input double DailyLossLimitPercent = 3.0;
input double RewardRisk = 2.0;
input int StructureBars = 10;
input int StopLookbackBars = 5;
input ulong MagicNumber = 301024;

datetime lastBar = 0;
string dayKey = "";

bool IsDemo()
{
   return AccountInfoInteger(ACCOUNT_TRADE_MODE)
          == ACCOUNT_TRADE_MODE_DEMO;
}

double HighestHigh(ENUM_TIMEFRAMES tf, int start, int count)
{
   double result = -DBL_MAX;
   for(int i = start; i < start + count; i++)
   {
      double v = iHigh(_Symbol, tf, i);
      if(v > result) result = v;
   }
   return result;
}

double LowestLow(ENUM_TIMEFRAMES tf, int start, int count)
{
   double result = DBL_MAX;
   for(int i = start; i < start + count; i++)
   {
      double v = iLow(_Symbol, tf, i);
      if(v < result) result = v;
   }
   return result;
}

bool DailyLossLocked()
{
   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);

   string key = StringFormat("SMC_%I64d_%04d%02d%02d",
      AccountInfoInteger(ACCOUNT_LOGIN),
      d.year, d.mon, d.day);

   if(key != dayKey)
   {
      dayKey = key;
      if(!GlobalVariableCheck(dayKey))
         GlobalVariableSet(dayKey, AccountInfoDouble(ACCOUNT_EQUITY));
   }

   double startEquity = GlobalVariableGet(dayKey);
   if(startEquity <= 0) return true;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = 100.0 * (startEquity - equity)
                        / startEquity;

   return lossPercent >= DailyLossLimitPercent;
}

double CalculateVolume(ENUM_ORDER_TYPE type,
                       double entry, double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY)
                      * RiskPercent / 100.0;

   double result = 0;
   if(!OrderCalcProfit(type, _Symbol, 1.0,
                       entry, sl, result))
      return 0;

   double lossPerLot = MathAbs(result);
   if(lossPerLot <= 0) return 0;

   double volume = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0 || volume < minVol) return 0;

   volume = MathFloor(volume / step) * step;
   volume = MathMin(volume, maxVol);

   return NormalizeDouble(volume, 8);
}

int OnInit()
{
   if(!IsDemo())
   {
      Print("STOP: DEMO ACCOUNT REQUIRED.");
      return INIT_FAILED;
   }

   if(_Symbol != "USDJPY")
   {
      Print("Attach to the USDJPY chart only.");
      return INIT_FAILED;
   }

   if(_Period != PERIOD_M30)
   {
      Print("Use the M30 chart.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   if(!IsDemo()) return;

   datetime bar = iTime(_Symbol, PERIOD_M30, 0);
   if(bar == 0 || bar == lastBar) return;
   lastBar = bar;

   if(DailyLossLocked())
   {
      Print("Daily loss limit reached. No new entries.");
      return;
   }

   if(PositionSelect(_Symbol)) return;

   if(Bars(_Symbol, PERIOD_H1) < StructureBars + 3 ||
      Bars(_Symbol, PERIOD_M30) < StructureBars + 3)
      return;

   // Simplified H1 structure-break bias
   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   double h1High = HighestHigh(PERIOD_H1, 2, StructureBars);
   double h1Low = LowestLow(PERIOD_H1, 2, StructureBars);

   int bias = 0;
   if(h1Close > h1High) bias = 1;
   if(h1Close < h1Low)  bias = -1;
   if(bias == 0) return;

   // M30 breakout must agree with H1 bias
   double m30Close = iClose(_Symbol, PERIOD_M30, 1);
   double m30High = HighestHigh(PERIOD_M30, 2, StructureBars);
   double m30Low = LowestLow(PERIOD_M30, 2, StructureBars);

   bool buySignal = bias == 1 && m30Close > m30High;
   bool sellSignal = bias == -1 && m30Close < m30Low;
   if(!buySignal && !sellSignal) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double entry, sl, tp, volume;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(buySignal)
   {
      entry = tick.ask;
      sl = LowestLow(PERIOD_M30, 1, StopLookbackBars);
      if(sl >= entry) return;

      tp = entry + (entry - sl) * RewardRisk;
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      if(entry - sl < SymbolInfoInteger(_Symbol,
                                        SYMBOL_TRADE_STOPS_LEVEL) * point)
         return;

      volume = CalculateVolume(ORDER_TYPE_BUY, entry, sl);
      if(volume <= 0) return;

      if(!trade.Buy(volume, _Symbol, 0, sl, tp, "SMC demo buy"))
         Print("Buy rejected: ", trade.ResultRetcodeDescription());
   }

   if(sellSignal)
   {
      entry = tick.bid;
      sl = HighestHigh(PERIOD_M30, 1, StopLookbackBars);
      if(sl <= entry) return;

      tp = entry - (sl - entry) * RewardRisk;
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);

      if(sl - entry < SymbolInfoInteger(_Symbol,
                                        SYMBOL_TRADE_STOPS_LEVEL) * point)
         return;

      volume = CalculateVolume(ORDER_TYPE_SELL, entry, sl);
      if(volume <= 0) return;

      if(!trade.Sell(volume, _Symbol, 0, sl, tp, "SMC demo sell"))
         Print("Sell rejected: ", trade.ResultRetcodeDescription());
   }
}
