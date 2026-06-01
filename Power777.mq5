//+------------------------------------------------------------------+
//|                                                    Power777.mq5 |
//|                        EA Power777 - ADX + RSI + Grid + Basket SL |
//|                                      Version 1.20 - Mai 2026     |
//+------------------------------------------------------------------+
#property copyright "Grok xAI - Pour Eagle"
#property version   "1.20"

#include <Trade\Trade.mqh>

//--- Inputs
input string          __________1 = "=== Paramètres de Trading ===";
input double          LotSize             = 0.01;          // Taille de lot de base
input double          MartingaleMultiplier = 1.5;          // Multiplicateur de lot
input int             MaxGridLevels       = 7;             // Nombre maximum de niveaux grid
input double          GridStepPips        = 40.0;          // Distance entre chaque niveau (pips)

input string          __________2 = "=== Indicateurs ADX + RSI ===";
input int             RSI_Period          = 14;
input double          RSI_BuyLevel        = 30.0;          // Oversold pour BUY
input double          RSI_SellLevel       = 70.0;          // Overbought pour SELL
input int             ADX_Period          = 14;
input double          ADX_Level           = 25.0;          // ADX < ce niveau = marché ranging
input ENUM_TIMEFRAMES HigherTF            = PERIOD_CURRENT; // Timeframe pour ADX (PERIOD_CURRENT = même TF)

input string          __________3 = "=== Gestion Risque ===";
input bool            UseBasketSL         = true;          // Activer le Basket Stop Loss en €
input double          BasketSL_EUR        = 50.0;          // Perte max autorisée sur le panier (€)

input string          __________4 = "=== Filtre Horaire Paris ===";
input bool            UseParisTimeFilter  = true;          // Filtre horaire Paris activé par défaut
input int             StartHourParis      = 1;             // Heure de début (heure locale Paris)
input int             EndHourParis        = 7;             // Heure de fin (heure locale Paris)

input string          __________5 = "=== Autres ===";
input ulong           MagicNumber         = 20260422;
input int             Slippage            = 3;
input int             BasketTP_Pips       = 80;            // TP du panier en pips (depuis le prix moyen)
input bool            Verbose             = true;          // Logs détaillés (mode verbose)

//--- Variables globales
CTrade   Trade;
int      hRSI = INVALID_HANDLE;
int      hADX = INVALID_HANDLE;
double   PointValue;
int      TotalBuy=0, TotalSell=0;
double   LastLotBuy=0, LastLotSell=0;

//+------------------------------------------------------------------+
//| Mode de remplissage broker                                        |
//+------------------------------------------------------------------+
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
//| Timeframe effectif pour ADX                                       |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES AdxTimeframe()
  {
   return (HigherTF == PERIOD_CURRENT) ? _Period : HigherTF;
  }

//+------------------------------------------------------------------+
//| Trading autorisé (équivalent MQL4 IsTradeAllowed)                 |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   PointValue = (_Symbol == "XAUUSD" || StringFind(_Symbol, "JPY") != -1) ? 0.01 : 0.0001;
   if(_Digits == 3 || _Digits == 5)
      PointValue *= 10;

   hRSI = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   hADX = iADX(_Symbol, AdxTimeframe(), ADX_Period);
   if(hRSI == INVALID_HANDLE || hADX == INVALID_HANDLE)
     {
      Print("=== Power777 | ERREUR: création handles RSI/ADX ===");
      return INIT_FAILED;
     }

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(Slippage);
   SetupTradeFillingMode();

   Print("=== Power777 v1.20 chargé sur ", _Symbol, " ===");
   Print("Lot=", LotSize,
         " | BasketSL=", UseBasketSL ? "ON (" + DoubleToString(BasketSL_EUR, 0) + "€)" : "OFF",
         " | Filtre Paris=", UseParisTimeFilter ? "ON (" + IntegerToString(StartHourParis) + "h-" + IntegerToString(EndHourParis) + "h)" : "OFF",
         " | Verbose=", Verbose ? "ON" : "OFF");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hRSI != INVALID_HANDLE)
      IndicatorRelease(hRSI);
   if(hADX != INVALID_HANDLE)
      IndicatorRelease(hADX);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsTradeAllowed())
      return;

   //--- Filtre horaire Paris
   if(UseParisTimeFilter && !IsParisTradingTime())
      return;

   //--- Mise à jour des compteurs
   CountOrders();

   //--- Protection Basket SL
   CheckBasketSL();

   //--- Nouveau signal initial
   if(TotalBuy == 0 && TotalSell == 0)
     {
      if(IsBuySignal())
         OpenFirstBuy();
      if(IsSellSignal())
         OpenFirstSell();
     }

   //--- Gestion grid
   ManageGrid();

   //--- Fermeture panier si TP atteint
   CheckBasketTP();
  }

//+------------------------------------------------------------------+
//| Lecture RSI barre 0                                               |
//+------------------------------------------------------------------+
double GetRSI()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hRSI, 0, 0, 1, buf) != 1)
      return EMPTY_VALUE;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Lecture ADX barre 1 (MODE_MAIN)                                   |
//+------------------------------------------------------------------+
double GetADX()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hADX, 0, 1, 1, buf) != 1)
      return EMPTY_VALUE;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Signal BUY                                                       |
//+------------------------------------------------------------------+
bool IsBuySignal()
  {
   double rsi = GetRSI();
   double adx = GetADX();

   if(Verbose)
      Print("[SIGNAL] BUY check → RSI=", DoubleToString(rsi, 2),
            " (seuil < ", RSI_BuyLevel, ") | ADX=", DoubleToString(adx, 2),
            " (seuil < ", ADX_Level, ")");

   return (rsi < RSI_BuyLevel && adx < ADX_Level);
  }

//+------------------------------------------------------------------+
//| Signal SELL                                                      |
//+------------------------------------------------------------------+
bool IsSellSignal()
  {
   double rsi = GetRSI();
   double adx = GetADX();

   if(Verbose)
      Print("[SIGNAL] SELL check → RSI=", DoubleToString(rsi, 2),
            " (seuil > ", RSI_SellLevel, ") | ADX=", DoubleToString(adx, 2),
            " (seuil < ", ADX_Level, ")");

   return (rsi > RSI_SellLevel && adx < ADX_Level);
  }

//+------------------------------------------------------------------+
//| Ouverture première position BUY                                  |
//+------------------------------------------------------------------+
void OpenFirstBuy()
  {
   double lot = LotSize;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(Trade.Buy(lot, _Symbol, ask, 0.0, 0.0, "Power777 BUY #1"))
     {
      LastLotBuy = lot;
      if(Verbose)
         Print("[OPEN] Premier BUY ouvert | Lot=", lot, " | Prix=", DoubleToString(ask, _Digits));
     }
  }

//+------------------------------------------------------------------+
//| Ouverture première position SELL                                 |
//+------------------------------------------------------------------+
void OpenFirstSell()
  {
   double lot = LotSize;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(Trade.Sell(lot, _Symbol, bid, 0.0, 0.0, "Power777 SELL #1"))
     {
      LastLotSell = lot;
      if(Verbose)
         Print("[OPEN] Premier SELL ouvert | Lot=", lot, " | Prix=", DoubleToString(bid, _Digits));
     }
  }

//+------------------------------------------------------------------+
//| Gestion du grid + martingale                                     |
//+------------------------------------------------------------------+
void ManageGrid()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- Grid BUY
   if(TotalBuy > 0 && TotalBuy <= MaxGridLevels)
     {
      double avgPrice = GetAveragePrice(POSITION_TYPE_BUY);
      double distancePips = (avgPrice - bid) / PointValue;

      if(Verbose && TotalBuy > 0)
         Print("[GRID] BUY check | Niveau=", TotalBuy,
               " | Distance=", DoubleToString(distancePips, 1), " pips | Seuil=", GridStepPips);

      if(bid <= avgPrice - GridStepPips * PointValue)
        {
         double newLot = NormalizeDouble(LastLotBuy * MartingaleMultiplier, 2);
         if(Trade.Buy(newLot, _Symbol, ask, 0.0, 0.0, "Power777 BUY #" + IntegerToString(TotalBuy + 1)))
           {
            LastLotBuy = newLot;
            if(Verbose)
               Print("[GRID] BUY ajouté #", TotalBuy + 1, " | Lot=", newLot);
           }
        }
     }

   //--- Grid SELL
   if(TotalSell > 0 && TotalSell <= MaxGridLevels)
     {
      double avgPrice = GetAveragePrice(POSITION_TYPE_SELL);
      double distancePips = (ask - avgPrice) / PointValue;

      if(Verbose && TotalSell > 0)
         Print("[GRID] SELL check | Niveau=", TotalSell,
               " | Distance=", DoubleToString(distancePips, 1), " pips | Seuil=", GridStepPips);

      if(ask >= avgPrice + GridStepPips * PointValue)
        {
         double newLot = NormalizeDouble(LastLotSell * MartingaleMultiplier, 2);
         if(Trade.Sell(newLot, _Symbol, bid, 0.0, 0.0, "Power777 SELL #" + IntegerToString(TotalSell + 1)))
           {
            LastLotSell = newLot;
            if(Verbose)
               Print("[GRID] SELL ajouté #", TotalSell + 1, " | Lot=", newLot);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Vérifie le TP du panier                                          |
//+------------------------------------------------------------------+
void CheckBasketTP()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(TotalBuy > 0)
     {
      double avg = GetAveragePrice(POSITION_TYPE_BUY);
      if(bid - avg >= BasketTP_Pips * PointValue)
        {
         if(Verbose)
            Print("[BASKET TP] BUY → Fermeture (", BasketTP_Pips, " pips)");
         CloseAllBuy();
        }
     }
   if(TotalSell > 0)
     {
      double avg = GetAveragePrice(POSITION_TYPE_SELL);
      if(avg - ask >= BasketTP_Pips * PointValue)
        {
         if(Verbose)
            Print("[BASKET TP] SELL → Fermeture (", BasketTP_Pips, " pips)");
         CloseAllSell();
        }
     }
  }

//+------------------------------------------------------------------+
//| Vérifie le Basket Stop Loss en €                                 |
//+------------------------------------------------------------------+
void CheckBasketSL()
  {
   if(!UseBasketSL)
      return;

   if(TotalBuy > 0)
     {
      double profit = GetBasketProfit(POSITION_TYPE_BUY);
      if(Verbose)
         Print("[CHECK SL] BUY | P/L = ", DoubleToString(profit, 2), " €");
      if(profit <= -BasketSL_EUR)
        {
         Print("[BASKET SL] BUY → Perte = ", DoubleToString(profit, 2), " € → Fermeture");
         CloseAllBuy();
        }
     }

   if(TotalSell > 0)
     {
      double profit = GetBasketProfit(POSITION_TYPE_SELL);
      if(Verbose)
         Print("[CHECK SL] SELL | P/L = ", DoubleToString(profit, 2), " €");
      if(profit <= -BasketSL_EUR)
        {
         Print("[BASKET SL] SELL → Perte = ", DoubleToString(profit, 2), " € → Fermeture");
         CloseAllSell();
        }
     }
  }

//+------------------------------------------------------------------+
//| Calcule le P/L du panier                                         |
//+------------------------------------------------------------------+
double GetBasketProfit(const ENUM_POSITION_TYPE type)
  {
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      profit += PositionGetDouble(POSITION_PROFIT)
              + PositionGetDouble(POSITION_SWAP)
              + PositionGetDouble(POSITION_COMMISSION);
     }
   return profit;
  }

//+------------------------------------------------------------------+
//| Fonctions utilitaires                                            |
//+------------------------------------------------------------------+
void CountOrders()
  {
   TotalBuy = TotalSell = 0;
   LastLotBuy = LastLotSell = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype == POSITION_TYPE_BUY)
        {
         TotalBuy++;
         LastLotBuy = PositionGetDouble(POSITION_VOLUME);
        }
      if(ptype == POSITION_TYPE_SELL)
        {
         TotalSell++;
         LastLotSell = PositionGetDouble(POSITION_VOLUME);
        }
     }
  }

double GetAveragePrice(const ENUM_POSITION_TYPE type)
  {
   double sum = 0, lots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;
      const double vol = PositionGetDouble(POSITION_VOLUME);
      sum  += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
      lots += vol;
     }
   return (lots > 0) ? sum / lots : 0;
  }

void CloseAllBuy()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      Trade.PositionClose(ticket, Slippage);
     }
  }

void CloseAllSell()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      Trade.PositionClose(ticket, Slippage);
     }
  }

bool IsParisTradingTime()
  {
   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   const int hour = dt.hour;
   return (hour >= StartHourParis && hour < EndHourParis);
  }
//+------------------------------------------------------------------+
