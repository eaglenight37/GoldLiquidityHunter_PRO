//+------------------------------------------------------------------+
//|     EvoX_SuperTrend_XAUUSD_M15_v1.1.mq5                         |
//|  Single Pair XAUUSD M15 - SuperTrend + ADX + Full Risk EvoX     |
//+------------------------------------------------------------------+
#property copyright "EvoX"
#property version   "1.1"
#property description "EvoX SuperTrend XAUUSD M15 — ADX filtre, risk %, news (calendrier), BE/trail 2R-lock"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//  INPUTS (presets conservés)
//+------------------------------------------------------------------+
input double   RiskPercent            = 0.42;
input double   MaxDailyLossPercent    = 3.2;
input double   WeeklyTargetEuro       = 75.0;
input double   MaxDrawdownPercent     = 15.0;
input double   ConsecLoss_RiskMult    = 0.40;

input int      SuperTrend_Period      = 10;
input double   SuperTrend_Multiplier  = 3.0;
input int      ADX_Period             = 14;
input double   ADX_Min                = 25.0;

input bool     UseNewsFilter          = true;
input bool     CloseOnNews            = true;
input bool     UseAutoHighImpactNews  = true;
input int      GMTOffset              = 2;

input bool     UseTrailing            = true;
input bool     UseBreakeven           = true;
input double   BE_Trigger_ATR         = 0.8;
input double   TrailDist_2R_ATR       = 0.35;

input long     MagicNumber            = 20260401;
input int      Slippage               = 3;
input bool     UseDashboard           = true;

input int      SuperTrend_LookbackBars = 400; // profondeur pour le calcul ST (série path-dependent)

//+------------------------------------------------------------------+
//  GLOBALES
//+------------------------------------------------------------------+
double   g_dailyStartBalance = 0;
double   g_weeklyStartBalance = 0;
double   g_initialBalance = 0;
double   g_peakEquity = 0;
bool     g_dailyLossTriggered = false;
bool     g_weeklyTargetReached = false;
bool     g_equityGuardTriggered = false;
int      consecLosses = 0;
datetime lastBarTime = 0;
ulong    g_lastConsecLossDealTicket = 0;

ulong    currentTicket = 0;
double   entryPrice = 0;
double   initialSL = 0;
bool     is2RLocked = false;

int      hATR_ST = INVALID_HANDLE;
int      hATR_14 = INVALID_HANDLE;
int      hADX = INVALID_HANDLE;

int      g_lastDayYMD = 0;
int      g_lastWeekId = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hATR_ST  = iATR(_Symbol, PERIOD_M15, SuperTrend_Period);
   hATR_14  = iATR(_Symbol, PERIOD_M15, 14);
   hADX     = iADX(_Symbol, PERIOD_M15, ADX_Period);

   if(hATR_ST == INVALID_HANDLE || hATR_14 == INVALID_HANDLE || hADX == INVALID_HANDLE)
   {
      Print("EvoX: échec création indicateurs (ATR/ADX). INIT_FAILED");
      return INIT_FAILED;
   }

   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   InitDailyTracking();
   InitWeeklyTracking();
   InitWeekDayKeys();
   InitConsecLossCursor();

   Print("=== EvoX SuperTrend XAUUSD M15 v1.1 lancé ===");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR_ST != INVALID_HANDLE)  IndicatorRelease(hATR_ST);
   if(hATR_14 != INVALID_HANDLE) IndicatorRelease(hATR_14);
   if(hADX != INVALID_HANDLE)    IndicatorRelease(hADX);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(ManageEquityGuard())
      return;
   if(UseDashboard)
      UpdateDashboard();

   CheckDailyReset();
   CheckWeeklyReset();
   ManageDailyLoss();
   ManageWeeklyTarget();

   if(g_dailyLossTriggered || g_weeklyTargetReached)
      return;

   TrackHistoryForConsecLosses();

   const bool newsActive = UseNewsFilter && (IsNewsTime() || IsHighImpactNewsTime());
   if(newsActive && CloseOnNews)
      CloseAllPositions("News");

   SyncActivePositionState();

   if(UseTrailing)
      ManageTrailing();
   if(UseBreakeven)
      ManageBreakeven();

   datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBar == lastBarTime)
      return;
   lastBarTime = currentBar;

   ProcessSignal();
}

//+------------------------------------------------------------------+
//  Utilitaires indicateurs
//+------------------------------------------------------------------+
bool CopyOne(const int handle, const int buffer, const int shift, double &out)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, buffer, shift, 1, buf) != 1)
      return false;
   out = buf[0];
   return MathIsValidNumber(out);
}

//+------------------------------------------------------------------+
//  SuperTrend (calcul sur buffer — correct pour MQL5 / série)
//+------------------------------------------------------------------+
bool GetSuperTrendAtShift(const int shift, double &stOut, double &upperBandOut, double &lowerBandOut)
{
   if(shift < 1)
      return false;

   const int need = MathMax(SuperTrend_LookbackBars, SuperTrend_Period + ADX_Period + 50);
   double atr[], high[], low[], close[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyBuffer(hATR_ST, 0, 0, need, atr) < need)
      return false;
   if(CopyHigh(_Symbol, PERIOD_M15, 0, need, high) != need)
      return false;
   if(CopyLow(_Symbol, PERIOD_M15, 0, need, low) != need)
      return false;
   if(CopyClose(_Symbol, PERIOD_M15, 0, need, close) != need)
      return false;

   static double st[];
   static int    tr[];
   ArrayResize(st, need);
   ArrayResize(tr, need);
   ArrayInitialize(st, 0.0);
   ArrayInitialize(tr, 0);

   // i = need-1 (plus vieille) -> 0 (plus récente)
   for(int i = need - 1; i >= 0; i--)
   {
      const double median = (high[i] + low[i]) / 2.0;
      const double upperBand = median + (SuperTrend_Multiplier * atr[i]);
      const double lowerBand = median - (SuperTrend_Multiplier * atr[i]);
      if(i == need - 1)
      {
         st[i] = lowerBand;
         tr[i] = 1;
         continue;
      }

      const int j = i + 1; // barre plus ancienne (précédente dans le temps)
      if(close[i] > st[j])
         tr[i] = 1;
      else if(close[i] < st[j])
         tr[i] = -1;
      else
         tr[i] = tr[j];

      if(tr[i] == 1)
         st[i] = MathMax(lowerBand, st[j]);
      else
         st[i] = MathMin(upperBand, st[j]);

      if(i == shift)
      {
         stOut = st[i];
         upperBandOut = upperBand;
         lowerBandOut = lowerBand;
      }
   }

   return MathIsValidNumber(stOut);
}

//+------------------------------------------------------------------+
//  Signal (logique conservée : close vs ST, ADX min, TP 2R)
//+------------------------------------------------------------------+
void ProcessSignal()
{
   double superTrend = 0, ub = 0, lb = 0;
   if(!GetSuperTrendAtShift(1, superTrend, ub, lb))
      return;

   double close1 = 0;
   if(!CopyCloseAtShift(1, close1))
      return;
   double adxMain = 0;
   if(!CopyOne(hADX, 0, 1, adxMain))
      return;

   if(adxMain < ADX_Min)
      return;

   double atr14 = 0;
   if(!CopyOne(hATR_14, 0, 1, atr14))
      return;

   const double slDistPrice = MathMax(_Point, MathAbs(close1 - superTrend));
   double lot = CalculateLotSize(slDistPrice * 1.8);

   if(!IsTradeAllowed() || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(PositionsTotalByMagic() != 0)
      return;

   // BUY
   if(close1 > superTrend)
   {
      const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = superTrend;
      double tp = ask + (ask - sl) * 2.0;
      NormalizeStopsForType(POSITION_TYPE_BUY, ask, sl, tp);

      if(trade.Buy(lot, _Symbol, ask, sl, tp, "SuperTrendBuy"))
      {
         if(!ResolvePositionTicketAfterDeal(ask, sl))
            Print("EvoX: Buy OK mais ticket position non résolu.");
      }
   }
   // SELL
   else if(close1 < superTrend)
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = superTrend;
      double tp = bid - (sl - bid) * 2.0;
      NormalizeStopsForType(POSITION_TYPE_SELL, bid, sl, tp);

      if(trade.Sell(lot, _Symbol, bid, sl, tp, "SuperTrendSell"))
      {
         if(!ResolvePositionTicketAfterDeal(bid, sl))
            Print("EvoX: Sell OK mais ticket position non résolu.");
      }
   }
}

//+------------------------------------------------------------------+
bool CopyCloseAtShift(const int shift, double &out)
{
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, PERIOD_M15, shift, 1, c) != 1)
      return false;
   out = c[0];
   return MathIsValidNumber(out);
}

int PositionsTotalByMagic()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      n++;
   }
   return n;
}

bool SelectOurPosition()
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
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      return true;
   }
   return false;
}

void SyncActivePositionState()
{
   if(currentTicket != 0 && PositionSelectByTicket(currentTicket))
      return;

   currentTicket = 0;
   entryPrice = 0;
   initialSL = 0;
   is2RLocked = false;

   if(!SelectOurPosition())
      return;

   currentTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   initialSL = PositionGetDouble(POSITION_SL);
}

bool ResolvePositionTicketAfterDeal(const double entry, const double sl)
{
   const ulong dealTicket = trade.ResultDeal();
   if(dealTicket == 0)
      return false;

   if(!HistoryDealSelect(dealTicket))
      return false;

   const long posId = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(posId <= 0)
      return false;

   if(!PositionSelectByTicket((ulong)posId))
      return false;

   currentTicket = (ulong)posId;
   entryPrice = entry;
   initialSL = sl;
   is2RLocked = false;
   return true;
}

void NormalizeStopsForType(const ENUM_POSITION_TYPE type, const double price, double &sl, double &tp)
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevel * _Point;

   if(type == POSITION_TYPE_BUY)
   {
      if(sl > 0 && (price - sl) < minDist)
         sl = NormalizeDouble(price - minDist - tick, digits);
      if(tp > 0 && (tp - price) < minDist)
         tp = NormalizeDouble(price + minDist + tick, digits);
   }
   else
   {
      if(sl > 0 && (sl - price) < minDist)
         sl = NormalizeDouble(price + minDist + tick, digits);
      if(tp > 0 && (price - tp) < minDist)
         tp = NormalizeDouble(price - minDist - tick, digits);
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
}

//+------------------------------------------------------------------+
//  2R-Lock + Trailing (2R en distance de prix, pas en profit monétaire)
//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(!PositionSelectByTicket(currentTicket))
      return;

   double atr = 0;
   if(!CopyOne(hATR_14, 0, 1, atr))
      return;

   double currentSL = PositionGetDouble(POSITION_SL);
   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   const double riskDist = MathMax(_Point, MathAbs(openPrice - initialSL));
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double favorableMove = 0;
   if(type == POSITION_TYPE_BUY)
      favorableMove = bid - openPrice;
   else if(type == POSITION_TYPE_SELL)
      favorableMove = openPrice - ask;

   double trailDistance = atr * 0.70;

   if(!is2RLocked && favorableMove >= 2.0 * riskDist)
   {
      is2RLocked = true;
      Print("[2R-LOCK] Activé (prix)");
   }

   if(is2RLocked)
      trailDistance = atr * TrailDist_2R_ATR;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(type == POSITION_TYPE_BUY)
   {
      double newSL = bid - trailDistance;
      newSL = NormalizeDouble(newSL, digits);
      if(newSL > currentSL)
         trade.PositionModify(currentTicket, newSL, PositionGetDouble(POSITION_TP));
   }
   else if(type == POSITION_TYPE_SELL)
   {
      double newSL = ask + trailDistance;
      newSL = NormalizeDouble(newSL, digits);
      if(currentSL == 0 || newSL < currentSL)
         trade.PositionModify(currentTicket, newSL, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//  Breakeven (déclencheur en distance prix vs ATR)
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   if(!PositionSelectByTicket(currentTicket))
      return;

   double atr = 0;
   if(!CopyOne(hATR_14, 0, 1, atr))
      return;

   const double triggerMove = atr * BE_Trigger_ATR;
   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double favorableMove = 0;
   if(type == POSITION_TYPE_BUY)
      favorableMove = bid - openPrice;
   else if(type == POSITION_TYPE_SELL)
      favorableMove = openPrice - ask;

   if(favorableMove < triggerMove)
      return;

   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double beOffset = MathMax(3 * _Point * 10, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * 3);

   if(type == POSITION_TYPE_BUY)
   {
      double newSL = NormalizeDouble(openPrice + beOffset, digits);
      if(newSL > PositionGetDouble(POSITION_SL))
         trade.PositionModify(currentTicket, newSL, PositionGetDouble(POSITION_TP));
   }
   else
   {
      double newSL = NormalizeDouble(openPrice - beOffset, digits);
      const double curSL = PositionGetDouble(POSITION_SL);
      if(curSL == 0 || newSL < curSL)
         trade.PositionModify(currentTicket, newSL, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//  Risk Management
//+------------------------------------------------------------------+
double CalculateLotSize(const double slDistPrice)
{
   if(slDistPrice <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct = RiskPercent;
   if(consecLosses > 0)
      riskPct *= ConsecLoss_RiskMult;

   const double riskAmount = balance * riskPct / 100.0;

   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   const double lossPerLot = (slDistPrice / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = riskAmount / lossPerLot;

   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / vstep) * vstep;
   lots = MathMax(vmin, MathMin(vmax, lots));

   if(lots < vmin)
      lots = vmin;

   return NormalizeDouble(lots, 2);
}

void InitConsecLossCursor()
{
   g_lastConsecLossDealTicket = 0;

   const datetime from = TimeCurrent() - 30 * 24 * 3600;
   if(!HistorySelect(from, TimeCurrent()))
      return;

   ulong newestOutTicket = 0;
   datetime newestOutTime = 0;

   const int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      const ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(!HistoryDealSelect(dealTicket))
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      const datetime tt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(newestOutTicket == 0 || tt > newestOutTime)
      {
         newestOutTime = tt;
         newestOutTicket = dealTicket;
      }
   }

   g_lastConsecLossDealTicket = newestOutTicket;
}

void TrackHistoryForConsecLosses()
{
   static datetime lastScan = 0;
   if(TimeCurrent() == lastScan)
      return;
   lastScan = TimeCurrent();

   const datetime from = TimeCurrent() - 30 * 24 * 3600;
   if(!HistorySelect(from, TimeCurrent()))
      return;

   const int total = HistoryDealsTotal();
   if(total <= 0)
      return;

   ulong newestOutTicket = 0;
   datetime newestOutTime = 0;

   for(int i = total - 1; i >= 0; i--)
   {
      const ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      if(!HistoryDealSelect(dealTicket))
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      const datetime tt = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      if(newestOutTicket == 0 || tt > newestOutTime)
      {
         newestOutTime = tt;
         newestOutTicket = dealTicket;
      }
   }

   if(newestOutTicket == 0 || newestOutTicket == g_lastConsecLossDealTicket)
      return;

   if(!HistoryDealSelect(newestOutTicket))
      return;

   const double profit = HistoryDealGetDouble(newestOutTicket, DEAL_PROFIT)
                         + HistoryDealGetDouble(newestOutTicket, DEAL_SWAP)
                         + HistoryDealGetDouble(newestOutTicket, DEAL_COMMISSION);

   if(profit < 0.0)
      consecLosses++;
   else
      consecLosses = 0;

   g_lastConsecLossDealTicket = newestOutTicket;
}

void InitDailyTracking()
{
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyLossTriggered = false;
}

void CheckDailyReset()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   const int ymd = tm.year * 10000 + tm.mon * 100 + tm.day;
   if(ymd != g_lastDayYMD)
   {
      g_lastDayYMD = ymd;
      InitDailyTracking();
   }
}

void ManageDailyLoss()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dd = g_dailyStartBalance - eq;
   if(g_dailyStartBalance > 0 && (dd / g_dailyStartBalance) * 100.0 >= MaxDailyLossPercent)
   {
      g_dailyLossTriggered = true;
      CloseAllPositions("MaxDailyLoss");
      Print("EvoX: limite perte journalière atteinte.");
   }
}

void InitWeeklyTracking()
{
   g_weeklyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_weeklyTargetReached = false;
}

void InitWeekDayKeys()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   g_lastDayYMD = tm.year * 10000 + tm.mon * 100 + tm.day;
   g_lastWeekId = WeekIdFromTime(TimeCurrent());
}

int WeekIdFromTime(const datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);

   // Lundi 00:00 (heure serveur) comme borne de semaine
   const int dow = tm.day_of_week; // 0=dimanche ... 6=samedi
   const int daysFromMonday = (dow == 0 ? 6 : dow - 1);

   const datetime mondayMidnight = (datetime)(t - daysFromMonday * 86400 - tm.hour * 3600 - tm.min * 60 - tm.sec);

   MqlDateTime m0;
   TimeToStruct(mondayMidnight, m0);
   return m0.year * 10000 + m0.mon * 100 + m0.day;
}

void CheckWeeklyReset()
{
   const int wk = WeekIdFromTime(TimeCurrent());
   if(wk != g_lastWeekId)
   {
      g_lastWeekId = wk;
      InitWeeklyTracking();
   }
}

void ManageWeeklyTarget()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double wkpl = eq - g_weeklyStartBalance;
   if(wkpl >= WeeklyTargetEuro)
   {
      g_weeklyTargetReached = true;
      CloseAllPositions("WeeklyTarget");
      Print("EvoX: objectif hebdomadaire atteint.");
   }
}

bool ManageEquityGuard()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEquity)
      g_peakEquity = eq;

   if(g_peakEquity <= 0)
      return false;

   const double ddPct = (g_peakEquity - eq) / g_peakEquity * 100.0;
   if(ddPct >= MaxDrawdownPercent)
   {
      if(!g_equityGuardTriggered)
      {
         g_equityGuardTriggered = true;
         CloseAllPositions("MaxDrawdown");
         Print("EvoX: garde-fou drawdown equity activé.");
      }
      return true;
   }
   return false;
}

void CloseAllPositions(const string reason)
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
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      trade.PositionClose(ticket);
   }
   if(reason != "")
      Print("EvoX: CloseAllPositions — ", reason);
}

datetime ServerToGmt(const datetime tServer)
{
   // GMTOffset = décalage broker vs GMT (broker = GMT + GMTOffset) => GMT = server - offset*3600
   return (datetime)(tServer - (long)GMTOffset * 3600);
}

bool IsNewsTime()
{
   // Fenêtre simple configurable : blocage 12:25–12:55 et 13:25–14:10 GMT (NFP/FOMC fréquents)
   // + décalage GMTOffset pour approximer l’heure serveur
   MqlDateTime g;
   TimeToStruct(ServerToGmt(TimeCurrent()), g);

   const int minutes = g.hour * 60 + g.min;

   const bool lunch = (minutes >= 12 * 60 + 25 && minutes <= 12 * 60 + 55);
   const bool us = (minutes >= 13 * 60 + 25 && minutes <= 14 * 60 + 10);
   return (lunch || us);
}

bool IsHighImpactNewsTime()
{
   if(!UseAutoHighImpactNews)
      return false;

   MqlCalendarValue values[];
   const datetime t0 = TimeCurrent() - 20 * 60;
   const datetime t1 = TimeCurrent() + 40 * 60;

   // Pays + devise : conjonction côté terminal ; "US" couvre une grande partie des drivers USD.
   const int n = CalendarValueHistory(values, t0, t1, "US", NULL);
   if(n <= 0)
      return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;

      const datetime et = values[i].time;
      if(et >= t0 - 10 * 60 && et <= t1 + 10 * 60)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  Dashboard
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   const double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dyPL = eq - g_dailyStartBalance;
   const double wkPL = eq - g_weeklyStartBalance;

   string txt = "══════════════════════════════\n";
   txt += "  EvoX SuperTrend XAUUSD M15 v1.1\n";
   txt += "══════════════════════════════\n";
   txt += " Balance : " + DoubleToString(bal, 2) + "\n";
   txt += " Equity  : " + DoubleToString(eq, 2) + "\n";
   txt += " P/L Jour: " + DoubleToString(dyPL, 2) + "\n";
   txt += " P/L Sem : " + DoubleToString(wkPL, 2) + " / " + DoubleToString(WeeklyTargetEuro, 0) + "\n";
   txt += " Risk    : " + DoubleToString(RiskPercent, 2) + "%";
   if(consecLosses > 0)
      txt += " (x" + DoubleToString(ConsecLoss_RiskMult, 2) + " après pertes)";
   txt += "\n";
   txt += " DD guard: " + (g_equityGuardTriggered ? "OUI" : "NON") + "\n";
   txt += " News    : " + (UseNewsFilter ? "ON" : "OFF") + "\n";
   txt += "══════════════════════════════";
   Comment(txt);
}

//+------------------------------------------------------------------+
