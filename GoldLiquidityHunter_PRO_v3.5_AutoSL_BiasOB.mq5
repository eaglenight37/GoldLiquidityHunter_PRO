//+------------------------------------------------------------------+
//|     GoldLiquidityHunter_PRO v3.4 – Simple Version (Bias + OB)   |
//|          Copyright 2026, Professional Trading Systems            |
//|           XAUUSD / NAS100 – ICT/SMC Simplified Expert Advisor   |
//+------------------------------------------------------------------+
/*
╔══════════════════════════════════════════════════════════════════════╗
║           USER MANUAL – GoldLiquidityHunter_PRO v3.53                ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  VERSION SIMPLIFIÉE : Biais Daily EMA200 + Order Block seulement   ║
║  (Sweep et Displacement désactivés par défaut pour plus de trades)  ║
║                                                                      ║
║  MEILLEURE CONFIGURATION :                                           ║
║  - Paire     : XAUUSD (H4) ou NAS100 (H1)                           ║
║  - Graphique : n'importe quel TF (M1, M15…) — l'analyse OB/ATR suit SignalTF ║
║  - SignalTF  : H4 (or) ou H1 (NAS) — réglage input, pas le TF du graphique   ║
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
#property version     "3.53"
#property description "GoldLiquidityHunter v3.53 — SL auto broker + OB sur SignalTF (graphique libre)"
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
input ENUM_TIMEFRAMES SignalTF      = PERIOD_H4;  // TF analyse OB / barres / ATR (indépendant du graphique)
input int      ATR_Period         = 14;
input int      OB_MaxAge_Bars     = 40;     // Âge max OB
input double   OB_BodyRatio       = 0.35;   // Ratio corps/range (très relâché)
input double   SL_BufferPoints    = 25.0;   // Distance minimale SL (le code prendra le max avec le Stops Level du broker)
input double   EMA200_BiasBuffer  = 0.0035;   // Ratio |close-EMA|/EMA (zone avec NeutralBuf, voir CalculateBias)
input double   EMA200_NeutralBuf  = 0.0085;   // Ratio — zone morte si max(Bias,Neutral) utilisé

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
input bool     StrictSymbolWhitelist = true;  // false = autoriser tout symbole (risque hors périmètre)
input ulong    MagicNumber        = 20260103;

//+------------------------------------------------------------------+
//|                    VARIABLES GLOBALES                             |
//+------------------------------------------------------------------+

CTrade         Trade;
CSymbolInfo    SymInfo;
CAccountInfo   Account;

int   hEMA200_D1  = INVALID_HANDLE;
int   hATR_Signal = INVALID_HANDLE;   // ATR sur SignalTF (aligné OB / signaux)

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
const string EA_VERSION = "3.53 AutoSL + Bias + OB";

//+------------------------------------------------------------------+
//| Helpers — point / stops broker, symbole, filling                  |
//+------------------------------------------------------------------+
double BrokerPoint()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0)
      p = _Point;
   return p;
}

int BrokerStopOrFreezePoints()
{
   const int sl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int fr = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(sl, fr);
}

bool SymbolIsAllowed()
{
   if(!StrictSymbolWhitelist)
      return true;
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0 ||
           StringFind(s, "NAS") >= 0 || StringFind(s, "US30") >= 0 ||
           StringFind(s, "US100") >= 0 || StringFind(s, "NDX") >= 0 ||
           StringFind(s, "USTEC") >= 0);
}

void SetupTradeFillingMode()
{
   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      Trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//|                           OnInit                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolIsAllowed())
   {
      Alert(EA_NAME + " | ERREUR: Symbole non reconnu (XAU/GOLD/NAS/US30…) ou désactivez StrictSymbolWhitelist");
      return INIT_FAILED;
   }

   hEMA200_D1 = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   hATR_Signal = iATR(_Symbol, SignalTF, ATR_Period);

   if(hEMA200_D1 == INVALID_HANDLE || hATR_Signal == INVALID_HANDLE)
   {
      Alert(EA_NAME + " | ERREUR: Handles indicateurs");
      return INIT_FAILED;
   }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(20);
   SetupTradeFillingMode();

   SymInfo.Name(_Symbol);
   SymInfo.RefreshRates();

   g_StartBalance      = Account.Balance();
   g_DailyStartBalance = Account.Balance();
   g_LastDayChecked    = TimeCurrent();

   ResetActiveTrade();
   CheckExistingPosition();

   LogMsg(1, "══════════════════════════════════════════════════════");
   LogMsg(1, EA_NAME + " | " + EA_VERSION + " | Initialisé avec succès");
   LogMsg(1, "Symbole: " + _Symbol + " | Graph: " + EnumToString(_Period) + " | SignalTF: " + EnumToString(SignalTF));
   LogMsg(1, "Mode: Biais Daily EMA200 + Order Block sur SignalTF (SL auto stops/freeze broker)");
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
   if(hATR_Signal != INVALID_HANDLE) IndicatorRelease(hATR_Signal);
   Comment("");
   LogMsg(1, EA_NAME + " | Désactivé | Raison: " + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//|                           OnTick                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBarTime = iTime(_Symbol, SignalTF, 0);
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

   const double deadRatio = MathMax(EMA200_NeutralBuf, EMA200_BiasBuffer);
   const double neutralThresh = bias.ema200 * deadRatio;
   const double dist = bias.closeD1 - bias.ema200;

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

   if(CopyOpen(  _Symbol, SignalTF, 1, scanSize, o) < scanSize) return ob;
   if(CopyHigh(  _Symbol, SignalTF, 1, scanSize, h) < scanSize) return ob;
   if(CopyLow(   _Symbol, SignalTF, 1, scanSize, l) < scanSize) return ob;
   if(CopyClose( _Symbol, SignalTF, 1, scanSize, c) < scanSize) return ob;
   if(CopyTime(  _Symbol, SignalTF, 1, scanSize, t) < scanSize) return ob;

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
//| Ticket position (API MQL5) + résolution après ordre marché     |
//+------------------------------------------------------------------+
ulong GetOurNewestPositionTicket()
{
   ulong bestTicket = 0;
   datetime bestTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(tm >= bestTime)
      {
         bestTime = tm;
         bestTicket = ticket;
      }
   }
   return bestTicket;
}

//+------------------------------------------------------------------+
ulong PositionTicketFromLastDeal()
{
   const ulong deal = Trade.ResultDeal();
   if(deal == 0)
      return 0;
   if(!HistoryDealSelect(deal))
      return 0;
   return (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
}

//+------------------------------------------------------------------+
ulong ResolveOpenedPositionTicket()
{
   ulong t = GetOurNewestPositionTicket();
   if(t > 0)
      return t;
   t = PositionTicketFromLastDeal();
   return t;
}

//+------------------------------------------------------------------+
//|                OpenTradeSimple – Ouverture simplifiée            |
//+------------------------------------------------------------------+
void OpenTradeSimple()
{
   ResetActiveTrade();

   SymInfo.RefreshRates();
   const double ask   = SymInfo.Ask();
   const double bid   = SymInfo.Bid();
   const double point = BrokerPoint();
   const int    regPts = BrokerStopOrFreezePoints();

   bool   result  = false;
   string comment = EA_NAME + " v3.53";

   if(g_Bias.direction == 1 && g_OB.bullish)
   {
      const double entryPrice = ask;

      const double min_stop_dist = (regPts + 5) * point;
      const double buffer_dist   = SL_BufferPoints * point;

      const double sl_distance = MathMax(buffer_dist, min_stop_dist);
      const double slPx = NormalizeDouble(g_OB.obLow - sl_distance, _Digits);
      const double slDist = entryPrice - slPx;

      if(slDist < 8 * point) return;

      const double tp1Px = NormalizeDouble(entryPrice + slDist * TP1_RR, _Digits);
      const double tp2Px = NormalizeDouble(entryPrice + slDist * TP2_RR, _Digits);

      const double lot = CalculateLotSize(slDist);
      if(lot <= 0.0) return;

      result = Trade.Buy(lot, _Symbol, 0.0, slPx, tp1Px, comment);

      if(result)
      {
         g_Trade.isOpen     = true;
         g_Trade.ticket     = ResolveOpenedPositionTicket();
         if(g_Trade.ticket == 0)
            LogMsg(2, "BUY exécuté mais aucun ticket position résolu — gestion trade peut échouer");
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
      else
         LogMsg(2, "BUY refusé | retcode=" + IntegerToString(Trade.ResultRetcode()) + " " + Trade.ResultRetcodeDescription());
   }
   else if(g_Bias.direction == -1 && !g_OB.bullish)
   {
      const double entryPrice = bid;

      const double min_stop_dist = (regPts + 5) * point;
      const double buffer_dist   = SL_BufferPoints * point;

      const double sl_distance = MathMax(buffer_dist, min_stop_dist);
      const double slPx = NormalizeDouble(g_OB.obHigh + sl_distance, _Digits);
      const double slDist = slPx - entryPrice;

      if(slDist < 8 * point) return;

      const double tp1Px = NormalizeDouble(entryPrice - slDist * TP1_RR, _Digits);
      const double tp2Px = NormalizeDouble(entryPrice - slDist * TP2_RR, _Digits);

      const double lot = CalculateLotSize(slDist);
      if(lot <= 0.0) return;

      result = Trade.Sell(lot, _Symbol, 0.0, slPx, tp1Px, comment);

      if(result)
      {
         g_Trade.isOpen     = true;
         g_Trade.ticket     = ResolveOpenedPositionTicket();
         if(g_Trade.ticket == 0)
            LogMsg(2, "SELL exécuté mais aucun ticket position résolu — gestion trade peut échouer");
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
      else
         LogMsg(2, "SELL refusé | retcode=" + IntegerToString(Trade.ResultRetcode()) + " " + Trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|   ManageOpenTrade – Breakeven / TP2 / Trailing (identique)      |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!g_Trade.isOpen) return;

   const double pt = BrokerPoint();

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
      double newSL = (g_Trade.direction == 1) ? NormalizeDouble(entry + 2.0 * pt, _Digits) :
                     NormalizeDouble(entry - 2.0 * pt, _Digits);

      bool improvement = (g_Trade.direction == 1) ? (newSL > posSL + pt) : (newSL < posSL - pt);

      if(improvement)
      {
         if(Trade.PositionModify(_Symbol, newSL, g_Trade.tp1))
         {
            g_Trade.beActivated = true;
            g_Trade.sl = newSL;
            LogMsg(2, "🔒 BREAKEVEN activé");
         }
      }
   }

   // TRAILING
   if(EnableTrailing && currentR >= Trail_StartRR && atr > 0.0)
   {
      double trailDist = Trail_ATR_Multi * atr;
      double trailSL;

      if(g_Trade.direction == 1)
      {
         trailSL = NormalizeDouble(bid - trailDist, _Digits);
         if(trailSL > posSL + pt)
         {
            if(Trade.PositionModify(_Symbol, trailSL, g_Trade.tp1))
            {
               g_Trade.trailActivated = true;
               g_Trade.sl = trailSL;
            }
         }
      }
      else
      {
         trailSL = NormalizeDouble(ask + trailDist, _Digits);
         if(trailSL < posSL - pt)
         {
            if(Trade.PositionModify(_Symbol, trailSL, g_Trade.tp1))
            {
               g_Trade.trailActivated = true;
               g_Trade.sl = trailSL;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//|          CalculateLotSize (identique)                            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePx)
{
   if(slDistancePx <= 0.0) return 0.0;

   double balance    = Account.Balance();
   double riskAmount = balance * (RiskPercent / 100.0);
   const double symPt = BrokerPoint();
   double slPoints   = slDistancePx / symPt;

   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0) return 0.0;

   double valuePerPt = (tickVal / tickSize) * symPt;
   double rawLot     = riskAmount / (slPoints * valuePerPt);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = MathFloor(rawLot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//+------------------------------------------------------------------+
//|      CheckTradeFilters (simplifié)                               |
//+------------------------------------------------------------------+
bool CheckTradeFilters()
{
   if(!IsInSession()) return false;

   if(EnableNewsFilter && IsNewsTime()) return false;

   if(EnableMaxSpread)
   {
      long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spreadPts > SpreadMaxPoints) return false;
   }

   return true;
}

bool IsInSession()
{
   datetime gmtNow = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmtNow, dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;

   int nowMins   = dt.hour * 60 + dt.min;
   int startMins = SessionStartGMT * 60;
   int endMins   = SessionEndGMT   * 60;

   return (nowMins >= startMins && nowMins < endMins);
}

bool IsNewsTime()
{
   datetime gmtNow = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(gmtNow, dt);

   int nowMins = dt.hour * 60 + dt.min;

   // Zone fixe 13:20–14:40 GMT (NFP + news)
   if(nowMins >= 800 && nowMins < 880) return true;

   return false;
}

//+------------------------------------------------------------------+
//|        RunSafetyChecks (identique)                               |
//+------------------------------------------------------------------+
bool RunSafetyChecks()
{
   if(g_DDPauseActive)
   {
      if(TimeCurrent() < g_DDPauseUntil) return false;
      g_DDPauseActive = false;
   }

   if(EnableDD_Pause && g_StartBalance > 0.0)
   {
      double ddPct = (g_StartBalance - Account.Balance()) / g_StartBalance * 100.0;
      if(ddPct >= MaxDrawdownPct)
      {
         g_DDPauseActive = true;
         g_DDPauseUntil  = TimeCurrent() + 48 * 3600;
         return false;
      }
   }

   if(g_DailyLossHit) return false;

   if(g_DailyStartBalance > 0.0)
   {
      double dlPct = (g_DailyStartBalance - Account.Balance()) / g_DailyStartBalance * 100.0;
      if(dlPct >= MaxDailyLossPct)
      {
         g_DailyLossHit = true;
         return false;
      }
   }

   return true;
}

void CheckDailyReset()
{
   MqlDateTime nowDt, lastDt;
   TimeToStruct(TimeCurrent(), nowDt);
   TimeToStruct(g_LastDayChecked, lastDt);

   if(nowDt.day != lastDt.day)
   {
      g_DailyStartBalance = Account.Balance();
      g_DailyTradeCount   = 0;
      g_DailyLossHit      = false;
      g_LastDayChecked    = TimeCurrent();
   }
}

void OnTradeClose()
{
   ResetActiveTrade();
}

void CheckExistingPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      g_Trade.isOpen     = true;
      g_Trade.ticket     = ticket;
      g_Trade.direction  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_Trade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_Trade.sl         = PositionGetDouble(POSITION_SL);
      g_Trade.tp1        = PositionGetDouble(POSITION_TP);
      g_Trade.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
      break;
   }
}

void ResetActiveTrade()
{
   g_Trade.isOpen     = false;
   g_Trade.ticket     = 0;
   g_Trade.direction  = 0;
   g_Trade.entryPrice = 0.0;
   g_Trade.sl         = 0.0;
   g_Trade.tp1        = 0.0;
   g_Trade.tp2        = 0.0;
   g_Trade.riskAmount = 0.0;
   g_Trade.tp2Hit     = false;
   g_Trade.beActivated= false;
   g_Trade.trailActivated = false;
   g_Trade.openTime   = 0;
}

double GetATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR_Signal, 0, 1, 3, buf) < 3) return 0.0;
   return buf[0];
}

void LogMsg(const int level, const string msg)
{
   if(level > LogLevel) return;

   string prefix;
   switch(level)
   {
      case 1: prefix = "[INFO]  "; break;
      case 2: prefix = "[WARN]  "; break;
      case 3: prefix = "[DEBUG] "; break;
      default: prefix = "[LOG]   "; break;
   }
   Print(EA_NAME + " | " + prefix + msg);
}

void UpdateComment()
{
   double bal    = Account.Balance();
   double dd     = (g_StartBalance > 0.0) ? MathMax((g_StartBalance - bal) / g_StartBalance * 100.0, 0.0) : 0.0;

   string tradeInfo;
   if(!g_Trade.isOpen)
      tradeInfo = "⬜ AUCUN TRADE ACTIF";
   else
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      const double px = (g_Trade.direction == 1) ? bid : ask;
      const double rDist = MathAbs(g_Trade.entryPrice - g_Trade.sl);
      double rVal = 0.0;
      if(rDist > 0.0)
         rVal = (g_Trade.direction == 1) ? (px - g_Trade.entryPrice) / rDist : (g_Trade.entryPrice - px) / rDist;

      tradeInfo = (g_Trade.direction == 1 ? "🟢 BUY" : "🔴 SELL") + " #" + IntegerToString(g_Trade.ticket) + "\n" +
                  "Entry: " + DoubleToString(g_Trade.entryPrice, 2) + " | SL: " + DoubleToString(g_Trade.sl, 2) + "\n" +
                  "R: " + DoubleToString(rVal, 2);
   }

   string c = "";
   c += "╔══ " + EA_NAME + " v3.53 ══╗\n";
   c += "Balance: " + DoubleToString(bal, 2) + " | DD: " + DoubleToString(dd, 2) + "%\n";
   c += "Trades/jour: " + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(MaxTradesPerDay) + "\n";
   c += "Biais: " + g_Bias.label + "\n";
   c += "──────────────────────────────────\n";
   c += tradeInfo + "\n";
   c += "╚══════════════════════════════════╝";

   Comment(c);
}
//+------------------------------------------------------------------+
//|                    FIN DU CODE – v3.53                           |
//+------------------------------------------------------------------+
