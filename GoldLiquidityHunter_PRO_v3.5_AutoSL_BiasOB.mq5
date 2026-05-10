//+------------------------------------------------------------------+
//|     GoldLiquidityHunter_PRO v3.4 – Simple Version (Bias + OB)   |
//|          Copyright 2026, Professional Trading Systems            |
//|           XAUUSD / NAS100 – ICT/SMC Simplified Expert Advisor   |
//+------------------------------------------------------------------+
/*
╔══════════════════════════════════════════════════════════════════════╗
║           USER MANUAL – GoldLiquidityHunter_PRO v3.4 SIMPLE          ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  VERSION SIMPLIFIÉE : Biais Daily EMA200 + Order Block seulement   ║
║  (Sweep et Displacement désactivés par défaut pour plus de trades)  ║
║                                                                      ║
║  MEILLEURE CONFIGURATION :                                           ║
║  - Paire     : XAUUSD (H4) ou NAS100 (H1)                           ║
║  - Timeframe : H4 (XAUUSD) ou H1 (NAS100)                           ║
║                                                                      ║
║  PARAMÈTRES RECOMMANDÉS :                                            ║
║  RiskPercent         = 0.50                                         ║
║  MaxTradesPerDay     = 3                                            ║
║  OB_BodyRatio        = 0.35                                         ║
║  OB_MaxAge_Bars      = 40                                           ║
║  SL_BufferPoints     = 25.0  (le code calcule auto le Stops Level)  ║
║  TP1_RR              = 2.5                                          ║
║  TP2_RR              = 3.8                                          ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
*/

#property copyright   "Professional Trading Systems 2026"
#property link        "https://goldliquidityhunter.pro"
#property version     "3.50"
#property description "GoldLiquidityHunter_PRO v3.5 – Auto Stops Level + Bias + OB"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//|                    STRUCTURES DE DONNÉES                          |
//+------------------------------------------------------------------+

struct SBias
{
   bool     valid;
   int      direction;   // 1=LONG | -1=SHORT | 0=NEUTRE
   double   ema200;
   double   closeD1;
   string   label;
};

struct SOrderBlock
{
   bool     valid;
   bool     bullish;
   double   obHigh;
   double   obLow;
   double   obEntryHigh;
   double   obEntryLow;
   int      barIndex;
   datetime obTime;
};

struct SActiveTrade
{
   bool     isOpen;
   ulong    ticket;
   int      direction;
   double   entryPrice;
   double   sl;
   double   tp1;
   double   tp2;
   double   riskAmount;
   bool     tp2Hit;
   bool     beActivated;
   bool     trailActivated;
   datetime openTime;
};

//+------------------------------------------------------------------+
//|              INPUTS – VERSION SIMPLIFIÉE                          |
//+------------------------------------------------------------------+

input group "══ RISK MANAGEMENT ══"
input double   RiskPercent        = 0.50;   // Risque par trade (% balance)
input double   MaxDailyLossPct    = 2.00;   // Perte journalière max (%)
input double   MaxDrawdownPct     = 10.00;  // Drawdown global max (%)
input int      MaxTradesPerDay    = 3;      // Trades max par jour
input bool     EnableDD_Pause     = true;

input group "══ STRATEGY CORE (SIMPLIFIÉ) ══"
input int      ATR_Period         = 14;
input int      OB_MaxAge_Bars     = 40;     // Âge max OB
input double   OB_BodyRatio       = 0.35;   // Ratio corps/range (très relâché)
input double   SL_BufferPoints    = 25.0;   // Distance minimale SL (le code prendra le max avec le Stops Level du broker)
input double   EMA200_BiasBuffer  = 0.0035;
input double   EMA200_NeutralBuf  = 0.0085;

input group "══ TAKE PROFIT ══"
input double   TP1_RR             = 2.5;
input double   TP2_RR             = 3.8;
input double   TP2_ClosePercent   = 55.0;
input bool     EnableTP2          = true;

input group "══ BREAKEVEN & TRAILING ══"
input bool     EnableBreakeven    = true;
input double   BE_RR              = 0.9;
input bool     EnableTrailing     = true;
input double   Trail_StartRR      = 1.2;
input double   Trail_ATR_Multi    = 0.60;

input group "══ SESSION & NEWS FILTER ══"
input int      SessionStartGMT    = 6;
input int      SessionEndGMT      = 17;
input int      NewsBufferMin      = 25;
input bool     EnableNewsFilter   = true;
input int      SpreadMaxPoints    = 55;
input bool     EnableMaxSpread    = true;

input group "══ NOTIFICATIONS ══"
input bool     EnablePush         = true;
input bool     EnableEmail        = false;
input bool     EnableAlert        = true;
input int      LogLevel           = 2;

input group "══ ADVANCED ══"
input ulong    MagicNumber        = 20260103;

//+------------------------------------------------------------------+
//|                    VARIABLES GLOBALES                             |
//+------------------------------------------------------------------+

CTrade         Trade;
CSymbolInfo    SymInfo;
CAccountInfo   Account;

int   hEMA200_D1  = INVALID_HANDLE;
int   hATR_H4     = INVALID_HANDLE;

double   g_StartBalance      = 0.0;
double   g_DailyStartBalance = 0.0;
int      g_DailyTradeCount   = 0;
datetime g_LastDayChecked    = 0;
bool     g_DailyLossHit      = false;
bool     g_DDPauseActive     = false;
datetime g_DDPauseUntil      = 0;

datetime g_LastBarTime = 0;

SActiveTrade g_Trade;

SBias        g_Bias;
SOrderBlock  g_OB;

const string EA_NAME    = "GoldLiquidityHunter_PRO v3.5";
const string EA_VERSION = "3.5 AutoSL + Bias + OB";

//+------------------------------------------------------------------+
//|                           OnInit                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0 && StringFind(_Symbol, "NAS") < 0 && StringFind(_Symbol, "US30") < 0)
   {
      Alert(EA_NAME + " | ERREUR: Optimisé pour XAUUSD ou NAS100/US30");
      return INIT_FAILED;
   }

   hEMA200_D1 = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   hATR_H4    = iATR(_Symbol, PERIOD_H4, ATR_Period);

   if(hEMA200_D1 == INVALID_HANDLE || hATR_H4 == INVALID_HANDLE)
   {
      Alert(EA_NAME + " | ERREUR: Handles indicateurs");
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);

   SymInfo.Name(_Symbol);
   SymInfo.RefreshRates();

   g_StartBalance      = Account.Balance();
   g_DailyStartBalance = Account.Balance();
   g_LastDayChecked    = TimeCurrent();

   ResetActiveTrade();
   CheckExistingPosition();

   LogMsg(1, "══════════════════════════════════════════════════════");
   LogMsg(1, EA_NAME + " | " + EA_VERSION + " | Initialisé avec succès");
   LogMsg(1, "Symbole: " + _Symbol + " | TF: " + EnumToString(_Period));
   LogMsg(1, "Mode: Biais Daily EMA200 + Order Block seulement");
   LogMsg(1, "Balance: " + DoubleToString(g_StartBalance, 2) + " | Risk: " + DoubleToString(RiskPercent, 2) + "%");
   LogMsg(1, "══════════════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|                          OnDeinit                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hEMA200_D1 != INVALID_HANDLE) IndicatorRelease(hEMA200_D1);
   if(hATR_H4    != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   Comment("");
   LogMsg(1, EA_NAME + " | Désactivé | Raison: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//|                           OnTick                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime != g_LastBarTime)
   {
      g_LastBarTime = currentBarTime;
      OnNewBar();
   }

   if(g_Trade.isOpen)
      ManageOpenTrade();

   UpdateComment();
}

//+------------------------------------------------------------------+
//|         OnNewBar – Version Simplifiée (Biais + OB)               |
//+------------------------------------------------------------------+
void OnNewBar()
{
   LogMsg(3, "──────── NOUVELLE BOUGIE: " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " ────────");

   CheckDailyReset();

   if(!RunSafetyChecks()) return;

   if(g_Trade.isOpen)
   {
      LogMsg(3, "Trade actif → analyse ignorée");
      return;
   }

   // === ÉTAPE 1 : BIAIS DAILY EMA200 ===
   g_Bias = CalculateBias();
   LogMsg(3, "Biais D1: " + g_Bias.label);

   if(!g_Bias.valid)
   {
      LogMsg(3, "Biais neutre ou invalide → aucun trade");
      return;
   }

   // === ÉTAPE 2 : ORDER BLOCK (seul filtre technique) ===
   g_OB = DetectOrderBlock();
   LogMsg(3, "Order Block: " + (g_OB.valid ? "✓ OUI" : "✗ NON"));

   if(!g_OB.valid)
   {
      LogMsg(3, "Aucun Order Block frais → ignoré");
      return;
   }

   // === FILTRES SESSION / NEWS / SPREAD ===
   if(!CheckTradeFilters()) return;

   // === LIMITE JOURNALIÈRE ===
   if(g_DailyTradeCount >= MaxTradesPerDay)
   {
      LogMsg(2, "Limite journalière atteinte");
      return;
   }

   // === OUVERTURE DU TRADE ===
   OpenTradeSimple();
}

//+------------------------------------------------------------------+
//|       CalculateBias – Biais directionnel Daily EMA200            |
//+------------------------------------------------------------------+
SBias CalculateBias()
{
   SBias bias;
   bias.valid     = false;
   bias.direction = 0;
   bias.ema200    = 0.0;
   bias.closeD1   = 0.0;
   bias.label     = "NEUTRE";

   double emaArr[];
   ArraySetAsSeries(emaArr, true);
   if(CopyBuffer(hEMA200_D1, 0, 1, 3, emaArr) < 3) return bias;

   double closeArr[];
   ArraySetAsSeries(closeArr, true);
   if(CopyClose(_Symbol, PERIOD_D1, 1, 2, closeArr) < 2) return bias;

   bias.ema200  = emaArr[0];
   bias.closeD1 = closeArr[0];

   if(bias.ema200 <= 0.0) return bias;

   double neutralThresh = bias.ema200 * EMA200_NeutralBuf;
   double dist = bias.closeD1 - bias.ema200;

   if(MathAbs(dist) < neutralThresh)
   {
      bias.label = "NEUTRE";
      return bias;
   }

   if(dist > 0)
   {
      bias.direction = 1;
      bias.valid     = true;
      bias.label     = "LONG (+ " + DoubleToString(dist / bias.ema200 * 100.0, 2) + "%)";
   }
   else
   {
      bias.direction = -1;
      bias.valid     = true;
      bias.label     = "SHORT (- " + DoubleToString(MathAbs(dist) / bias.ema200 * 100.0, 2) + "%)";
   }

   return bias;
}

//+------------------------------------------------------------------+
//|         DetectOrderBlock – Version Simplifiée                    |
//+------------------------------------------------------------------+
SOrderBlock DetectOrderBlock()
{
   SOrderBlock ob;
   ob.valid      = false;
   ob.bullish    = false;
   ob.obHigh     = 0.0;
   ob.obLow      = 0.0;
   ob.obEntryHigh= 0.0;
   ob.obEntryLow = 0.0;
   ob.barIndex   = -1;
   ob.obTime     = 0;

   int scanSize = OB_MaxAge_Bars + 5;

   double o[], h[], l[], c[];
   datetime t[];

   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
   ArraySetAsSeries(t, true);

   if(CopyOpen(  _Symbol, _Period, 1, scanSize, o) < scanSize) return ob;
   if(CopyHigh(  _Symbol, _Period, 1, scanSize, h) < scanSize) return ob;
   if(CopyLow(   _Symbol, _Period, 1, scanSize, l) < scanSize) return ob;
   if(CopyClose( _Symbol, _Period, 1, scanSize, c) < scanSize) return ob;
   if(CopyTime(  _Symbol, _Period, 1, scanSize, t) < scanSize) return ob;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 1; i < OB_MaxAge_Bars && i < scanSize - 2; i++)
   {
      double range_i = h[i] - l[i];
      if(range_i <= 0.0) continue;

      double body_i    = MathAbs(c[i] - o[i]);
      bool   bearish_i = (c[i] < o[i]);
      bool   bullish_i = (c[i] > o[i]);

      // ORDER BLOCK HAUSSIER (pour biais LONG)
      if(g_Bias.direction == 1 && bearish_i && (body_i / range_i) >= OB_BodyRatio)
      {
         bool conf = (i >= 1) && (c[i - 1] > o[i - 1]);

         if(conf)
         {
            double entryLow  = l[i];
            double entryHigh = l[i] + 0.45 * body_i;

            if(bid >= entryLow * 0.999 && bid <= h[i] * 1.001)
            {
               ob.valid       = true;
               ob.bullish     = true;
               ob.obLow       = l[i];
               ob.obHigh      = h[i];
               ob.obEntryLow  = entryLow;
               ob.obEntryHigh = entryHigh;
               ob.barIndex    = i;
               ob.obTime      = t[i];
               return ob;
            }
         }
      }

      // ORDER BLOCK BAISSIER (pour biais SHORT)
      if(g_Bias.direction == -1 && bullish_i && (body_i / range_i) >= OB_BodyRatio)
      {
         bool conf = (i >= 1) && (c[i - 1] < o[i - 1]);

         if(conf)
         {
            double entryHigh = h[i];
            double entryLow  = h[i] - 0.45 * body_i;

            if(ask >= l[i] * 0.999 && ask <= entryHigh * 1.0005)
            {
               ob.valid       = true;
               ob.bullish     = false;
               ob.obLow       = l[i];
               ob.obHigh      = h[i];
               ob.obEntryHigh = entryHigh;
               ob.obEntryLow  = entryLow;
               ob.barIndex    = i;
               ob.obTime      = t[i];
               return ob;
            }
         }
      }
   }

   return ob;
}

//+------------------------------------------------------------------+
//|                OpenTradeSimple – Ouverture simplifiée            |
//+------------------------------------------------------------------+
void OpenTradeSimple()
{
   ResetActiveTrade();

   SymInfo.RefreshRates();
   double ask   = SymInfo.Ask();
   double bid   = SymInfo.Bid();
   double point = _Point;

   bool result = false;
   string comment = EA_NAME + " v3.4 Simple";

   if(g_Bias.direction == 1 && g_OB.bullish)
   {
      double entryPrice = ask;

      // Calcul automatique de la distance minimale SL (Stops Level du broker)
      int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_stop_dist = (stops_level + 5) * point;   // +5 points de sécurité
      double buffer_dist  = SL_BufferPoints * point;

      double sl_distance = MathMax(buffer_dist, min_stop_dist);
      double slPx = NormalizeDouble(g_OB.obLow - sl_distance, _Digits);
      double slDist = entryPrice - slPx;

      if(slDist < 8 * point) return;

      double tp1Px = NormalizeDouble(entryPrice + slDist * TP1_RR, _Digits);
      double tp2Px = NormalizeDouble(entryPrice + slDist * TP2_RR, _Digits);

      double lot = CalculateLotSize(slDist);
      if(lot <= 0.0) return;

      result = Trade.Buy(lot, _Symbol, 0.0, slPx, tp1Px, comment);

      if(result)
      {
         ulong ticket = Trade.ResultOrder();
         g_Trade.isOpen     = true;
         g_Trade.ticket     = ticket;
         g_Trade.direction  = 1;
         g_Trade.entryPrice = Trade.ResultPrice();
         g_Trade.sl         = slPx;
         g_Trade.tp1        = tp1Px;
         g_Trade.tp2        = tp2Px;
         g_Trade.riskAmount = Account.Balance() * RiskPercent / 100.0;
         g_Trade.openTime   = TimeCurrent();

         g_DailyTradeCount++;

         string notif = "🟢 BUY | " + _Symbol + " | Lot: " + DoubleToString(lot, 2) +
                        " | Entry: " + DoubleToString(g_Trade.entryPrice, 2) +
                        " | SL: " + DoubleToString(slPx, 2) + " | TP1: " + DoubleToString(tp1Px, 2);

         LogMsg(1, notif);
         if(EnableAlert) Alert(EA_NAME + "\n" + notif);
      }
   }
   else if(g_Bias.direction == -1 && !g_OB.bullish)
   {
      double entryPrice = bid;

      // Calcul automatique de la distance minimale SL (Stops Level du broker)
      int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double min_stop_dist = (stops_level + 5) * point;   // +5 points de sécurité
      double buffer_dist  = SL_BufferPoints * point;

      double sl_distance = MathMax(buffer_dist, min_stop_dist);
      double slPx = NormalizeDouble(g_OB.obHigh + sl_distance, _Digits);
      double slDist = slPx - entryPrice;

      if(slDist < 8 * point) return;

      double tp1Px = NormalizeDouble(entryPrice - slDist * TP1_RR, _Digits);
      double tp2Px = NormalizeDouble(entryPrice - slDist * TP2_RR, _Digits);

      double lot = CalculateLotSize(slDist);
      if(lot <= 0.0) return;

      result = Trade.Sell(lot, _Symbol, 0.0, slPx, tp1Px, comment);

      if(result)
      {
         ulong ticket = Trade.ResultOrder();
         g_Trade.isOpen     = true;
         g_Trade.ticket     = ticket;
         g_Trade.direction  = -1;
         g_Trade.entryPrice = Trade.ResultPrice();
         g_Trade.sl         = slPx;
         g_Trade.tp1        = tp1Px;
         g_Trade.tp2        = tp2Px;
         g_Trade.riskAmount = Account.Balance() * RiskPercent / 100.0;
         g_Trade.openTime   = TimeCurrent();

         g_DailyTradeCount++;

         string notif = "🔴 SELL | " + _Symbol + " | Lot: " + DoubleToString(lot, 2) +
                        " | Entry: " + DoubleToString(g_Trade.entryPrice, 2) +
                        " | SL: " + DoubleToString(slPx, 2) + " | TP1: " + DoubleToString(tp1Px, 2);

         LogMsg(1, notif);
         if(EnableAlert) Alert(EA_NAME + "\n" + notif);
      }
   }
}

//+------------------------------------------------------------------+
//|   ManageOpenTrade – Breakeven / TP2 / Trailing (identique)      |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!g_Trade.isOpen) return;

   if(!PositionSelectByTicket(g_Trade.ticket))
   {
      OnTradeClose();
      return;
   }

   double posSL    = PositionGetDouble(POSITION_SL);
   double posVol   = PositionGetDouble(POSITION_VOLUME);
   double entry    = g_Trade.entryPrice;
   double slDist   = MathAbs(entry - g_Trade.sl);
   if(slDist <= 0.0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentPx = (g_Trade.direction == 1) ? bid : ask;
   double currentR  = (g_Trade.direction == 1) ? (currentPx - entry) / slDist : (entry - currentPx) / slDist;

   double atr = GetATR();

   // TP2 PARTIEL
   if(EnableTP2 && !g_Trade.tp2Hit)
   {
      bool tp2Hit = (g_Trade.direction == 1) ? (bid >= g_Trade.tp2) : (ask <= g_Trade.tp2);

      if(tp2Hit)
      {
         double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double closeVol= MathFloor((posVol * TP2_ClosePercent / 100.0) / lotStep) * lotStep;
         closeVol = MathMax(closeVol, minLot);

         if(closeVol < posVol && closeVol >= minLot)
         {
            if(Trade.PositionClosePartial(_Symbol, closeVol))
            {
               g_Trade.tp2Hit = true;
               LogMsg(1, "🎯 TP2 PARTIEL " + DoubleToString(TP2_ClosePercent, 0) + "% fermé");
            }
         }
      }
   }

   // BREAKEVEN
   if(EnableBreakeven && !g_Trade.beActivated && currentR >= BE_RR)
   {
      double newSL = (g_Trade.direction == 1) ? NormalizeDouble(entry + 2.0 * _Point, _Digits) :
                     NormalizeDouble(entry - 2.0 * _Point, _Digits);

      bool improvement = (g_Trade.direction == 1) ? (newSL > posSL + _Point