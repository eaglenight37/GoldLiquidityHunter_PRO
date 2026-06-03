//+------------------------------------------------------------------+
//|              XAUUSD_GridBasket_Secure_PRO.mq5                     |
//|     Grid Basket ultra sécurisé — Walk-Forward / Strategy Tester   |
//|          Copyright 2026, Professional Trading Systems            |
//+------------------------------------------------------------------+
/*
╔══════════════════════════════════════════════════════════════════════╗
║        XAUUSD GRID BASKET SECURE PRO — DOCUMENTATION STRATÉGIE       ║
╠══════════════════════════════════════════════════════════════════════╣
║                                                                      ║
║  TYPE        : Expert Advisor Grid Basket sur XAUUSD (or)            ║
║  TIMEFRAME   : Compatible tout TF (analyse sur SignalTF paramétrable)║
║  COMPTE      : Standard, Cent, Micro — détection auto lots/décimales║
║                                                                      ║
║  ── PHILOSOPHIE DE RISQUE (priorité absolue) ──                       ║
║  • Objectif drawdown global compte < 3% (surveillance continue)      ║
║  • Basket SL paramétrable, idéalement avant 5% de perte panier       ║
║  • Basket TP rapproché (% balance ou valeur monétaire)               ║
║  • Daily Max Drawdown : blocage entrées + option fermeture panier    ║
║  • Equity Protection : arrêt total si equity sous seuil (% ou $)     ║
║                                                                      ║
║  ── LOGIQUE D'ENTRÉE (zone de retournement) ──                       ║
║  • Fenêtre horaire nocturne paramétrable (ex. 22h → 8h serveur)      ║
║  • RSI(14) extrême : surachat → grille SELL, survente → grille BUY   ║
║  • ADX(14) faible : marché en range / retournement probable          ║
║  • Bollinger(20,2) : prix proche bande sup. ou inf. (proximité %)   ║
║  • Un seul panier actif à la fois (BUY ou SELL)                      ║
║                                                                      ║
║  ── GESTION GRILLE ──                                                ║
║  • Distance entre niveaux = ATR × multiplicateur (adaptatif volatilité)║
║  • Nombre max de niveaux paramétrable                                ║
║  • Progression de lot légère (fixe, linéaire ou multiplicateur)      ║
║                                                                      ║
║  ── GESTION PANIER (BASKET) ──                                       ║
║  • P/L total recalculé à chaque tick                                 ║
║  • Fermeture complète sur Basket TP ou Basket SL                     ║
║  • Partial Close optionnel (ex. 50% au 1er objectif intermédiaire)   ║
║  • Basket Breakeven : verrouillage à zéro après profit seuil         ║
║                                                                      ║
║  ── LOGGING WALK-FORWARD ──                                          ║
║  • Print() verbeux avec timestamps sur chaque événement clé          ║
║  • Export CSV optionnel (historique paniers, P/L, durée, raison)     ║
║  • Comment() graphique : état panier, P/L, niveaux, risque           ║
║  • OnDeinit : résumé complet (profit, max DD, winrate paniers…)      ║
║                                                                      ║
║  ── OPTIMISATION (OnTester) ──                                       ║
║  • Score composite : Profit Factor × (1 − MaxDD%) avec pénalités     ║
║    si MaxDD > 3% ou si recovery factor insuffisant                   ║
║                                                                      ║
║  PARAMÈTRES RECOMMANDÉS (point de départ) :                          ║
║  InpBasketTP_Percent=0.15 | InpBasketSL_Percent=0.40                 ║
║  InpMaxGlobalDD_Percent=3.0 | InpDailyMaxDD_Percent=1.5             ║
║  InpGridMaxLevels=5 | InpATR_GridMult=0.8 | InpNightStartHour=22     ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
*/

#property copyright   "Professional Trading Systems 2026"
#property link        "https://github.com"
#property version     "1.00"
#property description "XAUUSD Grid Basket Secure PRO — Walk-Forward ready"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|                         ÉNUMÉRATIONS                              |
//+------------------------------------------------------------------+

// Mode de calcul du Take Profit du panier
enum ENUM_BASKET_VALUE_MODE
{
   BASKET_MODE_PERCENT = 0,   // % de la balance
   BASKET_MODE_MONEY   = 1    // Valeur monétaire absolue
};

// Progression des lots entre niveaux de grille
enum ENUM_LOT_PROGRESSION
{
   LOT_PROG_FIXED     = 0,   // Lot identique à chaque niveau
   LOT_PROG_LINEAR    = 1,   // Ajout linéaire (+InpLotStep à chaque niveau)
   LOT_PROG_MULTIPLY  = 2    // Multiplication légère (×InpLotMultiplier)
};

// Action en cas de dépassement du drawdown journalier
enum ENUM_DAILY_DD_ACTION
{
   DAILY_DD_BLOCK_ENTRIES = 0,  // Bloquer uniquement les nouvelles entrées
   DAILY_DD_CLOSE_BASKET  = 1,  // Fermer le panier + bloquer entrées
   DAILY_DD_STOP_EA       = 2   // Arrêt complet du trading pour la journée
};

// Mode protection equity
enum ENUM_EQUITY_PROTECT_MODE
{
   EQUITY_PROTECT_PERCENT = 0,  // Seuil en % de la balance initiale
   EQUITY_PROTECT_MONEY   = 1   // Seuil en valeur monétaire absolue
};

// Niveau de verbosité des logs
enum ENUM_LOG_LEVEL
{
   LOG_LEVEL_SILENT  = 0,
   LOG_LEVEL_NORMAL  = 1,
   LOG_LEVEL_VERBOSE = 2,
   LOG_LEVEL_DEBUG   = 3
};

//+------------------------------------------------------------------+
//|                    INPUTS — GROUPES CLAIRS                        |
//+------------------------------------------------------------------+

input group "══ GÉNÉRAL ══"
input ulong              InpMagicNumber        = 20260603;       // Magic Number
input ENUM_TIMEFRAMES    InpSignalTF           = PERIOD_M15;     // Timeframe d'analyse des signaux
input bool               InpStrictXAUOnly      = true;           // Symbole or uniquement (XAU/GOLD)
input int                InpMaxSpreadPoints    = 80;             // Spread max autorisé (points)
input int                InpSlippagePoints     = 30;             // Slippage max (points)

input group "══ RISQUE GLOBAL ══"
input double             InpMaxGlobalDD_Percent = 3.0;           // Drawdown global max compte (%)
input double             InpDailyMaxDD_Percent  = 1.5;           // Drawdown journalier max (%)
input ENUM_DAILY_DD_ACTION InpDailyDD_Action    = DAILY_DD_CLOSE_BASKET; // Action si DD journalier
input bool               InpEnableEquityProtect = true;          // Activer protection equity
input ENUM_EQUITY_PROTECT_MODE InpEquityProtectMode = EQUITY_PROTECT_PERCENT; // Mode equity protect
input double             InpEquityProtectValue  = 97.0;          // Seuil equity (% ou $ selon mode)

input group "══ BASKET TP / SL ══"
input ENUM_BASKET_VALUE_MODE InpBasketTP_Mode  = BASKET_MODE_PERCENT; // Mode Basket TP
input double             InpBasketTP_Value     = 0.15;           // Basket TP (% balance ou $)
input ENUM_BASKET_VALUE_MODE InpBasketSL_Mode  = BASKET_MODE_PERCENT; // Mode Basket SL
input double             InpBasketSL_Value     = 0.40;           // Basket SL (% balance ou $, idéal <5%)

input group "══ BASKET AVANCÉ ══"
input bool               InpEnablePartialClose = true;           // Activer partial close panier
input ENUM_BASKET_VALUE_MODE InpPartialTP_Mode = BASKET_MODE_PERCENT; // Mode objectif partial
input double             InpPartialTP_Value    = 0.08;           // Objectif partial (% ou $)
input double             InpPartialClosePercent = 50.0;            // % du panier à fermer au partial
input bool               InpEnableBasketBE     = true;           // Activer basket breakeven
input ENUM_BASKET_VALUE_MODE InpBasketBE_Mode  = BASKET_MODE_PERCENT; // Mode seuil breakeven
input double             InpBasketBE_Value     = 0.05;           // Profit pour activer BE (% ou $)

input group "══ GRILLE ══"
input double             InpBaseLot            = 0.01;           // Lot de base (niveau 1)
input int                InpGridMaxLevels      = 5;              // Nombre max de niveaux grille
input int                InpATR_Period         = 14;             // Période ATR (distance grille)
input double             InpATR_GridMult       = 0.80;           // Distance grille = ATR × mult
input ENUM_LOT_PROGRESSION InpLotProgression   = LOT_PROG_LINEAR;  // Type progression lot
input double             InpLotStep            = 0.01;           // Incrément lot (linéaire)
input double             InpLotMultiplier      = 1.15;           // Multiplicateur lot (×)

input group "══ SIGNAUX — INDICATEURS ══"
input int                InpRSI_Period         = 14;             // Période RSI
input double             InpRSI_Oversold       = 30.0;           // RSI survente (signal BUY)
input double             InpRSI_Overbought     = 70.0;           // RSI surachat (signal SELL)
input int                InpADX_Period         = 14;             // Période ADX
input double             InpADX_MaxLevel       = 22.0;           // ADX max (faible = retournement)
input int                InpBB_Period          = 20;             // Période Bollinger
input double             InpBB_Deviation       = 2.0;            // Déviation Bollinger
input double             InpBB_ProximityPercent = 15.0;          // Proximité bande BB (% de la largeur)

input group "══ SESSION NOCTURNE ══"
input int                InpNightStartHour     = 22;             // Début session nocturne (heure serveur)
input int                InpNightEndHour       = 8;              // Fin session nocturne (heure serveur)

input group "══ LOGGING & EXPORT WALK-FORWARD ══"
input ENUM_LOG_LEVEL     InpLogLevel           = LOG_LEVEL_VERBOSE; // Niveau de log
input bool               InpExportCSV          = true;             // Exporter historique paniers CSV
input string             InpCSVFileName        = "GridBasket_WF.csv"; // Nom fichier CSV (MQL5/Files)

//+------------------------------------------------------------------+
//|              STRUCTURES & CLASSE CBasket                          |
//+------------------------------------------------------------------+

// Enregistrement statistique d'un panier fermé
struct SBasketRecord
{
   datetime openTime;
   datetime closeTime;
   int      direction;       // 1=BUY, -1=SELL
   int      levels;
   double   totalLots;
   double   profit;
   double   profitPercent;
   string   closeReason;
};

//+------------------------------------------------------------------+
//| Classe CBasket — gestion centralisée du panier de positions       |
//+------------------------------------------------------------------+
class CBasket
{
private:
   ulong    m_tickets[];
   int      m_direction;          // 1=BUY, -1=SELL, 0=aucun
   datetime m_openTime;
   int      m_levelsOpened;
   bool     m_partialDone;
   bool     m_breakevenActive;
   double   m_beFloorProfit;      // Profit minimum verrouillé après BE

   bool     IsOurPosition(const ulong ticket) const
   {
      if(!PositionSelectByTicket(ticket))
         return false;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         return false;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         return false;
      return true;
   }

   void SyncFromMarket()
   {
      // Resynchroniser la liste interne avec les positions ouvertes
      ulong live[];
      const int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         const ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurPosition(ticket))
            continue;
         const int n = ArraySize(live);
         ArrayResize(live, n + 1);
         live[n] = ticket;
      }

      ArrayResize(m_tickets, 0);
      for(int j = 0; j < ArraySize(live); j++)
      {
         const int k = ArraySize(m_tickets);
         ArrayResize(m_tickets, k + 1);
         m_tickets[k] = live[j];
      }

      if(ArraySize(m_tickets) == 0)
      {
         m_direction = 0;
         m_levelsOpened = 0;
         m_partialDone = false;
         m_breakevenActive = false;
         m_beFloorProfit = 0.0;
         m_openTime = 0;
      }
      else if(m_direction == 0)
      {
         if(PositionSelectByTicket(m_tickets[0]))
         {
            const long type = PositionGetInteger(POSITION_TYPE);
            m_direction = (type == POSITION_TYPE_BUY) ? 1 : -1;
            m_openTime = (datetime)PositionGetInteger(POSITION_TIME);
         }
      }
   }

public:
   CBasket()
   {
      ArrayResize(m_tickets, 0);
      m_direction = 0;
      m_openTime = 0;
      m_levelsOpened = 0;
      m_partialDone = false;
      m_breakevenActive = false;
      m_beFloorProfit = 0.0;
   }

   void Refresh()
   {
      SyncFromMarket();
      m_levelsOpened = ArraySize(m_tickets);
   }

   bool IsActive() const
   {
      return (ArraySize(m_tickets) > 0);
   }

   int Direction() const { return m_direction; }
   int Levels() const { return ArraySize(m_tickets); }
   int LevelsOpenedCount() const { return m_levelsOpened; }
   datetime OpenTime() const { return m_openTime; }
   bool PartialDone() const { return m_partialDone; }
   bool BreakevenActive() const { return m_breakevenActive; }

   void SetPartialDone(const bool v) { m_partialDone = v; }
   void SetBreakevenActive(const bool v, const double floorProfit = 0.0)
   {
      m_breakevenActive = v;
      if(v)
         m_beFloorProfit = floorProfit;
   }

   double TotalLots() const
   {
      double lots = 0.0;
      for(int i = 0; i < ArraySize(m_tickets); i++)
      {
         if(!PositionSelectByTicket(m_tickets[i]))
            continue;
         lots += PositionGetDouble(POSITION_VOLUME);
      }
      return lots;
   }

   double TotalProfit() const
   {
      double pl = 0.0;
      for(int i = 0; i < ArraySize(m_tickets); i++)
      {
         if(!PositionSelectByTicket(m_tickets[i]))
            continue;
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      return pl;
   }

   double AverageOpenPrice() const
   {
      double sumPV = 0.0;
      double sumV  = 0.0;
      for(int i = 0; i < ArraySize(m_tickets); i++)
      {
         if(!PositionSelectByTicket(m_tickets[i]))
            continue;
         const double vol = PositionGetDouble(POSITION_VOLUME);
         const double op  = PositionGetDouble(POSITION_PRICE_OPEN);
         sumPV += op * vol;
         sumV  += vol;
      }
      return (sumV > 0.0) ? (sumPV / sumV) : 0.0;
   }

   double WorstPrice() const
   {
      // Prix le plus défavorable pour ajouter un niveau de grille
      if(!IsActive())
         return 0.0;
      double worst = 0.0;
      for(int i = 0; i < ArraySize(m_tickets); i++)
      {
         if(!PositionSelectByTicket(m_tickets[i]))
            continue;
         const double op = PositionGetDouble(POSITION_PRICE_OPEN);
         if(i == 0)
            worst = op;
         else if(m_direction > 0)
            worst = MathMin(worst, op);
         else
            worst = MathMax(worst, op);
      }
      return worst;
   }

   void RegisterNewLevel(const ulong ticket, const int direction)
   {
      const int n = ArraySize(m_tickets);
      ArrayResize(m_tickets, n + 1);
      m_tickets[n] = ticket;
      if(n == 0)
      {
         m_direction = direction;
         m_openTime = TimeCurrent();
      }
      m_levelsOpened = ArraySize(m_tickets);
   }

   void Reset()
   {
      ArrayResize(m_tickets, 0);
      m_direction = 0;
      m_openTime = 0;
      m_levelsOpened = 0;
      m_partialDone = false;
      m_breakevenActive = false;
      m_beFloorProfit = 0.0;
   }
};

//+------------------------------------------------------------------+
//|                    VARIABLES GLOBALES                             |
//+------------------------------------------------------------------+

CTrade         g_Trade;
CSymbolInfo    g_SymInfo;
CAccountInfo   g_Account;
CPositionInfo  g_PosInfo;
CBasket        g_Basket;

int   g_hRSI  = INVALID_HANDLE;
int   g_hADX  = INVALID_HANDLE;
int   g_hBB   = INVALID_HANDLE;
int   g_hATR  = INVALID_HANDLE;

double   g_StartBalance       = 0.0;
double   g_EquityPeak         = 0.0;
double   g_MaxDrawdownPercent = 0.0;
double   g_DailyStartBalance  = 0.0;
double   g_DailyStartEquity   = 0.0;
datetime g_LastDayChecked     = 0;
bool     g_DailyDDHit         = false;
bool     g_GlobalDDHit        = false;
bool     g_EquityProtectHit   = false;
bool     g_TradingHalted      = false;

datetime g_LastBarTime        = 0;
datetime g_LastGridAddTime    = 0;

// Statistiques Walk-Forward
int      g_TotalBaskets       = 0;
int      g_WinningBaskets     = 0;
int      g_LosingBaskets      = 0;
double   g_TotalBasketProfit  = 0.0;
double   g_BestBasketProfit   = 0.0;
double   g_WorstBasketLoss    = 0.0;

SBasketRecord g_BasketHistory[];
int      g_CSVHeaderWritten   = 0;

const string EA_NAME    = "XAUUSD GridBasket Secure PRO";
const string EA_VERSION = "1.00";

//+------------------------------------------------------------------+
//|                         HELPERS GÉNÉRAUX                          |
//+------------------------------------------------------------------+

string TimestampStr()
{
   return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
}

void LogMsg(const ENUM_LOG_LEVEL level, const string msg)
{
   if((int)level > (int)InpLogLevel)
      return;
   Print("[", TimestampStr(), "] [", EA_NAME, "] ", msg);
}

double BrokerPoint()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(p <= 0.0)
      p = _Point;
   return p;
}

int SymbolDigitsCustom()
{
   const int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return (d > 0) ? d : _Digits;
}

bool SymbolIsGold()
{
   if(!InpStrictXAUOnly)
      return true;
   string s = _Symbol;
   StringToUpper(s);
   return (StringFind(s, "XAU") >= 0 || StringFind(s, "GOLD") >= 0);
}

void SetupTradeFillingMode()
{
   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_Trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_Trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_Trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

double NormalizeLotSize(double lot)
{
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0)
      return lot;

   lot = MathFloor(lot / stepLot + 1e-8) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   const int stepDigits = (int)MathRound(-MathLog10(stepLot));
   return NormalizeDouble(lot, MathMax(0, stepDigits));
}

double GetReferenceBalance()
{
   return (g_StartBalance > 0.0) ? g_StartBalance : g_Account.Balance();
}

double ModeValueToMoney(const ENUM_BASKET_VALUE_MODE mode, const double value)
{
   if(mode == BASKET_MODE_MONEY)
      return value;
   return GetReferenceBalance() * value / 100.0;
}

double CurrentGlobalDrawdownPercent()
{
   const double eq = g_Account.Equity();
   if(g_EquityPeak <= 0.0)
      return 0.0;
   if(eq >= g_EquityPeak)
      return 0.0;
   return (g_EquityPeak - eq) / g_EquityPeak * 100.0;
}

double CurrentDailyDrawdownPercent()
{
   const double eq = g_Account.Equity();
   if(g_DailyStartEquity <= 0.0)
      return 0.0;
   if(eq >= g_DailyStartEquity)
      return 0.0;
   return (g_DailyStartEquity - eq) / g_DailyStartEquity * 100.0;
}

bool IsNightSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int h = dt.hour;

   if(InpNightStartHour <= InpNightEndHour)
      return (h >= InpNightStartHour && h < InpNightEndHour);

   // Session traverse minuit (ex. 22h → 8h)
   return (h >= InpNightStartHour || h < InpNightEndHour);
}

bool SpreadOK()
{
   const long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return ((int)spread <= InpMaxSpreadPoints);
}

bool WaitIndicatorCalculated(const int handle, const int needBars, const int timeoutMs)
{
   const uint t0 = GetTickCount();
   while((int)BarsCalculated(handle) < needBars)
   {
      if(IsStopped())
         return false;
      if((int)(GetTickCount() - t0) > timeoutMs)
         break;
      Sleep(50);
   }
   return ((int)BarsCalculated(handle) >= needBars);
}

//+------------------------------------------------------------------+
//|                    INDICATEURS & SIGNAUX                          |
//+------------------------------------------------------------------+

bool ReadIndicators(double &rsi, double &adx, double &bbUpper, double &bbLower, double &bbMiddle, double &atr)
{
   double bufRSI[], bufADX[], bufBBU[], bufBBL[], bufBBM[], bufATR[];
   ArraySetAsSeries(bufRSI, true);
   ArraySetAsSeries(bufADX, true);
   ArraySetAsSeries(bufBBU, true);
   ArraySetAsSeries(bufBBL, true);
   ArraySetAsSeries(bufBBM, true);
   ArraySetAsSeries(bufATR, true);

   if(CopyBuffer(g_hRSI, 0, 1, 1, bufRSI) != 1) return false;
   if(CopyBuffer(g_hADX, 0, 1, 1, bufADX) != 1) return false;
   if(CopyBuffer(g_hBB, 1, 1, 1, bufBBU) != 1) return false;
   if(CopyBuffer(g_hBB, 2, 1, 1, bufBBL) != 1) return false;
   if(CopyBuffer(g_hBB, 0, 1, 1, bufBBM) != 1) return false;
   if(CopyBuffer(g_hATR, 0, 1, 1, bufATR) != 1) return false;

   rsi      = bufRSI[0];
   adx      = bufADX[0];
   bbUpper  = bufBBU[0];
   bbLower  = bufBBL[0];
   bbMiddle = bufBBM[0];
   atr      = bufATR[0];
   return true;
}

bool PriceNearBB(const double price, const double bbUpper, const double bbLower, const bool forBuy)
{
   const double width = bbUpper - bbLower;
   if(width <= 0.0)
      return false;

   const double proximity = width * InpBB_ProximityPercent / 100.0;
   if(forBuy)
      return (price <= bbLower + proximity);
   return (price >= bbUpper - proximity);
}

// Retourne 1=BUY, -1=SELL, 0=aucun signal
int DetectReversalSignal(const double rsi, const double adx, const double bbUpper, const double bbLower)
{
   g_SymInfo.RefreshRates();
   const double bid = g_SymInfo.Bid();
   const double ask = g_SymInfo.Ask();
   const double mid = (bid + ask) * 0.5;

   if(adx > InpADX_MaxLevel)
   {
      LogMsg(LOG_LEVEL_DEBUG, StringFormat("Signal rejeté: ADX=%.2f > max %.2f", adx, InpADX_MaxLevel));
      return 0;
   }

   // Signal BUY : survente + proximité bande inférieure
   if(rsi <= InpRSI_Oversold && PriceNearBB(mid, bbUpper, bbLower, true))
   {
      LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
         "SIGNAL BUY détecté | RSI=%.2f | ADX=%.2f | Prix=%.5f | BB_L=%.5f",
         rsi, adx, mid, bbLower));
      return 1;
   }

   // Signal SELL : surachat + proximité bande supérieure
   if(rsi >= InpRSI_Overbought && PriceNearBB(mid, bbUpper, bbLower, false))
   {
      LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
         "SIGNAL SELL détecté | RSI=%.2f | ADX=%.2f | Prix=%.5f | BB_U=%.5f",
         rsi, adx, mid, bbUpper));
      return -1;
   }

   return 0;
}

double GetGridDistance(const double atr)
{
   return MathMax(BrokerPoint() * 10.0, atr * InpATR_GridMult);
}

double CalcLotForLevel(const int levelIndex)
{
   // levelIndex : 1 = premier niveau
   double lot = InpBaseLot;
   switch(InpLotProgression)
   {
      case LOT_PROG_FIXED:
         lot = InpBaseLot;
         break;
      case LOT_PROG_LINEAR:
         lot = InpBaseLot + InpLotStep * (levelIndex - 1);
         break;
      case LOT_PROG_MULTIPLY:
         lot = InpBaseLot * MathPow(InpLotMultiplier, levelIndex - 1);
         break;
   }
   return NormalizeLotSize(lot);
}

//+------------------------------------------------------------------+
//|                    GESTION DES ORDRES                             |
//+------------------------------------------------------------------+

bool OpenGridLevel(const int direction, const int levelIndex, const string commentSuffix)
{
   const double lot = CalcLotForLevel(levelIndex);
   if(lot <= 0.0)
   {
      LogMsg(LOG_LEVEL_NORMAL, "Ouverture annulée: lot normalisé invalide");
      return false;
   }

   g_SymInfo.RefreshRates();
   const string cmt = StringFormat("GB_L%d_%s", levelIndex, commentSuffix);
   bool ok = false;

   if(direction > 0)
      ok = g_Trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, cmt);
   else
      ok = g_Trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, cmt);

   if(!ok)
   {
      LogMsg(LOG_LEVEL_NORMAL, StringFormat(
         "Échec ouverture niveau %d | Err=%d | %s",
         levelIndex, GetLastError(), g_Trade.ResultRetcodeDescription()));
      return false;
   }

   // Attendre que la position soit visible sur le marché
   Sleep(100);
   g_Basket.Refresh();

   LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
      "NIVEAU OUVERT #%d | Dir=%s | Lot=%.4f | Niveaux panier=%d",
      levelIndex, (direction > 0 ? "BUY" : "SELL"), lot, g_Basket.Levels()));

   return true;
}

bool ClosePositionByTicket(const ulong ticket, const double volumeToClose = 0.0)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   const double vol = PositionGetDouble(POSITION_VOLUME);
   double closeVol = (volumeToClose > 0.0) ? volumeToClose : vol;
   closeVol = NormalizeLotSize(MathMin(closeVol, vol));
   if(closeVol <= 0.0)
      return false;

   return g_Trade.PositionClosePartial(ticket, closeVol);
}

bool CloseAllBasketPositions(const string reason)
{
   g_Basket.Refresh();
   if(!g_Basket.IsActive())
      return true;

   const double profitBefore = g_Basket.TotalProfit();
   const int dir = g_Basket.Direction();
   const int levels = g_Basket.Levels();
   const double lots = g_Basket.TotalLots();
   const datetime openT = g_Basket.OpenTime();

   LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
      "FERMETURE PANIER | Raison=%s | P/L=%.2f | Niveaux=%d",
      reason, profitBefore, levels));

   // Collecter tickets (fermer en ordre inverse pour éviter index shift)
   ulong tickets[];
   const int n = PositionsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      const int k = ArraySize(tickets);
      ArrayResize(tickets, k + 1);
      tickets[k] = t;
   }

   bool allOk = true;
   for(int j = ArraySize(tickets) - 1; j >= 0; j--)
   {
      if(!g_Trade.PositionClose(tickets[j]))
      {
         LogMsg(LOG_LEVEL_NORMAL, StringFormat("Échec fermeture ticket %I64u | %s",
            tickets[j], g_Trade.ResultRetcodeDescription()));
         allOk = false;
      }
   }

   // Enregistrer statistiques
   const double refBal = GetReferenceBalance();
   const double profitPct = (refBal > 0.0) ? (profitBefore / refBal * 100.0) : 0.0;

   g_TotalBaskets++;
   g_TotalBasketProfit += profitBefore;
   if(profitBefore >= 0.0)
   {
      g_WinningBaskets++;
      if(profitBefore > g_BestBasketProfit)
         g_BestBasketProfit = profitBefore;
   }
   else
   {
      g_LosingBaskets++;
      if(profitBefore < g_WorstBasketLoss)
         g_WorstBasketLoss = profitBefore;
   }

   SBasketRecord rec;
   rec.openTime       = openT;
   rec.closeTime      = TimeCurrent();
   rec.direction      = dir;
   rec.levels         = levels;
   rec.totalLots      = lots;
   rec.profit         = profitBefore;
   rec.profitPercent  = profitPct;
   rec.closeReason    = reason;

   const int rh = ArraySize(g_BasketHistory);
   ArrayResize(g_BasketHistory, rh + 1);
   g_BasketHistory[rh] = rec;

   ExportBasketToCSV(rec);
   g_Basket.Reset();

   LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
      "Panier fermé | P/L=%.2f (%.3f%%) | WinRate=%.1f%%",
      profitBefore, profitPct,
      (g_TotalBaskets > 0) ? (100.0 * g_WinningBaskets / g_TotalBaskets) : 0.0));

   return allOk;
}

bool PartialCloseBasket(const double percent)
{
   g_Basket.Refresh();
   if(!g_Basket.IsActive())
      return false;

   LogMsg(LOG_LEVEL_VERBOSE, StringFormat("PARTIAL CLOSE %.1f%% | P/L actuel=%.2f",
      percent, g_Basket.TotalProfit()));

   ulong tickets[];
   for(int i = 0; i < PositionsTotal(); i++)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      const int k = ArraySize(tickets);
      ArrayResize(tickets, k + 1);
      tickets[k] = t;
   }

   bool ok = true;
   for(int j = 0; j < ArraySize(tickets); j++)
   {
      if(!PositionSelectByTicket(tickets[j]))
         continue;
      const double vol = PositionGetDouble(POSITION_VOLUME);
      double closeVol = NormalizeLotSize(vol * percent / 100.0);
      const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(closeVol < minLot)
         closeVol = minLot;
      if(closeVol >= vol)
         ok = g_Trade.PositionClose(tickets[j]) && ok;
      else
         ok = g_Trade.PositionClosePartial(tickets[j], closeVol) && ok;
   }

   g_Basket.SetPartialDone(true);
   g_Basket.Refresh();
   return ok;
}

//+------------------------------------------------------------------+
//|                    PROTECTION & SÉCURITÉ                          |
//+------------------------------------------------------------------+

void CheckDailyReset()
{
   MqlDateTime nowDt, lastDt;
   TimeToStruct(TimeCurrent(), nowDt);
   TimeToStruct(g_LastDayChecked, lastDt);

   if(nowDt.day == lastDt.day && nowDt.mon == lastDt.mon && nowDt.year == lastDt.year)
      return;

   LogMsg(LOG_LEVEL_VERBOSE, "── Reset journalier ──");
   g_DailyStartBalance = g_Account.Balance();
   g_DailyStartEquity  = g_Account.Equity();
   g_DailyDDHit        = false;
   g_LastDayChecked    = TimeCurrent();

   // Réinitialiser halt journalier (pas equity protect global)
   if(!g_EquityProtectHit && !g_GlobalDDHit)
      g_TradingHalted = false;
}

bool UpdateEquityPeakAndDD()
{
   const double eq = g_Account.Equity();
   if(eq > g_EquityPeak)
      g_EquityPeak = eq;

   const double dd = CurrentGlobalDrawdownPercent();
   if(dd > g_MaxDrawdownPercent)
      g_MaxDrawdownPercent = dd;

   if(dd >= InpMaxGlobalDD_Percent)
   {
      if(!g_GlobalDDHit)
      {
         LogMsg(LOG_LEVEL_NORMAL, StringFormat(
            "ALERTE DD GLOBAL %.2f%% >= seuil %.2f%% — trading stoppé",
            dd, InpMaxGlobalDD_Percent));
         g_GlobalDDHit = true;
         g_TradingHalted = true;
      }
      return false;
   }
   return true;
}

bool CheckDailyDrawdown()
{
   const double dailyDD = CurrentDailyDrawdownPercent();
   if(dailyDD < InpDailyMaxDD_Percent)
      return true;

   if(!g_DailyDDHit)
   {
      LogMsg(LOG_LEVEL_NORMAL, StringFormat(
         "ALERTE DD JOURNALIER %.2f%% >= seuil %.2f%%",
         dailyDD, InpDailyMaxDD_Percent));
      g_DailyDDHit = true;
   }

   switch(InpDailyDD_Action)
   {
      case DAILY_DD_BLOCK_ENTRIES:
         return false;

      case DAILY_DD_CLOSE_BASKET:
         if(g_Basket.IsActive())
            CloseAllBasketPositions("DailyMaxDD_CloseBasket");
         g_TradingHalted = true;
         return false;

      case DAILY_DD_STOP_EA:
         if(g_Basket.IsActive())
            CloseAllBasketPositions("DailyMaxDD_StopEA");
         g_TradingHalted = true;
         return false;
   }
   return false;
}

bool CheckEquityProtection()
{
   if(!InpEnableEquityProtect)
      return true;

   const double eq = g_Account.Equity();
   double threshold = 0.0;

   if(InpEquityProtectMode == EQUITY_PROTECT_PERCENT)
      threshold = GetReferenceBalance() * InpEquityProtectValue / 100.0;
   else
      threshold = InpEquityProtectValue;

   if(eq >= threshold)
      return true;

   if(!g_EquityProtectHit)
   {
      LogMsg(LOG_LEVEL_NORMAL, StringFormat(
         "EQUITY PROTECTION déclenchée | Equity=%.2f < Seuil=%.2f",
         eq, threshold));
      g_EquityProtectHit = true;
      g_TradingHalted = true;
   }

   if(g_Basket.IsActive())
      CloseAllBasketPositions("EquityProtection");

   return false;
}

bool RunSafetyChecks()
{
   CheckDailyReset();
   if(!UpdateEquityPeakAndDD())
      return false;
   if(!CheckEquityProtection())
      return false;
   if(!CheckDailyDrawdown())
      return false;
   if(g_TradingHalted)
      return false;
   if(!SpreadOK())
   {
      LogMsg(LOG_LEVEL_DEBUG, "Spread trop élevé — tick ignoré");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//|                    GESTION DU PANIER                              |
//+------------------------------------------------------------------+

void ManageBasket()
{
   g_Basket.Refresh();
   if(!g_Basket.IsActive())
      return;

   const double pl = g_Basket.TotalProfit();
   const double tpTarget = ModeValueToMoney(InpBasketTP_Mode, InpBasketTP_Value);
   const double slTarget = ModeValueToMoney(InpBasketSL_Mode, InpBasketSL_Value);

   LogMsg(LOG_LEVEL_DEBUG, StringFormat(
      "P/L Panier=%.2f | TP=%.2f | SL=-%.2f | Niveaux=%d | Lots=%.2f",
      pl, tpTarget, slTarget, g_Basket.Levels(), g_Basket.TotalLots()));

   // Basket Breakeven : verrouiller à zéro une fois le seuil atteint
   if(InpEnableBasketBE && !g_Basket.BreakevenActive())
   {
      const double beTrigger = ModeValueToMoney(InpBasketBE_Mode, InpBasketBE_Value);
      if(pl >= beTrigger)
      {
         g_Basket.SetBreakevenActive(true, 0.0);
         LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
            "BASKET BREAKEVEN activé | P/L=%.2f >= seuil %.2f", pl, beTrigger));
      }
   }

   // Partial close intermédiaire
   if(InpEnablePartialClose && !g_Basket.PartialDone())
   {
      const double partialTarget = ModeValueToMoney(InpPartialTP_Mode, InpPartialTP_Value);
      if(pl >= partialTarget)
      {
         PartialCloseBasket(InpPartialClosePercent);
         LogMsg(LOG_LEVEL_VERBOSE, "Partial close exécuté au objectif intermédiaire");
      }
   }

   // Basket TP
   if(pl >= tpTarget)
   {
      CloseAllBasketPositions("BasketTP");
      return;
   }

   // Basket SL (perte)
   if(pl <= -slTarget)
   {
      CloseAllBasketPositions("BasketSL");
      return;
   }

   // Breakeven strict : fermer si profit repasse sous 0 après activation BE
   if(g_Basket.BreakevenActive() && pl <= 0.0)
   {
      CloseAllBasketPositions("BasketBE_Zero");
      return;
   }
}

bool ShouldAddGridLevel(const double atr)
{
   g_Basket.Refresh();
   if(!g_Basket.IsActive())
      return false;
   if(g_Basket.Levels() >= InpGridMaxLevels)
      return false;

   // Éviter ajouts trop rapprochés dans le temps (min 1 barre SignalTF)
   const datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(g_LastGridAddTime == barTime && g_Basket.Levels() > 1)
      return false;

   const double gridDist = GetGridDistance(atr);
   g_SymInfo.RefreshRates();
   const double bid = g_SymInfo.Bid();
   const double ask = g_SymInfo.Ask();
   const double worst = g_Basket.WorstPrice();
   const int dir = g_Basket.Direction();

   if(dir > 0)
   {
      // BUY grid : ajouter si prix descend sous le pire niveau - distance
      if(bid <= worst - gridDist)
         return true;
   }
   else if(dir < 0)
   {
      // SELL grid : ajouter si prix monte au-dessus du pire niveau + distance
      if(ask >= worst + gridDist)
         return true;
   }
   return false;
}

void TryAddGridLevel(const double atr)
{
   if(!ShouldAddGridLevel(atr))
      return;

   const int nextLevel = g_Basket.Levels() + 1;
   const int dir = g_Basket.Direction();
   if(OpenGridLevel(dir, nextLevel, "GRID"))
      g_LastGridAddTime = iTime(_Symbol, InpSignalTF, 0);
}

//+------------------------------------------------------------------+
//|                    ENTRÉES & NOUVELLE BARRE                       |
//+------------------------------------------------------------------+

void OnNewBar()
{
   LogMsg(LOG_LEVEL_DEBUG, "──── Nouvelle barre SignalTF ────");

   if(!RunSafetyChecks())
      return;

   g_Basket.Refresh();

   double rsi, adx, bbU, bbL, bbM, atr;
   if(!ReadIndicators(rsi, adx, bbU, bbL, bbM, atr))
   {
      LogMsg(LOG_LEVEL_NORMAL, "Lecture indicateurs échouée");
      return;
   }

   // Gestion panier existant : ajout niveaux grille
   if(g_Basket.IsActive())
   {
      ManageBasket();
      if(g_Basket.IsActive())
         TryAddGridLevel(atr);
      return;
   }

   // Pas de panier actif → chercher nouvelle entrée
   if(!IsNightSession())
   {
      LogMsg(LOG_LEVEL_DEBUG, "Hors session nocturne — pas de nouvelle entrée");
      return;
   }

   const int signal = DetectReversalSignal(rsi, adx, bbU, bbL);
   if(signal == 0)
      return;

   LogMsg(LOG_LEVEL_VERBOSE, StringFormat(
      "Ouverture panier initial | Dir=%s | ATR=%.5f | GridDist=%.5f",
      (signal > 0 ? "BUY" : "SELL"), atr, GetGridDistance(atr)));

   OpenGridLevel(signal, 1, "INIT");
}

//+------------------------------------------------------------------+
//|                    EXPORT CSV WALK-FORWARD                        |
//+------------------------------------------------------------------+

void EnsureCSVHeader()
{
   if(!InpExportCSV || g_CSVHeaderWritten != 0)
      return;

   const string path = InpCSVFileName;
   int handle = FileOpen(path, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle != INVALID_HANDLE)
   {
      FileClose(handle);
      g_CSVHeaderWritten = 1;
      return;
   }

   handle = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      LogMsg(LOG_LEVEL_NORMAL, "Impossible de créer CSV: " + InpCSVFileName);
      return;
   }

   FileWrite(handle,
      "OpenTime", "CloseTime", "Direction", "Levels", "TotalLots",
      "Profit", "ProfitPercent", "CloseReason", "Balance", "Equity");
   FileClose(handle);
   g_CSVHeaderWritten = 1;
}

void ExportBasketToCSV(const SBasketRecord &rec)
{
   if(!InpExportCSV)
      return;

   EnsureCSVHeader();

   const int handle = FileOpen(InpCSVFileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      LogMsg(LOG_LEVEL_NORMAL, "Export CSV échoué: " + InpCSVFileName);
      return;
   }

   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
      TimeToString(rec.openTime, TIME_DATE | TIME_SECONDS),
      TimeToString(rec.closeTime, TIME_DATE | TIME_SECONDS),
      (rec.direction > 0 ? "BUY" : "SELL"),
      IntegerToString(rec.levels),
      DoubleToString(rec.totalLots, 4),
      DoubleToString(rec.profit, 2),
      DoubleToString(rec.profitPercent, 4),
      rec.closeReason,
      DoubleToString(g_Account.Balance(), 2),
      DoubleToString(g_Account.Equity(), 2));
   FileClose(handle);

   LogMsg(LOG_LEVEL_DEBUG, "Ligne CSV exportée | Raison=" + rec.closeReason);
}

//+------------------------------------------------------------------+
//|                    AFFICHAGE GRAPHIQUE                            |
//+------------------------------------------------------------------+

void UpdateChartComment()
{
   g_Basket.Refresh();

   const double eq = g_Account.Equity();
   const double bal = g_Account.Balance();
   const double gdd = CurrentGlobalDrawdownPercent();
   const double ddd = CurrentDailyDrawdownPercent();
   const double pl = g_Basket.IsActive() ? g_Basket.TotalProfit() : 0.0;

   string dirStr = "—";
   if(g_Basket.IsActive())
      dirStr = (g_Basket.Direction() > 0) ? "BUY" : "SELL";

   const string txt = StringFormat(
      "%s v%s\n"
      "─────────────────────────\n"
      "Balance: %.2f | Equity: %.2f\n"
      "DD Global: %.2f%% (max %.2f%%) | DD Jour: %.2f%%\n"
      "Session: %s | Spread: %d pts\n"
      "─────────────────────────\n"
      "Panier: %s | Niveaux: %d/%d\n"
      "P/L Panier: %.2f | Lots: %.2f\n"
      "Partial: %s | BE: %s\n"
      "─────────────────────────\n"
      "Paniers: %d | Win: %d | Loss: %d\n"
      "WinRate: %.1f%% | P/L cumulé: %.2f\n"
      "Trading: %s",
      EA_NAME, EA_VERSION,
      bal, eq,
      gdd, g_MaxDrawdownPercent, ddd,
      (IsNightSession() ? "NUIT" : "JOUR"), (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      dirStr, g_Basket.Levels(), InpGridMaxLevels,
      pl, g_Basket.IsActive() ? g_Basket.TotalLots() : 0.0,
      (g_Basket.PartialDone() ? "OUI" : "NON"),
      (g_Basket.BreakevenActive() ? "ACTIF" : "NON"),
      g_TotalBaskets, g_WinningBaskets, g_LosingBaskets,
      (g_TotalBaskets > 0) ? (100.0 * g_WinningBaskets / g_TotalBaskets) : 0.0,
      g_TotalBasketProfit,
      (g_TradingHalted ? "HALT" : "ACTIF"));

   Comment(txt);
}

//+------------------------------------------------------------------+
//|                    ÉVÉNEMENTS MT5                                 |
//+------------------------------------------------------------------+

int OnInit()
{
   if(!SymbolIsGold())
   {
      Alert(EA_NAME + " | ERREUR: symbole non-or — désactiver InpStrictXAUOnly pour tests");
      return INIT_FAILED;
   }

   g_hRSI = iRSI(_Symbol, InpSignalTF, InpRSI_Period, PRICE_CLOSE);
   g_hADX = iADX(_Symbol, InpSignalTF, InpADX_Period);
   g_hBB  = iBands(_Symbol, InpSignalTF, InpBB_Period, 0, InpBB_Deviation, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, InpSignalTF, InpATR_Period);

   if(g_hRSI == INVALID_HANDLE || g_hADX == INVALID_HANDLE ||
      g_hBB == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Alert(EA_NAME + " | ERREUR: création handles indicateurs");
      return INIT_FAILED;
   }

   SymbolSelect(_Symbol, true);

   if(!WaitIndicatorCalculated(g_hRSI, InpRSI_Period + 5, 10000))
      LogMsg(LOG_LEVEL_NORMAL, "RSI: calcul incomplet — vérifier historique");
   if(!WaitIndicatorCalculated(g_hADX, InpADX_Period + 5, 10000))
      LogMsg(LOG_LEVEL_NORMAL, "ADX: calcul incomplet — vérifier historique");
   if(!WaitIndicatorCalculated(g_hBB, InpBB_Period + 5, 10000))
      LogMsg(LOG_LEVEL_NORMAL, "BB: calcul incomplet — vérifier historique");
   if(!WaitIndicatorCalculated(g_hATR, InpATR_Period + 5, 10000))
      LogMsg(LOG_LEVEL_NORMAL, "ATR: calcul incomplet — vérifier historique");

   g_Trade.SetExpertMagicNumber(InpMagicNumber);
   g_Trade.SetDeviationInPoints(InpSlippagePoints);
   SetupTradeFillingMode();

   g_SymInfo.Name(_Symbol);
   g_SymInfo.Refresh();

   g_StartBalance      = g_Account.Balance();
   g_EquityPeak        = g_Account.Equity();
   g_DailyStartBalance = g_StartBalance;
   g_DailyStartEquity  = g_Account.Equity();
   g_LastDayChecked    = TimeCurrent();

   g_Basket.Refresh();
   EnsureCSVHeader();

   LogMsg(LOG_LEVEL_NORMAL, "══════════════════════════════════════════════════════");
   LogMsg(LOG_LEVEL_NORMAL, EA_NAME + " v" + EA_VERSION + " | Initialisé");
   LogMsg(LOG_LEVEL_NORMAL, StringFormat(
      "Symbole=%s | ChartTF=%s | SignalTF=%s | Digits=%d",
      _Symbol, EnumToString(_Period), EnumToString(InpSignalTF), SymbolDigitsCustom()));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat(
      "Balance=%.2f | Lot min=%.4f step=%.4f | BasketTP=%.4f | BasketSL=%.4f",
      g_StartBalance,
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
      InpBasketTP_Value, InpBasketSL_Value));
   LogMsg(LOG_LEVEL_NORMAL, "══════════════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hADX != INVALID_HANDLE) IndicatorRelease(g_hADX);
   if(g_hBB != INVALID_HANDLE)  IndicatorRelease(g_hBB);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);

   Comment("");

   const double winRate = (g_TotalBaskets > 0) ?
      (100.0 * g_WinningBaskets / g_TotalBaskets) : 0.0;
   const double netProfit = g_Account.Balance() - g_StartBalance;
   const double netPct = (g_StartBalance > 0.0) ?
      (netProfit / g_StartBalance * 100.0) : 0.0;

   LogMsg(LOG_LEVEL_NORMAL, "══════════════════════════════════════════════════════");
   LogMsg(LOG_LEVEL_NORMAL, "RÉSUMÉ WALK-FORWARD — OnDeinit");
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("Raison arrêt: %d", reason));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("Balance initiale: %.2f | Finale: %.2f", g_StartBalance, g_Account.Balance()));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("Profit net: %.2f (%.2f%%)", netProfit, netPct));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("Max Drawdown observé: %.2f%% (seuil %.2f%%)", g_MaxDrawdownPercent, InpMaxGlobalDD_Percent));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("Paniers totaux: %d | Gagnants: %d | Perdants: %d", g_TotalBaskets, g_WinningBaskets, g_LosingBaskets));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("WinRate paniers: %.1f%%", winRate));
   LogMsg(LOG_LEVEL_NORMAL, StringFormat("P/L cumulé paniers: %.2f | Meilleur: %.2f | Pire: %.2f", g_TotalBasketProfit, g_BestBasketProfit, g_WorstBasketLoss));
   if(InpExportCSV)
      LogMsg(LOG_LEVEL_NORMAL, "Export CSV: " + InpCSVFileName + " (dossier MQL5/Files)");
   LogMsg(LOG_LEVEL_NORMAL, "══════════════════════════════════════════════════════");
}

void OnTick()
{
   // Mise à jour DD en continu (chaque tick)
   UpdateEquityPeakAndDD();
   CheckDailyReset();

   if(g_Basket.IsActive())
   {
      ManageBasket();
      if(g_Basket.IsActive())
      {
         double rsi, adx, bbU, bbL, bbM, atr;
         if(ReadIndicators(rsi, adx, bbU, bbL, bbM, atr))
         {
            if(RunSafetyChecks())
               TryAddGridLevel(atr);
         }
      }
   }

   datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(barTime != g_LastBarTime)
   {
      g_LastBarTime = barTime;
      OnNewBar();
   }

   UpdateChartComment();
}

//+------------------------------------------------------------------+
//| OnTester — critères d'optimisation intelligents                   |
//+------------------------------------------------------------------+
double OnTester()
{
   const double profit     = TesterStatistics(STAT_PROFIT);
   const double grossProf  = TesterStatistics(STAT_GROSS_PROFIT);
   const double grossLoss  = TesterStatistics(STAT_GROSS_LOSS);
   const double maxDD      = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   const double trades     = TesterStatistics(STAT_TRADES);
   const double pf         = (grossLoss != 0.0) ? (grossProf / MathAbs(grossLoss)) : (grossProf > 0.0 ? 10.0 : 0.0);
   const double recovery   = (maxDD > 0.0) ? (profit / maxDD) : profit;
   const double sharpe     = TesterStatistics(STAT_SHARPE_RATIO);

   // Score de base : Profit Factor pondéré par drawdown
   double score = pf * (1.0 - maxDD / 100.0);

   // Pénalité forte si DD > 3% (objectif principal)
   if(maxDD > 3.0)
      score *= MathMax(0.05, 1.0 - (maxDD - 3.0) / 10.0);

   // Pénalité si DD > seuil paramétré
   if(maxDD > InpMaxGlobalDD_Percent)
      score *= 0.25;

   // Bonus recovery factor
   if(recovery > 1.0)
      score *= (1.0 + MathMin(recovery, 5.0) * 0.05);

   // Bonus Sharpe modéré
   if(sharpe > 0.0)
      score *= (1.0 + MathMin(sharpe, 3.0) * 0.03);

   // Pénalité peu de trades (robustesse WF)
   if(trades < 10.0)
      score *= 0.5;

   // Pénalité profit négatif
   if(profit <= 0.0)
      score *= 0.1;

   LogMsg(LOG_LEVEL_DEBUG, StringFormat(
      "OnTester | PF=%.2f | MaxDD=%.2f%% | Recovery=%.2f | Score=%.4f",
      pf, maxDD, recovery, score));

   return score;
}

//+------------------------------------------------------------------+
