//+------------------------------------------------------------------+
//|                  GoldLiquidityHunter_PRO v3.5                    |
//|               AutoSL + Bias Daily EMA200 + Order Block           |
//|                  Version simplifiée et robuste                   |
//+------------------------------------------------------------------+
#property copyright "© 2026 Grok + User"
#property link      "https://github.com/eaglenight37"
#property version   "3.50"
#property strict
#property description "SMC/ICT EA - Biais Daily EMA200 + Order Block seulement - SL automatique"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input double   RiskPercent         = 0.32;      // Risque par trade en %
input int      ATR_Period          = 14;        // Période ATR
input double   OB_BodyRatio        = 0.33;      // Ratio minimum corps/range pour OB
input int      OB_MaxAge_Bars      = 40;        // Age max de l'OB (en bars H4)
input double   SL_BufferPoints     = 25.0;      // Buffer SL (sera auto-ajusté avec le broker)
input double   TP1_RR              = 2.5;       // Take Profit 1
input double   TP2_RR              = 3.8;       // Take Profit 2
input double   TP2_ClosePercent    = 55.0;      // % fermé à TP2
input double   BE_RR               = 0.9;       // Breakeven à X R
input double   Trail_StartRR       = 1.2;       // Début trailing
input double   Trail_ATR_Multi     = 0.60;      // Multiplicateur ATR pour trailing

input int      MagicNumber         = 202605;    // Magic Number
input int      LogLevel            = 2;         // 1=Info, 2=Info+Debug, 3=Full

//--- Variables globales
datetime lastBarTime = 0;
double   point;
int      handleEMA_D1;
int      handleATR_H4;

//+------------------------------------------------------------------+
int OnInit()
{
   point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   handleEMA_D1 = iMA(NULL, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   handleATR_H4 = iATR(NULL, PERIOD_H4, ATR_Period);
   
   if(handleEMA_D1 == INVALID_HANDLE || handleATR_H4 == INVALID_HANDLE)
   {
      Print("Erreur création indicateurs");
      return INIT_FAILED;
   }
   
   Print("GoldLiquidityHunter_PRO v3.5 AutoSL_BiasOB initialisé avec succès");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Time[0] == lastBarTime) return;
   lastBarTime = Time[0];
   
   OnNewBar();
}

//+------------------------------------------------------------------+
void OnNewBar()
{
   if(!IsNewBar()) return;
   
   // Biais Daily EMA200
   double bias = CalculateBias();
   if(bias == 0) return; // neutre
   
   // Détection Order Block
   if(!DetectOrderBlock(bias)) return;
   
   // Construction du signal et ouverture
   BuildAndOpenTrade(bias);
}

//+------------------------------------------------------------------+
double CalculateBias()
{
   double ema[];
   CopyBuffer(handleEMA_D1, 0, 1, 1, ema);
   double closeD1 = iClose(NULL, PERIOD_D1, 1);
   
   double diffPct = (closeD1 - ema[0]) / ema[0] * 100;
   
   if(diffPct > 0.35)  return 1;  // LONG
   if(diffPct < -0.35) return -1; // SHORT
   return 0; // neutre
}

//+------------------------------------------------------------------+
bool DetectOrderBlock(double bias)
{
   // Logique simplifiée OB (dernière bougie opposée + confirmation)
   for(int i = 3; i < OB_MaxAge_Bars; i++)
   {
      double high = iHigh(NULL, PERIOD_H4, i);
      double low  = iLow(NULL, PERIOD_H4, i);
      double open = iOpen(NULL, PERIOD_H4, i);
      double close = iClose(NULL, PERIOD_H4, i);
      
      double body = MathAbs(close - open);
      double range = high - low;
      
      if(range == 0) continue;
      
      if(bias > 0) // LONG → on cherche un OB baissier
      {
         if(close < open && body/range >= OB_BodyRatio)
         {
            // Confirmation haussière après
            if(iClose(NULL, PERIOD_H4, i-1) > iOpen(NULL, PERIOD_H4, i-1))
            {
               // Zone OB = low de cette bougie
               return true;
            }
         }
      }
      else // SHORT → on cherche un OB haussier
      {
         if(close > open && body/range >= OB_BodyRatio)
         {
            if(iClose(NULL, PERIOD_H4, i-1) < iOpen(NULL, PERIOD_H4, i-1))
            {
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void BuildAndOpenTrade(double bias)
{
   double sl_distance = CalculateAutoSLDistance(bias);
   double entry = (bias > 0) ? Ask : Bid;
   
   double sl = (bias > 0) ? entry - sl_distance : entry + sl_distance;
   double tp1 = (bias > 0) ? entry + TP1_RR * sl_distance : entry - TP1_RR * sl_distance;
   
   double lot = CalculateLotSize(entry, sl);
   
   if(bias > 0)
      trade.Buy(lot, _Symbol, entry, sl, tp1, "v3.5 BUY");
   else
      trade.Sell(lot, _Symbol, entry, sl, tp1, "v3.5 SELL");
   
   Print("🟢 Trade ouvert v3.5 | Lot: ", lot);
}

//+------------------------------------------------------------------+
double CalculateAutoSLDistance(double bias)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = (stopsLevel + 5) * point;
   double buffer   = SL_BufferPoints * point;
   
   return MathMax(buffer, minDist);
}

//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
   double riskMoney = AccountBalance() * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double distance  = MathAbs(entry - sl) / point;
   
   double lot = riskMoney / (distance * tickValue);
   lot = NormalizeDouble(lot, 2);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastTime = 0;
   datetime currentTime = iTime(NULL, PERIOD_H4, 0);
   if(currentTime != lastTime)
   {
      lastTime = currentTime;
      return true;
   }
   return false;
}