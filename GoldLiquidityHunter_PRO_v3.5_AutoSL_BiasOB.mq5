//+------------------------------------------------------------------+
//|                  GoldLiquidityHunter_PRO v3.5                    |
//|               AutoSL + Bias Daily EMA200 + Order Block           |
//|                  Version simplifiée et robuste                   |
//+------------------------------------------------------------------+
#property copyright "© 2026 Grok + User"
#property link      "https://github.com/eaglenight37"
#property version   "3.51"
#property strict
#property description "SMC/ICT EA — Biais D1 EMA200 + OB sur TF signal. SL structurel OB + min broker."
#property description "TP2 / trailing ATR / filtres news : inputs conservés, non implémentés dans cette build."

#include <Trade\Trade.mqh>
CTrade trade;

//--- Timeframe analyse (H4 Gold par défaut ; NAS100 H1 → WorkTF=PERIOD_H1)
input ENUM_TIMEFRAMES WorkTF             = PERIOD_H4;

//--- Risque & filtres
input double   RiskPercent               = 0.32;     // Risque par trade (% du solde)
input int      MaxTradesPerDay           = 0;       // 0 = illimité
input int      MaxSpreadPoints           = 0;       // 0 = désactivé (points bruts SYMBOL_SPREAD)
input bool     OnePositionPerSymbol     = true;   // Une seule position (ce symbole + magic)

//--- Biais D1
input double   EMA200_BiasBuffer         = 0.35;    // |close-EMA|/EMA*100 > seuil → biais (en %)

//--- OB + SL
input int      ATR_Period               = 14;       // Réservé (ATR chargé ; extension trailing future)
input double   OB_BodyRatio             = 0.33;
input int      OB_MaxAge_Bars           = 40;
input double   SL_BufferPoints          = 25.0;     // Buffer points sous/sur zone OB

input double   TP1_RR                   = 2.5;
input double   TP2_RR                   = 3.8;      // Non implémenté
input double   TP2_ClosePercent         = 55.0;     // Non implémenté
input double   BE_RR                    = 0.9;    // Non implémenté
input double   Trail_StartRR            = 1.2;    // Non implémenté
input double   Trail_ATR_Multi          = 0.60;   // Non implémenté

input int      MagicNumber              = 202605;
input int      LogLevel                 = 2;       // 0=silencieux, 1=important, 2=+détail

//--- Variables globales
double   point;
int      handleEMA_D1;
int      handleATR_Work;
double   g_ob_extreme = 0.0;   // LONG: low de l’OB ; SHORT: high de l’OB
bool     g_ob_valid   = false;
int      g_trades_today = 0;
int      g_trade_day_ymd = 0;

//+------------------------------------------------------------------+
void LogInfo(const string msg)
{
   if(LogLevel >= 1) Print(msg);
}

//+------------------------------------------------------------------+
void LogDbg(const string msg)
{
   if(LogLevel >= 2) Print(msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
   {
      Print("SYMBOL_POINT invalide");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   handleEMA_D1 = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   handleATR_Work = iATR(_Symbol, WorkTF, ATR_Period);

   if(handleEMA_D1 == INVALID_HANDLE || handleATR_Work == INVALID_HANDLE)
   {
      Print("Erreur création indicateurs");
      return INIT_FAILED;
   }

   LogInfo("GoldLiquidityHunter_PRO v3.51 AutoSL_BiasOB | WorkTF=" + EnumToString(WorkTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleEMA_D1 != INVALID_HANDLE)
      IndicatorRelease(handleEMA_D1);
   if(handleATR_Work != INVALID_HANDLE)
      IndicatorRelease(handleATR_Work);
}

//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastSignalBar = 0;
   datetime barOpen = iTime(_Symbol, WorkTF, 0);
   if(barOpen == 0)
      return;
   if(barOpen == lastSignalBar)
      return;
   lastSignalBar = barOpen;

   ResetDailyTradeCountIfNeeded();

   g_ob_valid = false;
   g_ob_extreme = 0.0;

   double bias = CalculateBias();
   if(bias == 0)
      return;

   if(!PassesSpreadFilter())
      return;

   if(!DetectOrderBlock(bias))
      return;

   if(MaxTradesPerDay > 0 && g_trades_today >= MaxTradesPerDay)
   {
      LogDbg("Max trades/jour atteint: " + IntegerToString(g_trades_today));
      return;
   }

   if(OnePositionPerSymbol && HasOurPosition())
      return;

   BuildAndOpenTrade(bias);
}

//+------------------------------------------------------------------+
void ResetDailyTradeCountIfNeeded()
{
   MqlDateTime t;
   TimeToStruct(TimeGMT(), t);
   int ymd = t.year * 10000 + t.mon * 100 + t.day;
   if(ymd != g_trade_day_ymd)
   {
      g_trade_day_ymd = ymd;
      g_trades_today = 0;
   }
}

//+------------------------------------------------------------------+
bool PassesSpreadFilter()
{
   if(MaxSpreadPoints <= 0)
      return true;
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(sp > MaxSpreadPoints)
   {
      LogDbg("Spread filtré: " + IntegerToString((int)sp) + " > " + IntegerToString(MaxSpreadPoints));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double CalculateBias()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(handleEMA_D1, 0, 1, 1, ema) != 1)
   {
      LogInfo("CalculateBias: CopyBuffer EMA échoué");
      return 0.0;
   }
   double closeD1 = iClose(_Symbol, PERIOD_D1, 1);
   if(closeD1 <= 0.0 || ema[0] <= 0.0)
      return 0.0;

   double diffPct = (closeD1 - ema[0]) / ema[0] * 100.0;
   double th = EMA200_BiasBuffer;

   if(diffPct > th)
      return 1.0;
   if(diffPct < -th)
      return -1.0;
   return 0.0;
}

//+------------------------------------------------------------------+
bool DetectOrderBlock(double bias)
{
   for(int i = 3; i < OB_MaxAge_Bars; i++)
   {
      double high  = iHigh(_Symbol, WorkTF, i);
      double low   = iLow(_Symbol, WorkTF, i);
      double open  = iOpen(_Symbol, WorkTF, i);
      double close = iClose(_Symbol, WorkTF, i);

      double body = MathAbs(close - open);
      double range = high - low;
      if(range == 0.0)
         continue;

      if(bias > 0)
      {
         if(close < open && body / range >= OB_BodyRatio)
         {
            if(iClose(_Symbol, WorkTF, i - 1) > iOpen(_Symbol, WorkTF, i - 1))
            {
               g_ob_extreme = low;
               g_ob_valid = true;
               return true;
            }
         }
      }
      else
      {
         if(close > open && body / range >= OB_BodyRatio)
         {
            if(iClose(_Symbol, WorkTF, i - 1) < iOpen(_Symbol, WorkTF, i - 1))
            {
               g_ob_extreme = high;
               g_ob_valid = true;
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
double MinStopDistancePrice()
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return (stopsLevel + 5) * point;
}

//+------------------------------------------------------------------+
double AutoSlDistancePrice()
{
   double minDist = MinStopDistancePrice();
   double buffer = SL_BufferPoints * point;
   return MathMax(buffer, minDist);
}

//+------------------------------------------------------------------+
void BuildAndOpenTrade(double bias)
{
   double entry = (bias > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double bufPx = SL_BufferPoints * point;
   double minDist = MinStopDistancePrice();
   double autoDist = AutoSlDistancePrice();

   double sl = 0.0;
   if(bias > 0)
   {
      double sl_auto = entry - autoDist;
      double sl_ob = (g_ob_valid) ? (g_ob_extreme - bufPx) : sl_auto;
      sl = MathMin(sl_ob, sl_auto);
      if(entry - sl < minDist)
         sl = entry - minDist;
      if(g_ob_valid && sl >= g_ob_extreme)
      {
         LogInfo("SL invalide vs OB (LONG), skip");
         return;
      }
   }
   else
   {
      double sl_auto = entry + autoDist;
      double sl_ob = (g_ob_valid) ? (g_ob_extreme + bufPx) : sl_auto;
      sl = MathMax(sl_ob, sl_auto);
      if(sl - entry < minDist)
         sl = entry + minDist;
      if(g_ob_valid && sl <= g_ob_extreme)
      {
         LogInfo("SL invalide vs OB (SHORT), skip");
         return;
      }
   }

   double sl_dist = MathAbs(entry - sl);
   double tp1 = (bias > 0) ? entry + TP1_RR * sl_dist : entry - TP1_RR * sl_dist;

   double lot = CalculateLotSize(entry, sl);
   if(lot <= 0.0)
   {
      LogInfo("Lot calculé nul, skip");
      return;
   }

   string cmt = (bias > 0) ? "v3.51 BUY" : "v3.51 SELL";
   bool ok = false;
   if(bias > 0)
      ok = trade.Buy(lot, _Symbol, entry, sl, tp1, cmt);
   else
      ok = trade.Sell(lot, _Symbol, entry, sl, tp1, cmt);

   if(!ok)
   {
      LogInfo("Ordre refusé retcode=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      return;
   }

   g_trades_today++;
   LogInfo("Trade ouvert v3.51 | Lot=" + DoubleToString(lot, 2) + " SL=" + DoubleToString(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double distPrice = MathAbs(entry - sl);
   double ticks = distPrice / tickSize;
   if(ticks <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lossPerLot = ticks * tickValue;
   if(lossPerLot <= 0.0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      lot = MathFloor(lot / lotStep) * lotStep;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
