//+------------------------------------------------------------------+
//|                           GoldSwingInstitutionalSemiAuto.mq5      |
//|   XAUUSD H4 — swing institutionnel, semi-auto (validation panel)  |
//|   Copyright 2026, Professional Trading Systems                    |
//+------------------------------------------------------------------+
#property copyright "Professional Trading Systems 2026"
#property link      "https://github.com/"
#property version   "1.00"
#property description "XAU H4/D1 biais + S/R dynamiques + RR 1:3 + risque % + trailing BE puis ATR loose"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- inputs
input group "══ RISK / EXECUTION ══"
input double   RiskPercent         = 0.5;     // Risque par trade (% balance)
input ulong      MagicNumber       = 987654;  // Magic number
input bool       StrictGoldSymbol  = true;    // Symbole or (XAU/GOLD) uniquement

input group "══ SETUP (H4 + D1) ══"
input double   RR_Target           = 3.0;     // Objectif RR minimum (1:3)
input double   ATR_Multi_SL        = 1.5;     // SL sous/au-dessus niveau ± ATR×
input double   NearLevel_ATR_Ratio = 0.8;     // Proximité support/résistance vs ATR
input int      SwingLookback       = 45;      // Barres pour pivots swing
input int      SwingLeftRight      = 2;       // Fenêtre fractale (2 = 5-bar pivot)

input group "══ TRAILING INSTITUTIONNEL ══"
input double   Trail_Start_R       = 1.0;     // À partir de ce gain (en R) → BE + buffer
input double   BE_ProfitPoints       = 15.0;  // Au-delà du prix d'entrée (points) pour verrouiller un mini gain
input double   Trail_ActivateExtraR = 0.5;   // Trailing ATR après (Trail_Start_R + ce R) ex. 1+0.5=1.5R
input double   Trail_ATR_Multi       = 2.0;   // Distance loose = ATR(H4)×
input double   Trail_SwingBufferPts  = 20.0;  // SL long ne descend pas sous dernier swing low − buffer (pts)

input group "══ NOTIFICATIONS ══"
input bool     UsePushAlerts       = true;

//--- chart / UI
const string   OBJ_PREFIX          = "GSISA_";
const string   BTN_LONG            = "GSISA_BtnLong";
const string   BTN_SHORT           = "GSISA_BtnShort";
const string   BTN_CANCEL          = "GSISA_BtnCancel";
const string   HLINE_SUP           = "GSISA_Support";
const string   HLINE_RES           = "GSISA_Resistance";
const string   LABEL_INFO          = "GSISA_Info";

CTrade         Trade;
CSymbolInfo    SymInfo;
CAccountInfo   Account;

int    hEMA50_H4   = INVALID_HANDLE;
int    hEMA200_H4  = INVALID_HANDLE;
int    hEMA200_D1  = INVALID_HANDLE;
int    hRSI_H4     = INVALID_HANDLE;
int    hATR_H4     = INVALID_HANDLE;

datetime g_lastBarH4 = 0;
double   g_support   = 0.0;
double   g_resist    = 0.0;

bool           g_signalActive = false;
ENUM_ORDER_TYPE g_signalType  = ORDER_TYPE_BUY;
double         g_sigSL        = 0.0;
double         g_sigTP        = 0.0;

//+------------------------------------------------------------------+
double BrokerPoint()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0) p = _Point;
   return p;
}

int BrokerStopOrFreezePoints()
{
   const int sl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int fr = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(sl, fr);
}

bool SymbolIsGold()
{
   if(!StrictGoldSymbol) return true;
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0);
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

void DeleteObjectsByPrefix()
{
   const int n = ObjectsTotal(0, 0, OBJ_ALL_TYPES);
   for(int i = n - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_ALL_TYPES);
      if(StringFind(name, OBJ_PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

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
bool FindSwingLowHigh(double &outLow, double &outHigh)
{
   outLow  = 0.0;
   outHigh = 0.0;
   const int L = SwingLeftRight;
   const int need = SwingLookback + L + 2;
   double low[], high[];
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(high, true);
   if(CopyLow(_Symbol, PERIOD_H4, 0, need, low) < need) return false;
   if(CopyHigh(_Symbol, PERIOD_H4, 0, need, high) < need) return false;

   for(int i = L; i < SwingLookback; i++)
   {
      bool isLow = true;
      for(int k = 1; k <= L; k++)
      {
         if(low[i] >= low[i - k] || low[i] >= low[i + k]) { isLow = false; break; }
      }
      if(isLow) { outLow = low[i]; break; }
   }
   for(int i = L; i < SwingLookback; i++)
   {
      bool isHigh = true;
      for(int k = 1; k <= L; k++)
      {
         if(high[i] <= high[i - k] || high[i] <= high[i + k]) { isHigh = false; break; }
      }
      if(isHigh) { outHigh = high[i]; break; }
   }
   return (outLow > 0.0 || outHigh > 0.0);
}

void DrawLevels()
{
   ObjectDelete(0, HLINE_SUP);
   ObjectDelete(0, HLINE_RES);
   if(g_support > 0.0)
   {
      ObjectCreate(0, HLINE_SUP, OBJ_HLINE, 0, 0, g_support);
      ObjectSetInteger(0, HLINE_SUP, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, HLINE_SUP, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, HLINE_SUP, OBJPROP_WIDTH, 2);
   }
   if(g_resist > 0.0)
   {
      ObjectCreate(0, HLINE_RES, OBJ_HLINE, 0, 0, g_resist);
      ObjectSetInteger(0, HLINE_RES, OBJPROP_COLOR, clrTomato);
      ObjectSetInteger(0, HLINE_RES, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, HLINE_RES, OBJPROP_WIDTH, 2);
   }
}

//+------------------------------------------------------------------+
double LastSwingLowForTrail()
{
   const int L = SwingLeftRight;
   const int need = 80;
   double low[];
   ArraySetAsSeries(low, true);
   if(CopyLow(_Symbol, PERIOD_H4, 0, need, low) < need) return 0.0;
   for(int i = L; i < need - L - 1; i++)
   {
      bool isLow = true;
      for(int k = 1; k <= L; k++)
      {
         if(low[i] >= low[i - k] || low[i] >= low[i + k]) { isLow = false; break; }
      }
      if(isLow) return low[i];
   }
   return 0.0;
}

double LastSwingHighForTrail()
{
   const int L = SwingLeftRight;
   const int need = 80;
   double high[];
   ArraySetAsSeries(high, true);
   if(CopyHigh(_Symbol, PERIOD_H4, 0, need, high) < need) return 0.0;
   for(int i = L; i < need - L - 1; i++)
   {
      bool isHigh = true;
      for(int k = 1; k <= L; k++)
      {
         if(high[i] <= high[i - k] || high[i] <= high[i + k]) { isHigh = false; break; }
      }
      if(isHigh) return high[i];
   }
   return 0.0;
}

//+------------------------------------------------------------------+
string IrKey(const ulong ticket) { return "GSISA_IR_" + IntegerToString(ticket); }
string BeKey(const ulong ticket) { return "GSISA_BE_" + IntegerToString(ticket); }

void CleanupStaleGlobals()
{
   string names[];
   int n = 0;
   const int total = GlobalVariablesTotal();
   for(int i = 0; i < total; i++)
   {
      const string name = GlobalVariableName(i);
      if(StringFind(name, "GSISA_IR_") != 0 && StringFind(name, "GSISA_BE_") != 0)
         continue;
      ArrayResize(names, n + 1);
      names[n++] = name;
   }
   for(int j = 0; j < n; j++)
   {
      const ulong t = (ulong)StringToInteger(StringSubstr(names[j], 9));
      if(t == 0 || !PositionSelectByTicket(t))
         GlobalVariableDel(names[j]);
   }
}

void RegisterPositionRisk(const ulong posTicket, const double initialRiskPx)
{
   GlobalVariableSet(IrKey(posTicket), initialRiskPx);
   GlobalVariableSet(BeKey(posTicket), 0.0); // BE pas encore fait
}

double GetInitialRiskPx(const ulong posTicket, const double entry, const double sl)
{
   if(GlobalVariableCheck(IrKey(posTicket)))
      return GlobalVariableGet(IrKey(posTicket));
   return MathAbs(entry - sl);
}

bool IsBEDone(const ulong posTicket)
{
   if(!GlobalVariableCheck(BeKey(posTicket))) return false;
   return (GlobalVariableGet(BeKey(posTicket)) > 0.5);
}

void SetBEDone(const ulong posTicket)
{
   GlobalVariableSet(BeKey(posTicket), 1.0);
}

//+------------------------------------------------------------------+
bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      return true;
   }
   return false;
}

ulong FindNewestOurPositionTicket()
{
   datetime bestT = 0;
   ulong    best  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(ot >= bestT) { bestT = ot; best = ticket; }
   }
   return best;
}

//+------------------------------------------------------------------+
bool NormalizeStops(const ENUM_ORDER_TYPE type, double price, double &sl, double &tp)
{
   const double pt = BrokerPoint();
   const int    stk = BrokerStopOrFreezePoints();
   const double minDist = stk * pt;
   if(minDist <= 0.0) return true;

   if(type == ORDER_TYPE_BUY)
   {
      if(sl > 0.0 && (price - sl) < minDist) sl = price - minDist;
      if(tp > 0.0 && (tp - price) < minDist) tp = price + minDist;
   }
   else
   {
      if(sl > 0.0 && (sl - price) < minDist) sl = price + minDist;
      if(tp > 0.0 && (price - tp) < minDist) tp = price - minDist;
   }
   return true;
}

//+------------------------------------------------------------------+
void RemoveConfirmPanel()
{
   ObjectDelete(0, BTN_LONG);
   ObjectDelete(0, BTN_SHORT);
   ObjectDelete(0, BTN_CANCEL);
   ObjectDelete(0, LABEL_INFO);
   g_signalActive = false;
   g_sigSL = g_sigTP = 0.0;
}

void CreateConfirmPanel()
{
   ObjectDelete(0, BTN_LONG);
   ObjectDelete(0, BTN_SHORT);
   ObjectDelete(0, BTN_CANCEL);
   ObjectDelete(0, LABEL_INFO);

   int y = 40;
   ObjectCreate(0, BTN_LONG, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_LONG, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BTN_LONG, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, BTN_LONG, OBJPROP_XSIZE, 170);
   ObjectSetInteger(0, BTN_LONG, OBJPROP_YSIZE, 36);
   ObjectSetString(0, BTN_LONG, OBJPROP_TEXT, "VALIDER LONG 0.5%");
   ObjectSetInteger(0, BTN_LONG, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_LONG, OBJPROP_BGCOLOR, clrForestGreen);

   ObjectCreate(0, BTN_SHORT, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_XDISTANCE, 200);
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_XSIZE, 170);
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_YSIZE, 36);
   ObjectSetString(0, BTN_SHORT, OBJPROP_TEXT, "VALIDER SHORT 0.5%");
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_SHORT, OBJPROP_BGCOLOR, clrFireBrick);

   ObjectCreate(0, BTN_CANCEL, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_XDISTANCE, 380);
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_YSIZE, 36);
   ObjectSetString(0, BTN_CANCEL, OBJPROP_TEXT, "ANNULER");
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_CANCEL, OBJPROP_BGCOLOR, clrDimGray);

   string dir = (g_signalType == ORDER_TYPE_BUY) ? "LONG" : "SHORT";
   ObjectCreate(0, LABEL_INFO, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, LABEL_INFO, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, LABEL_INFO, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, LABEL_INFO, OBJPROP_YDISTANCE, y + 42);
   ObjectSetInteger(0, LABEL_INFO, OBJPROP_COLOR, clrGold);
   ObjectSetString(0, LABEL_INFO, OBJPROP_TEXT,
                   "Signal " + dir + " H4 | RR 1:" + DoubleToString(RR_Target, 1) +
                   " | SL " + DoubleToString(g_sigSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
                   " | TP " + DoubleToString(g_sigTP, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
                   " | Cliquez la direction validée (l'autre annule le panel).");
   ObjectSetInteger(0, LABEL_INFO, OBJPROP_FONTSIZE, 9);

   g_signalActive = true;
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolIsGold())
   {
      Alert("GoldSwingInstitutionalSemiAuto | Symbole non-or — désactiver StrictGoldSymbol pour tests.");
      return INIT_FAILED;
   }

   hEMA50_H4  = iMA(_Symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200_H4 = iMA(_Symbol, PERIOD_H4, 200, 0, MODE_EMA, PRICE_CLOSE);
   hEMA200_D1 = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   hRSI_H4    = iRSI(_Symbol, PERIOD_H4, 14, PRICE_CLOSE);
   hATR_H4    = iATR(_Symbol, PERIOD_H4, 14);

   if(hEMA50_H4 == INVALID_HANDLE || hEMA200_H4 == INVALID_HANDLE || hEMA200_D1 == INVALID_HANDLE ||
      hRSI_H4 == INVALID_HANDLE || hATR_H4 == INVALID_HANDLE)
   {
      Alert("GoldSwingInstitutionalSemiAuto | Erreur création indicateurs.");
      return INIT_FAILED;
   }

   SymInfo.Name(_Symbol);
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(30);
   SetupTradeFillingMode();

   Print("GoldSwingInstitutionalSemiAuto | Semi-auto | risque ", RiskPercent, "% | RR 1:", RR_Target);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA50_H4  != INVALID_HANDLE) IndicatorRelease(hEMA50_H4);
   if(hEMA200_H4 != INVALID_HANDLE) IndicatorRelease(hEMA200_H4);
   if(hEMA200_D1 != INVALID_HANDLE) IndicatorRelease(hEMA200_D1);
   if(hRSI_H4    != INVALID_HANDLE) IndicatorRelease(hRSI_H4);
   if(hATR_H4    != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   RemoveConfirmPanel();
   DeleteObjectsByPrefix();
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == BTN_LONG || sparam == BTN_SHORT || sparam == BTN_CANCEL)
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw(0);
   }

   if(!g_signalActive) return;

   if(sparam == BTN_CANCEL)
   {
      Print("GoldSwingInstitutionalSemiAuto | Signal annulé.");
      RemoveConfirmPanel();
      return;
   }

   if(sparam == BTN_LONG)
   {
      if(g_signalType != ORDER_TYPE_BUY)
      {
         Print("GoldSwingInstitutionalSemiAuto | Panel SHORT actif — LONG ignoré (annulation).");
         RemoveConfirmPanel();
         return;
      }
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = g_sigSL, tp = g_sigTP;
      NormalizeStops(ORDER_TYPE_BUY, ask, sl, tp);
      double dist = MathAbs(ask - sl);
      double lot = CalculateLotSize(dist);
      if(lot <= 0.0)
      {
         Print("GoldSwingInstitutionalSemiAuto | Lot calculé nul — vérifier SL.");
         return;
      }
      string cmt = "GSISA Swing Long";
      if(Trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt))
      {
         ulong pos = FindNewestOurPositionTicket();
         if(pos > 0) RegisterPositionRisk(pos, dist);
         if(UsePushAlerts)
            SendNotification("GoldSwingInstitutionalSemiAuto | BUY lot=" + DoubleToString(lot, 2) + " RR 1:" + DoubleToString(RR_Target, 1));
         Alert("Trade LONG ouvert | lot ", lot);
      }
      else
         Print("GoldSwingInstitutionalSemiAuto | Erreur Buy: ", Trade.ResultRetcodeDescription());
      RemoveConfirmPanel();
      return;
   }

   if(sparam == BTN_SHORT)
   {
      if(g_signalType != ORDER_TYPE_SELL)
      {
         Print("GoldSwingInstitutionalSemiAuto | Panel LONG actif — SHORT ignoré (annulation).");
         RemoveConfirmPanel();
         return;
      }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = g_sigSL, tp = g_sigTP;
      NormalizeStops(ORDER_TYPE_SELL, bid, sl, tp);
      double dist = MathAbs(bid - sl);
      double lot = CalculateLotSize(dist);
      if(lot <= 0.0)
      {
         Print("GoldSwingInstitutionalSemiAuto | Lot calculé nul — vérifier SL.");
         return;
      }
      string cmt = "GSISA Swing Short";
      if(Trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt))
      {
         ulong pos = FindNewestOurPositionTicket();
         if(pos > 0) RegisterPositionRisk(pos, dist);
         if(UsePushAlerts)
            SendNotification("GoldSwingInstitutionalSemiAuto | SELL lot=" + DoubleToString(lot, 2) + " RR 1:" + DoubleToString(RR_Target, 1));
         Alert("Trade SHORT ouvert | lot ", lot);
      }
      else
         Print("GoldSwingInstitutionalSemiAuto | Erreur Sell: ", Trade.ResultRetcodeDescription());
      RemoveConfirmPanel();
   }
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   SymInfo.RefreshRates();
   const double bid = SymInfo.Bid();
   const double ask = SymInfo.Ask();
   const double pt  = BrokerPoint();
   const double beBuf = BE_ProfitPoints * pt;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR_H4, 0, 0, 1, atr) != 1) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      const long ptype = PositionGetInteger(POSITION_TYPE);
      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double       sl    = PositionGetDouble(POSITION_SL);
      const double tp    = PositionGetDouble(POSITION_TP);

      double oneR = GetInitialRiskPx(ticket, entry, sl);
      if(oneR <= 0.0) continue;

      const double moveR = (ptype == POSITION_TYPE_BUY)
                           ? ((bid - entry) / oneR)
                           : ((entry - ask) / oneR);

      //--- Phase BE après Trail_Start_R (en mouvement favorable, pas P/L compte)
      if(moveR >= Trail_Start_R && !IsBEDone(ticket))
      {
         double newSL;
         if(ptype == POSITION_TYPE_BUY)
            newSL = entry + beBuf;
         else
            newSL = entry - beBuf;

         double slAdj = newSL;
         double tpAdj = tp;
         const double px = (ptype == POSITION_TYPE_BUY ? bid : ask);
         NormalizeStops((ENUM_ORDER_TYPE)ptype, px, slAdj, tpAdj);

         const bool better = (ptype == POSITION_TYPE_BUY) ? (slAdj > sl) : ((sl == 0.0) || (slAdj < sl));
         if(better && Trade.PositionModify(ticket, slAdj, tpAdj))
            SetBEDone(ticket);
      }

      //--- Trailing loose après activation supplémentaire (défaut 1R + 0.5R = 1.5R)
      const double trailFromR = Trail_Start_R + Trail_ActivateExtraR;
      if(moveR >= trailFromR && IsBEDone(ticket))
      {
         double trailDist = atr[0] * Trail_ATR_Multi;
         double newSL;

         if(ptype == POSITION_TYPE_BUY)
         {
            newSL = bid - trailDist;
            const double swingL = LastSwingLowForTrail();
            if(swingL > 0.0)
            {
               const double floorSL = swingL - Trail_SwingBufferPts * pt;
               newSL = MathMax(newSL, floorSL);
            }
            newSL = MathMax(newSL, sl);
            if(newSL < bid - pt && newSL > sl + pt * 5)
            {
               double slAdj = newSL;
               double tpAdj = tp;
               NormalizeStops(ORDER_TYPE_BUY, bid, slAdj, tpAdj);
               Trade.PositionModify(ticket, slAdj, tpAdj);
            }
         }
         else
         {
            newSL = ask + trailDist;
            const double swingH = LastSwingHighForTrail();
            if(swingH > 0.0)
            {
               const double capSL = swingH + Trail_SwingBufferPts * pt;
               newSL = MathMin(newSL, capSL);
            }
            if(sl > 0.0)
               newSL = MathMin(sl, newSL);
            if(newSL > ask + pt && (sl == 0.0 || newSL < sl - pt * 5))
            {
               double slAdj = newSL;
               double tpAdj = tp;
               NormalizeStops(ORDER_TYPE_SELL, ask, slAdj, tpAdj);
               Trade.PositionModify(ticket, slAdj, tpAdj);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CleanupStaleGlobals();

   datetime barH4 = iTime(_Symbol, PERIOD_H4, 0);
   if(barH4 != g_lastBarH4)
   {
      g_lastBarH4 = barH4;
      if(FindSwingLowHigh(g_support, g_resist))
         DrawLevels();
   }

   ManageTrailingStop();

   if(g_signalActive)
      return;

   if(HasOurPosition())
      return;

   double ema50[], ema200[], ema200d1[], rsi[], atr[];
   ArraySetAsSeries(ema50, true);
   ArraySetAsSeries(ema200, true);
   ArraySetAsSeries(ema200d1, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(hEMA50_H4, 0, 0, 2, ema50) < 2) return;
   if(CopyBuffer(hEMA200_H4, 0, 0, 2, ema200) < 2) return;
   if(CopyBuffer(hEMA200_D1, 0, 0, 1, ema200d1) < 1) return;
   if(CopyBuffer(hRSI_H4, 0, 0, 1, rsi) < 1) return;
   if(CopyBuffer(hATR_H4, 0, 0, 1, atr) < 1) return;

   double closeD1 = iClose(_Symbol, PERIOD_D1, 0);
   if(closeD1 <= 0.0) return;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   const bool d1Bull = (closeD1 > ema200d1[0]);
   const bool d1Bear = (closeD1 < ema200d1[0]);

   //--- LONG : rebond zone support + biais H4/D1 haussiers
   if(d1Bull && ema50[0] > ema200[0] && rsi[0] > 50.0 && ask > ema50[0] &&
      g_support > 0.0 && (ask - g_support) < atr[0] * NearLevel_ATR_Ratio)
   {
      g_signalType  = ORDER_TYPE_BUY;
      g_sigSL       = g_support - atr[0] * ATR_Multi_SL;
      g_sigTP       = ask + (ask - g_sigSL) * RR_Target;
      NormalizeStops(ORDER_TYPE_BUY, ask, g_sigSL, g_sigTP);
      CreateConfirmPanel();
      Alert("GoldSwingInstitutionalSemiAuto | SIGNAL LONG H4 — validation requise.");
      if(UsePushAlerts) SendNotification("GSISA | LONG H4 — ouvrez le graphique et validez.");
      return;
   }

   //--- SHORT : rejet zone résistance + biais H4/D1 baissiers
   if(d1Bear && ema50[0] < ema200[0] && rsi[0] < 50.0 && bid < ema50[0] &&
      g_resist > 0.0 && (g_resist - bid) < atr[0] * NearLevel_ATR_Ratio)
   {
      g_signalType  = ORDER_TYPE_SELL;
      g_sigSL       = g_resist + atr[0] * ATR_Multi_SL;
      g_sigTP       = bid - (g_sigSL - bid) * RR_Target;
      NormalizeStops(ORDER_TYPE_SELL, bid, g_sigSL, g_sigTP);
      CreateConfirmPanel();
      Alert("GoldSwingInstitutionalSemiAuto | SIGNAL SHORT H4 — validation requise.");
      if(UsePushAlerts) SendNotification("GSISA | SHORT H4 — ouvrez le graphique et validez.");
   }
}

//+------------------------------------------------------------------+
