//+------------------------------------------------------------------+
//|                          InstitutionalGold_SMC_PropFirm_v1.mq5   |
//|                        Version 1.00 — Mai 2026                   |
//|                                                                  |
//|  Auteur / Author : Institutional Trading Lab (fictif)            |
//|                                                                  |
//|  DESCRIPTION (FR) :                                               |
//|  Expert Advisor professionnel XAUUSD orienté prop firm (FTMO,    |
//|  FundedNext, The5ers, etc.). Stratégie Smart Money Concepts      |
//|  (ICT/SMC) sélective : biais EMA200 timeframe supérieur (H4/D1), |
//|  entrées sur M5/M15 avec confluence minimale 4/6 (Order Block,  |
//|  FVG, sweep de liquidité, displacement, kill zones London/NY,  |
//|  momentum RSI + expansion ATR). Gestion risque stricte : risque  |
//|  par trade configurable, limite de trades/jour, plafond de     |
//|  perte journalière avec fermeture globale, filtre spread et     |
//|  news. Breakeven à +1R, trailing optionnel, sorties anticipées    |
//|  si FVG adverse ou cassure de structure.                         |
//|                                                                  |
//|  DESCRIPTION (EN):                                              |
//|  Professional XAUUSD EA for prop firms using SMC/ICT-style       |
//|  confluence (HTF EMA200 bias, OB, FVG, liquidity sweep,          |
//|  displacement, session kill zones, RSI+ATR momentum). Strict     |
//|  risk controls, news/spread filters, logging and chart zones.    |
//+------------------------------------------------------------------+
#property copyright "Institutional Trading Lab 2026"
#property link      ""
#property version   "1.00"
#property description "InstitutionalGold_SMC_PropFirm_v1 — SMC/ICT XAUUSD, prop-firm risk"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs — Risk / Risque                                           |
//+------------------------------------------------------------------+
input group "══ RISK — Prop firm / Risque prop ══"
input double   RiskPercent               = 0.50;    // Risk per trade % balance (clamped 0.1–1.0) / Risque %
input int      MaxTradesPerDay           = 2;       // Max trades per day / Trades max/jour
input double   DailyLossLimitPercent     = 4.0;    // Daily loss from day-start equity, halt / Perte jour %
input double   MaxDailyDrawdownPercent   = 4.0;    // Max DD vs day-start equity (prop) / DD max vs début
input double   MaxIntradayDDFromPeakPct  = 5.0;    // DD from intraday equity peak / DD depuis pic jour
input bool     CloseAllOnDailyLimit      = true;   // Close all EA positions if limit hit / Fermer tout
input ulong    MagicNumber               = 2026051401; // Unique magic / Numéro magique
input bool     StrictSymbolWhitelist     = true;    // Only XAU/GOLD symbols / Or seulement

//+------------------------------------------------------------------+
//| Inputs — Strategy / Stratégie                                    |
//+------------------------------------------------------------------+
input group "══ STRATEGY — SMC core / Cœur SMC ══"
input ENUM_TIMEFRAMES BiasTimeframe       = PERIOD_H4; // HTF for EMA200 / TF biais (H4 ou D1)
input ENUM_TIMEFRAMES SignalTimeframe     = PERIOD_M15; // Entry TF M5 or M15 / TF signal
input int      EMA_Period_Bias           = 200;
input int      RSI_Period                = 14;
input int      ATR_Period                = 14;
input int      SwingLookbackMin          = 20;      // Min bars swing window / Fenêtre swing min
input int      SwingLookbackMax          = 50;      // Max bars swing window / Fenêtre swing max
input int      OB_MaxAge_Bars            = 48;      // Max age order block / Âge max OB
input double   OB_BodyRatio              = 0.42;    // OB candle body/range / Ratio corps OB
input double   ImpulseBodyRatio          = 0.55;    // Displacement body/range / Ratio displacement
input double   ImpulseMinATRMult         = 0.85;    // Displacement candle >= ATR * k / Impulsion min vs ATR
input int      FVG_LookbackBars          = 80;      // Scan FVG / Recherche FVG
input int      MinConfluenceRequired     = 4;      // Minimum 4 of 6 / Confluence min (sur 6)
input double   MinRR                     = 2.0;    // Minimum reward:risk / RR minimum
input double   ATRMultiplierSL           = 1.5;    // Extra SL buffer vs ATR / Tampon SL x ATR
input double   SL_BufferPoints           = 30.0;   // Min SL distance points / Distance min SL (pts)

//+------------------------------------------------------------------+
//| Inputs — Trade management / Gestion du trade                     |
//+------------------------------------------------------------------+
input group "══ TRADE MGMT — BE, trail, early exit ══"
input bool     UseBreakeven              = true;
input double   BreakevenAtR            = 1.0;      // Move SL to BE after +1R / BE après +1R
input bool     UseTrailing               = true;
input double   TrailingStartR            = 1.0;      // Start trail after R / Début trail (R)
input double   Trail_ATR_Mult            = 0.75;    // Trail distance = ATR * k / Distance trail ATR
input bool     UseSwingTrail             = false;   // Alternative: trail under/above swings / Trail swings
input bool     EarlyExit_OppositeFVG     = true;    // Close if mitigates opposing FVG / Sortie FVG opposé
input bool     EarlyExit_StructureBreak  = true;    // Close on BOS against / Sortie cassure structure
input int      StructureSwingBars        = 5;       // Bars for structure / Structure courte

//+------------------------------------------------------------------+
//| Inputs — Sessions (SERVER time) / Sessions (heure SERVEUR)      |
//+------------------------------------------------------------------+
input group "══ SESSIONS — Kill zones (broker server) ══"
input bool     LondonKillZone            = true;
input int      LondonStartHour           = 7;       // Server hour / Heure serveur début London
input int      LondonStartMinute         = 0;
input int      LondonEndHour             = 11;
input int      LondonEndMinute           = 0;
input bool     NYKillZone                = true;
input int      NYStartHour               = 13;
input int      NYStartMinute             = 30;
input int      NYEndHour                 = 17;
input int      NYEndMinute               = 0;

//+------------------------------------------------------------------+
//| Inputs — Filters / Filtres                                       |
//+------------------------------------------------------------------+
input group "══ FILTERS — Spread, news / Spread, news ══"
input bool     UseNewsFilter             = true;
input int      NewsBufferMinutes         = 30;      // Before & after / Avant & après (minutes)
input bool     UseNewsExternalFile       = true;    // Read MQL5/Files events CSV / Fichier CSV
input string   NewsEventsFileName        = "InstitutionalGold_NewsEvents.csv"; // Optional / Optionnel
input bool     UseFixedNewsBlackouts     = true;    // Built-in high-impact windows / Fenêtres fixes
input int      SpreadMaxPoints           = 28;      // Max spread (points) XAUUSD / Spread max
input bool     EnableMaxSpread           = true;

//+------------------------------------------------------------------+
//| Inputs — Logging & chart / Journal & graphique                   |
//+------------------------------------------------------------------+
input group "══ LOG & DISPLAY / Affichage ══"
input int      LogLevel                  = 2;       // 1=info 2=warn 3=debug
input bool     EnableExternalLog         = true;
input string   ExternalLogFileName       = "InstitutionalGold_SMC_Log.txt";
input bool     DrawZonesOnChart          = true;
input int      MaxObjectsPerType         = 12;      // Limit chart clutter / Limite objets

//+------------------------------------------------------------------+
//| Data structures / Structures                                     |
//+------------------------------------------------------------------+
struct SBiasHTF
{
   bool     valid;
   int      direction;   // 1 long, -1 short
   double   ema200;
   double   closeRef;
   string   label;
};

struct SOrderBlock
{
   bool     valid;
   bool     bullish;     // true = bullish OB (demand) for longs
   double   obHigh;
   double   obLow;
   int      barIndex;
   datetime obTime;
};

struct SFVGZone
{
   bool     bullish;
   double   zLow;
   double   zHigh;
   int      barIndex;
   bool     mitigated;
};

struct SSwingLevels
{
   double   lastSwingHigh;
   double   lastSwingLow;
   int      shBar;
   int      slBar;
   bool     valid;
};

struct SConfluenceScore
{
   int      score;
   bool     obOk;
   bool     fvgOk;
   bool     sweepOk;
   bool     displacementOk;
   bool     sessionOk;
   bool     momentumOk;
   string   detail;
};

struct SActiveTrade
{
   bool     isOpen;
   ulong    ticket;
   int      direction;
   double   entryPrice;
   double   slInitial;
   double   slCurrent;
   double   tpPrice;
   double   riskDistance;
   double   riskMoney;
   bool     beDone;
   bool     trailActive;
   datetime openTime;
   string   reasonComment;
};

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         Trade;
CSymbolInfo    SymInfo;
CAccountInfo   Account;

int      hEMA_Bias   = INVALID_HANDLE;
int      hATR_Signal = INVALID_HANDLE;
int      hRSI_Signal = INVALID_HANDLE;

string   g_EA_Name    = "InstitutionalGold_SMC_PropFirm_v1";
string   g_EA_Version = "1.00";

double   g_StartBalance        = 0.0;
double   g_DayStartEquity      = 0.0;
double   g_IntradayEquityPeak  = 0.0;
int      g_DailyTradeCount     = 0;
datetime g_LastDayChecked      = 0;
bool     g_DailyHalt           = false;
datetime g_LastSignalBarTime   = 0;

SActiveTrade g_Trade;

// Cached UI / cache affichage
string   g_UI_BiasLabel   = "-";
string   g_UI_Confluence  = "-";
int      g_UI_Score       = 0;

datetime g_NewsRanges[];
// each pair: start, end
int      g_NewsRangeCount = 0;

const string OBJ_PREFIX = "IGSMC_PF1_";

//+------------------------------------------------------------------+
//| Utility — Points broker                                          |
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
   if(!StrictSymbolWhitelist) return true;
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

//+------------------------------------------------------------------+
//| Logging — Experts + fichier / File log                         |
//+------------------------------------------------------------------+
void LogMsg(const int level, const string msg)
{
   if(level > LogLevel) return;
   string prefix = "[LOG] ";
   if(level == 1) prefix = "[INFO] ";
   else if(level == 2) prefix = "[WARN] ";
   else if(level == 3) prefix = "[DBG] ";
   const string line = g_EA_Name + " | " + prefix + msg;
   Print(line);

   if(!EnableExternalLog) return;
   int h = FileOpen(ExternalLogFileName, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " | " + line + "\r\n");
   FileClose(h);
}

//+------------------------------------------------------------------+
//| Chart comment panel / Panneau commentaire graphique             |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   const long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string pos = g_Trade.isOpen ? ((g_Trade.direction == 1 ? "BUY #" : "SELL #") + IntegerToString(g_Trade.ticket)) : "FLAT / plat";

   const double dayPnL = (g_DayStartEquity > 0.0) ? (g_DayStartEquity - Account.Equity()) / g_DayStartEquity * 100.0 : 0.0;

   string txt = "";
   txt += "╔══ " + g_EA_Name + " " + g_EA_Version + " ══╗\n";
   txt += "Bias HTF / Biais : " + g_UI_BiasLabel + "\n";
   txt += "Confluence (last bar) : " + IntegerToString(g_UI_Score) + "/6 | " + g_UI_Confluence + "\n";
   txt += "Trades today / Jour : " + IntegerToString(g_DailyTradeCount) + "/" + IntegerToString(MaxTradesPerDay) +
          " | Halt : " + (g_DailyHalt ? "YES / oui" : "no / non") + "\n";
   txt += "Day DD vs start / DD jour : " + DoubleToString(dayPnL, 2) + "% | Spread : " + IntegerToString(sp) + " pts\n";
   txt += "Position / Position : " + pos + "\n";
   txt += "╚════════════════════════════════════╝";
   Comment(txt);
}

void PrefetchHistory(const ENUM_TIMEFRAMES tf, const int minBars)
{
   datetime t[];
   ArraySetAsSeries(t, true);
   const int n = (int)CopyTime(_Symbol, tf, 0, minBars, t);
   if(n < minBars)
      LogMsg(2, "Prefetch " + EnumToString(tf) + ": " + IntegerToString(n) + "/" + IntegerToString(minBars) +
             " — open chart TF or load history / ouvrez le TF ou chargez l'historique.");
}

bool WaitIndicatorCalculated(const int handle, const int needBars, const int timeoutMs)
{
   const uint t0 = GetTickCount();
   while((int)BarsCalculated(handle) < needBars)
   {
      if(IsStopped()) return false;
      if((int)(GetTickCount() - t0) > timeoutMs) break;
      Sleep(40);
   }
   return ((int)BarsCalculated(handle) >= needBars);
}

//+------------------------------------------------------------------+
//| News — load CSV: YYYY.MM.DD HH:MM;YYYY.MM.DD HH:MM optional      |
//| or single datetime per line for event center                     |
//+------------------------------------------------------------------+
void ClearNewsRanges()
{
   ArrayResize(g_NewsRanges, 0);
   g_NewsRangeCount = 0;
}

void AddNewsRange(const datetime tStart, const datetime tEnd)
{
   const int oldN = ArraySize(g_NewsRanges);
   ArrayResize(g_NewsRanges, oldN + 2);
   g_NewsRanges[oldN + 0] = tStart;
   g_NewsRanges[oldN + 1] = tEnd;
   g_NewsRangeCount += 2;
}

bool ParseDateTimeToken(const string token, datetime &outDt)
{
   string s = token;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(StringLen(s) < 10) return false;
   outDt = StringToTime(s);
   return (outDt > 0);
}

void LoadNewsEventsFromFile()
{
   ClearNewsRanges();
   if(!UseNewsExternalFile) return;

   int h = FileOpen(NewsEventsFileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      LogMsg(3, "News file not found (optional): " + NewsEventsFileName + " / fichier absent (ok)");
      return;
   }

   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      if(StringLen(line) < 8) continue;
      if(StringGetCharacter(line, 0) == '#' || StringGetCharacter(line, 0) == ';') continue;

      string parts[];
      const int n = StringSplit(line, ';', parts);
      datetime tEv = 0;
      if(n >= 1)
      {
         if(!ParseDateTimeToken(parts[0], tEv)) continue;
         datetime t0 = tEv - NewsBufferMinutes * 60;
         datetime t1 = tEv + NewsBufferMinutes * 60;
         AddNewsRange(t0, t1);
      }
   }
   FileClose(h);
   LogMsg(1, "News CSV loaded, blackout windows: " + IntegerToString(g_NewsRangeCount / 2));
}

bool IsInsideNewsRange(const datetime now)
{
   for(int i = 0; i + 1 < ArraySize(g_NewsRanges); i += 2)
   {
      if(now >= g_NewsRanges[i] && now <= g_NewsRanges[i + 1])
         return true;
   }
   return false;
}

// Fixed blackouts (server time approximation for US releases cluster)
// / Fenêtres fixes (approx.) — ajuster selon broker si besoin
bool IsFixedNewsBlackoutServerTime(const datetime now)
{
   if(!UseFixedNewsBlackouts) return false;

   MqlDateTime dt;
   TimeToStruct(now, dt);

   const int dow = dt.day_of_week;
   const int mins = dt.hour * 60 + dt.min;

   // Daily US data window 13:00–15:30 server (often aligns with NY news cluster)
   if(mins >= (13 * 60) && mins < (15 * 60 + 30))
      return true;

   // First Friday NFP-style extended window / Vendredi NFP élargi
   if(dow == 5 && dt.day <= 7 && mins >= (12 * 60 + 30) && mins < (16 * 60))
      return true;

   return false;
}

bool IsNewsBlackout()
{
   if(!UseNewsFilter) return false;
   const datetime now = TimeCurrent();
   if(IsInsideNewsRange(now)) return true;
   if(IsFixedNewsBlackoutServerTime(now)) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Session kill zones — SERVER time / Heure serveur                 |
//+------------------------------------------------------------------+
bool TimeInRange(const datetime now, const int h1, const int m1, const int h2, const int m2)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   const int cur = dt.hour * 60 + dt.min;
   const int a = h1 * 60 + m1;
   const int b = h2 * 60 + m2;
   if(a <= b)
      return (cur >= a && cur < b);
   // overnight wrap (not used for London/NY standard)
   return (cur >= a || cur < b);
}

bool IsSessionKillZone()
{
   bool ok = false;
   if(LondonKillZone)
      ok = ok || TimeInRange(TimeCurrent(), LondonStartHour, LondonStartMinute, LondonEndHour, LondonEndMinute);
   if(NYKillZone)
      ok = ok || TimeInRange(TimeCurrent(), NYStartHour, NYStartMinute, NYEndHour, NYEndMinute);
   return ok;
}

//+------------------------------------------------------------------+
//| HTF Bias EMA200 / Biais EMA200                                   |
//+------------------------------------------------------------------+
SBiasHTF CalculateBiasEMA200()
{
   SBiasHTF b;
   b.valid = false;
   b.direction = 0;
   b.ema200 = 0.0;
   b.closeRef = 0.0;
   b.label = "NEUTRAL / neutre";

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(hEMA_Bias, 0, 1, 1, ema) != 1) return b;

   double cl[];
   ArraySetAsSeries(cl, true);
   if(CopyClose(_Symbol, BiasTimeframe, 1, 1, cl) != 1) return b;

   b.ema200 = ema[0];
   b.closeRef = cl[0];
   if(b.ema200 <= 0.0) return b;

   if(b.closeRef > b.ema200)
   {
      b.direction = 1;
      b.valid = true;
      b.label = "BULL HTF / haussier (close>EMA200)";
   }
   else if(b.closeRef < b.ema200)
   {
      b.direction = -1;
      b.valid = true;
      b.label = "BEAR HTF / baissier (close<EMA200)";
   }
   return b;
}

//+------------------------------------------------------------------+
//| ATR & RSI helpers                                                |
//+------------------------------------------------------------------+
double GetATRSignal(const int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR_Signal, 0, shift, 3, buf) < 3) return 0.0;
   return buf[0];
}

double GetRSISignal(const int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hRSI_Signal, 0, shift, 1, buf) != 1) return 50.0;
   return buf[0];
}

bool ATR_IsExpanding()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR_Signal, 0, 1, 4, buf) < 4) return false;
   // Expansion: ATR[1] > ATR[2] and ATR[1] > SMA(ATR,3) over past / expansion simple
   const double a1 = buf[0];
   const double a2 = buf[1];
   const double a3 = buf[2];
   const double sma3 = (a1 + a2 + a3) / 3.0;
   return (a1 > a2 && a1 >= sma3);
}

//+------------------------------------------------------------------+
//| Swing highs/lows in window / Swings                              |
//+------------------------------------------------------------------+
bool FindRecentSwings(SSwingLevels &sw, const int lookback)
{
   sw.valid = false;
   sw.lastSwingHigh = 0.0;
   sw.lastSwingLow = 0.0;
   sw.shBar = -1;
   sw.slBar = -1;

   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyHigh(_Symbol, SignalTimeframe, 1, lookback, h) < lookback) return false;
   if(CopyLow(_Symbol, SignalTimeframe, 1, lookback, l) < lookback) return false;

   // Most recent swings = smallest bar index (series) / Swings récents = indice minimal
   int bestSH = -1, bestSL = -1;
   for(int i = 2; i < lookback - 2; i++)
   {
      if(h[i] > h[i - 1] && h[i] > h[i + 1] && h[i] > h[i - 2] && h[i] > h[i + 2])
      {
         if(bestSH < 0 || i < bestSH)
         {
            bestSH = i;
            sw.lastSwingHigh = h[i];
            sw.shBar = i;
         }
      }
      if(l[i] < l[i - 1] && l[i] < l[i + 1] && l[i] < l[i - 2] && l[i] < l[i + 2])
      {
         if(bestSL < 0 || i < bestSL)
         {
            bestSL = i;
            sw.lastSwingLow = l[i];
            sw.slBar = i;
         }
      }
   }
   sw.valid = (sw.lastSwingHigh > 0.0 && sw.lastSwingLow > 0.0);
   return sw.valid;
}

//+------------------------------------------------------------------+
//| Liquidity sweep / Sweep liquidité                                |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(const int biasDir, const SSwingLevels &sw, const double atr1)
{
   if(!sw.valid) return false;

   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   const int need = 6;
   if(CopyOpen(_Symbol, SignalTimeframe, 1, need, o) < need) return false;
   if(CopyHigh(_Symbol, SignalTimeframe, 1, need, h) < need) return false;
   if(CopyLow(_Symbol, SignalTimeframe, 1, need, l) < need) return false;
   if(CopyClose(_Symbol, SignalTimeframe, 1, need, c) < need) return false;

   const double eps = atr1 * 0.08;
   if(biasDir == 1)
   {
      // Bull: sweep sell-side liquidity (below swing low) then reclaim
      const double level = sw.lastSwingLow;
      const bool swept = (l[1] < level - eps || l[2] < level - eps);
      const bool reclaim = (c[1] > level);
      return swept && reclaim;
   }
   if(biasDir == -1)
   {
      const double level = sw.lastSwingHigh;
      const bool swept = (h[1] > level + eps || h[2] > level + eps);
      const bool reclaim = (c[1] < level);
      return swept && reclaim;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Order Block detection / Détection Order Block                    |
//+------------------------------------------------------------------+
SOrderBlock DetectOrderBlock(const int biasDir)
{
   SOrderBlock ob;
   ob.valid = false;
   ob.bullish = false;
   ob.obHigh = ob.obLow = 0.0;
   ob.barIndex = -1;
   ob.obTime = 0;

   const int scan = OB_MaxAge_Bars + 8;
   double o[], h[], l[], c[];
   datetime tv[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(tv, true);

   if(CopyOpen(_Symbol, SignalTimeframe, 1, scan, o) < scan) return ob;
   if(CopyHigh(_Symbol, SignalTimeframe, 1, scan, h) < scan) return ob;
   if(CopyLow(_Symbol, SignalTimeframe, 1, scan, l) < scan) return ob;
   if(CopyClose(_Symbol, SignalTimeframe, 1, scan, c) < scan) return ob;
   if(CopyTime(_Symbol, SignalTimeframe, 1, scan, tv) < scan) return ob;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double atr1 = GetATRSignal(1);
   if(atr1 <= 0.0) return ob;

   for(int i = 2; i < OB_MaxAge_Bars && i < scan - 3; i++)
   {
      const double range_i = h[i] - l[i];
      if(range_i <= 0.0) continue;
      const double body = MathAbs(c[i] - o[i]);
      const bool bear = (c[i] < o[i]);
      const bool bull = (c[i] > o[i]);
      const double bratio = body / range_i;

      // Bullish OB for long bias: last down candle before up impulse
      if(biasDir == 1 && bear && bratio >= OB_BodyRatio)
      {
         bool impulse = false;
         for(int j = i - 1; j >= MathMax(1, i - 4); j--)
         {
            const double rj = h[j] - l[j];
            if(rj <= 0.0) continue;
            const double bj = MathAbs(c[j] - o[j]);
            if(c[j] > o[j] && bj / rj >= ImpulseBodyRatio && (c[j] - o[j]) >= ImpulseMinATRMult * atr1)
            {
               impulse = true;
               break;
            }
         }
         if(!impulse) continue;

         const double entryLow = l[i];
         const double entryHigh = l[i] + 0.50 * body;
         if(bid >= entryLow - 2 * _Point && bid <= h[i] + 4 * _Point)
         {
            ob.valid = true;
            ob.bullish = true;
            ob.obLow = l[i];
            ob.obHigh = h[i];
            ob.barIndex = i;
            ob.obTime = tv[i];
            return ob;
         }
      }

      // Bearish OB for short bias
      if(biasDir == -1 && bull && bratio >= OB_BodyRatio)
      {
         bool impulse = false;
         for(int j = i - 1; j >= MathMax(1, i - 4); j--)
         {
            const double rj = h[j] - l[j];
            if(rj <= 0.0) continue;
            const double bj = MathAbs(c[j] - o[j]);
            if(c[j] < o[j] && bj / rj >= ImpulseBodyRatio && (o[j] - c[j]) >= ImpulseMinATRMult * atr1)
            {
               impulse = true;
               break;
            }
         }
         if(!impulse) continue;

         const double entryHigh = h[i];
         const double entryLow = h[i] - 0.50 * body;
         if(ask <= entryHigh + 2 * _Point && ask >= l[i] - 4 * _Point)
         {
            ob.valid = true;
            ob.bullish = false;
            ob.obLow = l[i];
            ob.obHigh = h[i];
            ob.barIndex = i;
            ob.obTime = tv[i];
            return ob;
         }
      }
   }
   return ob;
}

//+------------------------------------------------------------------+
//| FVG — 3-candle imbalance / FVG 3 bougies                         |
//+------------------------------------------------------------------+
bool FindRecentFVG(const int biasDir, SFVGZone &outZone)
{
   outZone.bullish = false;
   outZone.zLow = outZone.zHigh = 0.0;
   outZone.barIndex = -1;
   outZone.mitigated = true;

   double h[], l[];
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   const int n = FVG_LookbackBars;
   if(CopyHigh(_Symbol, SignalTimeframe, 1, n, h) < n) return false;
   if(CopyLow(_Symbol, SignalTimeframe, 1, n, l) < n) return false;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int k = 3; k < n - 1; k++)
   {
      // indices: k = oldest of trio in scan, k-1 middle, k-2 newest of trio? Using classic shift:
      // bull FVG: low[k-2] > high[k]  (series: larger index = older bar)
      const int i0 = k;     // oldest
      const int i1 = k - 1; // mid
      const int i2 = k - 2; // newest of pattern (more recent)

      if(biasDir == 1)
      {
         if(l[i2] > h[i0])
         {
            const double zLow = h[i0];
            const double zHigh = l[i2];
            if(zHigh <= zLow) continue;
            // unmitigated for long: price not filled gap down through zone on recent bars
            bool mitigated = false;
            for(int t = 1; t <= k - 3; t++)
            {
               if(l[t] <= zHigh && h[t] >= zLow)
               {
                  mitigated = true;
                  break;
               }
            }
            if(mitigated) continue;
            // Bullish FVG as support: price above gap / FVG haussier = prix au-dessus du gap
            if(bid <= zHigh + _Point) continue;

            outZone.bullish = true;
            outZone.zLow = zLow;
            outZone.zHigh = zHigh;
            outZone.barIndex = i2;
            outZone.mitigated = false;
            return true;
         }
      }
      else if(biasDir == -1)
      {
         if(h[i2] < l[i0])
         {
            const double zLow = h[i2];
            const double zHigh = l[i0];
            if(zHigh <= zLow) continue;
            bool mitigated = false;
            for(int t = 1; t <= k - 3; t++)
            {
               if(l[t] <= zHigh && h[t] >= zLow)
               {
                  mitigated = true;
                  break;
               }
            }
            if(mitigated) continue;
            // Bearish FVG as resistance: price below gap / FVG baissier = prix sous le gap
            if(ask >= zLow - _Point) continue;

            outZone.bullish = false;
            outZone.zLow = zLow;
            outZone.zHigh = zHigh;
            outZone.barIndex = i2;
            outZone.mitigated = false;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Displacement after interaction / Displacement                    |
//+------------------------------------------------------------------+
bool DetectDisplacement(const int biasDir, const SOrderBlock &ob, const double atr1)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   ArraySetAsSeries(c, true);
   if(CopyOpen(_Symbol, SignalTimeframe, 1, 4, o) < 4) return false;
   if(CopyHigh(_Symbol, SignalTimeframe, 1, 4, h) < 4) return false;
   if(CopyLow(_Symbol, SignalTimeframe, 1, 4, l) < 4) return false;
   if(CopyClose(_Symbol, SignalTimeframe, 1, 4, c) < 4) return false;

   for(int i = 1; i <= 2; i++)
   {
      const double range = h[i] - l[i];
      if(range <= 0.0) continue;
      const double body = MathAbs(c[i] - o[i]);
      if(body / range < ImpulseBodyRatio) continue;

      if(biasDir == 1)
      {
         if(c[i] <= o[i]) continue;
         if((c[i] - o[i]) < ImpulseMinATRMult * atr1) continue;
         // close should leave OB zone upward / clôture au-dessus de la zone OB
         if(c[i] > ob.obHigh - 2 * _Point) return true;
      }
      else
      {
         if(c[i] >= o[i]) continue;
         if((o[i] - c[i]) < ImpulseMinATRMult * atr1) continue;
         if(c[i] < ob.obLow + 2 * _Point) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Momentum confluence / Momentum                                   |
//+------------------------------------------------------------------+
bool MomentumConfluence(const int biasDir)
{
   const double rsi = GetRSISignal(1);
   const bool rsiOk = (biasDir == 1) ? (rsi > 50.0) : (rsi < 50.0);
   const bool atrOk = ATR_IsExpanding();
   return rsiOk && atrOk;
}

//+------------------------------------------------------------------+
//| Confluence aggregator / Agrégat confluence                       |
//+------------------------------------------------------------------+
SConfluenceScore BuildConfluence(const SBiasHTF &bias, const SOrderBlock &ob, const SFVGZone &fvg,
                                 const SSwingLevels &sw, const double atr1)
{
   SConfluenceScore s;
   s.score = 0;
   s.obOk = ob.valid;
   s.fvgOk = fvg.mitigated == false && fvg.zHigh > fvg.zLow;
   s.sweepOk = DetectLiquiditySweep(bias.direction, sw, atr1);
   s.displacementOk = ob.valid ? DetectDisplacement(bias.direction, ob, atr1) : false;
   s.sessionOk = IsSessionKillZone();
   s.momentumOk = MomentumConfluence(bias.direction);

   if(s.obOk) s.score++;
   if(s.fvgOk) s.score++;
   if(s.sweepOk) s.score++;
   if(s.displacementOk) s.score++;
   if(s.sessionOk) s.score++;
   if(s.momentumOk) s.score++;

   s.detail = StringFormat("SC=%d OB=%d FVG=%d SW=%d DISP=%d SES=%d MOM=%d",
                           s.score,
                           (int)s.obOk, (int)s.fvgOk, (int)s.sweepOk,
                           (int)s.displacementOk, (int)s.sessionOk, (int)s.momentumOk);
   return s;
}

//+------------------------------------------------------------------+
//| Chart drawing / Dessin graphique                                 |
//+------------------------------------------------------------------+
void DeleteOldObjectsByPrefix(const string pref, const int maxKeep)
{
   int total = ObjectsTotal(0, 0, -1);
   int count = 0;
   for(int i = total - 1; i >= 0; i--)
   {
      const string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, pref) != 0) continue;
      count++;
      if(count > maxKeep)
         ObjectDelete(0, name);
   }
}

void DrawOrderBlock(const SOrderBlock &ob)
{
   if(!DrawZonesOnChart || !ob.valid) return;
   DeleteOldObjectsByPrefix(OBJ_PREFIX + "OB_", MaxObjectsPerType);

   const string name = OBJ_PREFIX + "OB_" + TimeToString(ob.obTime, TIME_DATE | TIME_MINUTES);
   if(ObjectFind(0, name) >= 0) return;

   const color clr = ob.bullish ? clrDodgerBlue : clrCrimson;
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, ob.obTime, ob.obHigh, TimeCurrent() + PeriodSeconds(SignalTimeframe) * 8, ob.obLow))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
}

void DrawFVG(const SFVGZone &z, const datetime tAnchor)
{
   if(!DrawZonesOnChart || z.zHigh <= z.zLow) return;
   DeleteOldObjectsByPrefix(OBJ_PREFIX + "FVG_", MaxObjectsPerType);

   const string name = OBJ_PREFIX + "FVG_" + TimeToString(tAnchor, TIME_DATE | TIME_MINUTES);
   if(ObjectFind(0, name) >= 0) return;

   const color clr = z.bullish ? clrLime : clrOrangeRed;
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, tAnchor, z.zHigh, TimeCurrent() + PeriodSeconds(SignalTimeframe) * 10, z.zLow))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, false);
}

void DrawLiquidityLines(const SSwingLevels &sw)
{
   if(!DrawZonesOnChart || !sw.valid) return;
   const string hname = OBJ_PREFIX + "LIQ_H";
   const string lname = OBJ_PREFIX + "LIQ_L";

   if(ObjectFind(0, hname) < 0) ObjectCreate(0, hname, OBJ_HLINE, 0, 0, sw.lastSwingHigh);
   else ObjectSetDouble(0, hname, OBJPROP_PRICE, sw.lastSwingHigh);
   ObjectSetInteger(0, hname, OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, hname, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, hname, OBJPROP_WIDTH, 1);

   if(ObjectFind(0, lname) < 0) ObjectCreate(0, lname, OBJ_HLINE, 0, 0, sw.lastSwingLow);
   else ObjectSetDouble(0, lname, OBJPROP_PRICE, sw.lastSwingLow);
   ObjectSetInteger(0, lname, OBJPROP_COLOR, clrMediumOrchid);
   ObjectSetInteger(0, lname, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lname, OBJPROP_WIDTH, 1);
}

//+------------------------------------------------------------------+
//| Lot size / Taille de lot                                         |
//+------------------------------------------------------------------+
double CalculateLotSize(const double slDistancePx)
{
   if(slDistancePx <= 0.0) return 0.0;

   double riskPct = RiskPercent;
   riskPct = MathMax(riskPct, 0.10);
   riskPct = MathMin(riskPct, 1.00);

   const double balance = Account.Balance();
   const double riskMoney = balance * (riskPct / 100.0);
   const double symPt = BrokerPoint();
   const double slPoints = slDistancePx / symPt;

   const double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   const double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSize <= 0.0) return 0.0;

   const double valuePerPt = (tickVal / tickSize) * symPt;
   double rawLot = riskMoney / (slPoints * valuePerPt);

   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = MathFloor(rawLot / lotStep) * lotStep;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return lot;
}

//+------------------------------------------------------------------+
//| Safety: connection, spread, daily limits                       |
//+------------------------------------------------------------------+
bool TerminalConnected()
{
   return (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
}

bool SpreadOK()
{
   if(!EnableMaxSpread) return true;
   const long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (sp <= SpreadMaxPoints);
}

void UpdateIntradayPeakEquity()
{
   const double eq = Account.Equity();
   if(eq > g_IntradayEquityPeak)
      g_IntradayEquityPeak = eq;
}

double DailyLossVsStartPercent()
{
   if(g_DayStartEquity <= 0.0) return 0.0;
   return (g_DayStartEquity - Account.Equity()) / g_DayStartEquity * 100.0;
}

double DrawdownVsDayStartPercent()
{
   if(g_DayStartEquity <= 0.0) return 0.0;
   return (g_DayStartEquity - Account.Equity()) / g_DayStartEquity * 100.0;
}

double DrawdownFromIntradayPeakPercent()
{
   if(g_IntradayEquityPeak <= 0.0) return 0.0;
   return (g_IntradayEquityPeak - Account.Equity()) / g_IntradayEquityPeak * 100.0;
}

void CloseAllOurPositions(const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      Trade.PositionClose(ticket);
      LogMsg(1, "Position closed (risk halt): " + reason + " | #" + IntegerToString(ticket));
   }
   ResetActiveTradeState();
}

bool CheckDailyRiskHalts()
{
   if(g_DailyHalt) return false;

   const double ddDay = DrawdownVsDayStartPercent();
   const double lossDay = DailyLossVsStartPercent();
   const double ddPeak = DrawdownFromIntradayPeakPercent();

   if(lossDay >= DailyLossLimitPercent || ddDay >= MaxDailyDrawdownPercent)
   {
      LogMsg(1, StringFormat("DAILY HALT: loss=%.2f%% (lim %.2f%%) DDvsStart=%.2f%% (lim %.2f%%)",
                              lossDay, DailyLossLimitPercent, ddDay, MaxDailyDrawdownPercent));
      if(CloseAllOnDailyLimit) CloseAllOurPositions("Daily loss / DD limit");
      g_DailyHalt = true;
      return false;
   }

   if(ddPeak >= MaxIntradayDDFromPeakPct)
   {
      LogMsg(1, StringFormat("INTRADAY HALT: DD from peak=%.2f%% (lim %.2f%%)", ddPeak, MaxIntradayDDFromPeakPct));
      if(CloseAllOnDailyLimit) CloseAllOurPositions("Intraday DD from peak");
      g_DailyHalt = true;
      return false;
   }
   return true;
}

void CheckDayRollover()
{
   MqlDateTime nowDt, lastDt;
   TimeToStruct(TimeCurrent(), nowDt);
   TimeToStruct(g_LastDayChecked, lastDt);
   if(nowDt.day != lastDt.day || nowDt.mon != lastDt.mon || nowDt.year != lastDt.year)
   {
      g_DayStartEquity = Account.Equity();
      g_IntradayEquityPeak = g_DayStartEquity;
      g_DailyTradeCount = 0;
      g_DailyHalt = false;
      g_LastDayChecked = TimeCurrent();
      LogMsg(1, "New day reset / Nouveau jour: equity start=" + DoubleToString(g_DayStartEquity, 2));
   }
}

//+------------------------------------------------------------------+
//| Trade state helpers                                              |
//+------------------------------------------------------------------+
void ResetActiveTradeState()
{
   g_Trade.isOpen = false;
   g_Trade.ticket = 0;
   g_Trade.direction = 0;
   g_Trade.entryPrice = 0.0;
   g_Trade.slInitial = 0.0;
   g_Trade.slCurrent = 0.0;
   g_Trade.tpPrice = 0.0;
   g_Trade.riskDistance = 0.0;
   g_Trade.riskMoney = 0.0;
   g_Trade.beDone = false;
   g_Trade.trailActive = false;
   g_Trade.openTime = 0;
   g_Trade.reasonComment = "";
}

void CheckExistingPositionAttach()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      g_Trade.isOpen = true;
      g_Trade.ticket = ticket;
      g_Trade.direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_Trade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_Trade.slCurrent = PositionGetDouble(POSITION_SL);
      g_Trade.tpPrice = PositionGetDouble(POSITION_TP);
      g_Trade.slInitial = g_Trade.slCurrent;
      g_Trade.riskDistance = MathAbs(g_Trade.entryPrice - g_Trade.slInitial);
      g_Trade.openTime = (datetime)PositionGetInteger(POSITION_TIME);
      break;
   }
}

ulong GetOurNewestPositionTicket()
{
   ulong bestTicket = 0;
   datetime bestTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(tm >= bestTime)
      {
         bestTime = tm;
         bestTicket = ticket;
      }
   }
   return bestTicket;
}

ulong PositionTicketFromLastDeal()
{
   const ulong deal = Trade.ResultDeal();
   if(deal == 0) return 0;
   if(!HistoryDealSelect(deal)) return 0;
   return (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
}

ulong ResolveOpenedPositionTicket()
{
   ulong t = GetOurNewestPositionTicket();
   if(t > 0) return t;
   return PositionTicketFromLastDeal();
}

//+------------------------------------------------------------------+
//| SL / TP construction                                             |
//+------------------------------------------------------------------+
bool ComputeStopsAndTargets(const int dir, const SOrderBlock &ob, const SSwingLevels &sw,
                            const double entryPrice, double &slOut, double &tpOut, double &riskDist)
{
   const double pt = BrokerPoint();
   const int regPts = BrokerStopOrFreezePoints();
   const double minDist = (regPts + 8) * pt;
   const double bufPts = SL_BufferPoints * pt;
   const double atr1 = GetATRSignal(1);
   const double atrBuf = atr1 * ATRMultiplierSL;

   double swingExt = 0.0;
   if(dir == 1 && sw.valid)
      swingExt = sw.lastSwingLow - 4 * pt;
   else if(dir == -1 && sw.valid)
      swingExt = sw.lastSwingHigh + 4 * pt;

   if(dir == 1)
   {
      const double slOb = ob.obLow - MathMax(bufPts, atrBuf);
      slOut = slOb;
      if(sw.valid) slOut = MathMin(slOut, swingExt);
      slOut = NormalizeDouble(slOut, _Digits);
      riskDist = entryPrice - slOut;
      if(riskDist < minDist)
      {
         slOut = NormalizeDouble(entryPrice - minDist, _Digits);
         riskDist = entryPrice - slOut;
      }
   }
   else
   {
      const double slOb = ob.obHigh + MathMax(bufPts, atrBuf);
      slOut = slOb;
      if(sw.valid) slOut = MathMax(slOut, swingExt);
      slOut = NormalizeDouble(slOut, _Digits);
      riskDist = slOut - entryPrice;
      if(riskDist < minDist)
      {
         slOut = NormalizeDouble(entryPrice + minDist, _Digits);
         riskDist = slOut - entryPrice;
      }
   }

   if(riskDist <= 0.0) return false;

   // TP: prefer opposite liquidity pool minimal RR / TP: liquidité opposée min RR
   double tpCandidate = 0.0;
   if(dir == 1 && sw.valid)
      tpCandidate = sw.lastSwingHigh;
   else if(dir == -1 && sw.valid)
      tpCandidate = sw.lastSwingLow;

   if(dir == 1)
   {
      const double tpRR = entryPrice + riskDist * MinRR;
      tpOut = MathMax(tpCandidate, tpRR);
      if(tpOut <= entryPrice + riskDist * MinRR)
         tpOut = tpRR;
   }
   else
   {
      const double tpRR = entryPrice - riskDist * MinRR;
      tpOut = MathMin(tpCandidate, tpRR);
      if(tpOut >= entryPrice - riskDist * MinRR)
         tpOut = tpRR;
   }
   tpOut = NormalizeDouble(tpOut, _Digits);

   const double rr = (dir == 1) ? (tpOut - entryPrice) / riskDist : (entryPrice - tpOut) / riskDist;
   if(rr < MinRR - 1e-6)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Order open with retries / Ouverture avec retry                   |
//+------------------------------------------------------------------+
bool OpenMarketOrder(const int dir, const double lot, const double sl, const double tp, const string cmt)
{
   SymInfo.RefreshRates();
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(25);

   for(int attempt = 1; attempt <= 4; attempt++)
   {
      bool ok = false;
      if(dir == 1) ok = Trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt);
      else ok = Trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt);

      if(ok) return true;

      const uint rc = Trade.ResultRetcode();
      LogMsg(2, "Order failed attempt " + IntegerToString(attempt) + " retcode=" + IntegerToString(rc) + " " + Trade.ResultRetcodeDescription());

      if(rc == TRADE_REQUOTE || rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_PRICE_CHANGED)
      {
         Sleep(200 + 100 * attempt);
         SymInfo.RefreshRates();
         continue;
      }
      if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_TRADE_DISABLED)
         break;
      Sleep(150);
   }
   return false;
}

void OpenTradeFromSetup(const SBiasHTF &bias, const SOrderBlock &ob, const SFVGZone &fvg,
                        const SSwingLevels &sw, const SConfluenceScore &cf)
{
   if(g_Trade.isOpen) return;
   if(g_DailyHalt) return;
   if(g_DailyTradeCount >= MaxTradesPerDay) return;

   SymInfo.Name(_Symbol);
   SymInfo.RefreshRates();

   const double ask = SymInfo.Ask();
   const double bid = SymInfo.Bid();
   const int dir = bias.direction;

   double entry = (dir == 1) ? ask : bid;
   double sl = 0.0, tp = 0.0, risk = 0.0;
   if(!ComputeStopsAndTargets(dir, ob, sw, entry, sl, tp, risk)) return;

   const double lot = CalculateLotSize(risk);
   if(lot <= 0.0)
   {
      LogMsg(2, "Lot size zero / lot nul");
      return;
   }

   const string cmt = "IGSMCv1 | " + cf.detail;

   if(!OpenMarketOrder(dir, lot, sl, tp, cmt))
      return;

   g_Trade.isOpen = true;
   g_Trade.ticket = ResolveOpenedPositionTicket();
   g_Trade.direction = dir;
   g_Trade.entryPrice = Trade.ResultPrice();
   g_Trade.slInitial = sl;
   g_Trade.slCurrent = sl;
   g_Trade.tpPrice = tp;
   g_Trade.riskDistance = risk;
   const double rp = MathMin(MathMax(RiskPercent, 0.10), 1.00);
   g_Trade.riskMoney = Account.Balance() * (rp / 100.0);
   g_Trade.beDone = false;
   g_Trade.trailActive = false;
   g_Trade.openTime = TimeCurrent();
   g_Trade.reasonComment = cmt;

   g_DailyTradeCount++;

   LogMsg(1, StringFormat("OPEN %s lot=%.2f entry=%.5f SL=%.5f TP=%.5f | %s",
                          (dir == 1 ? "BUY" : "SELL"), lot, g_Trade.entryPrice, sl, tp, cf.detail));
}

//+------------------------------------------------------------------+
//| Manage position: BE, trail, early exit                         |
//+------------------------------------------------------------------+
bool OpposingFVGShouldExit(const int dir)
{
   if(!EarlyExit_OppositeFVG) return false;
   SFVGZone z;
   if(!FindRecentFVG((dir == 1 ? -1 : 1), z)) return false;
   if(z.zHigh <= z.zLow) return false;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double px = (dir == 1) ? bid : ask;

   // mitigated opposing zone / zone opposée touchée
   if(dir == 1)
      return (px >= z.zLow && px <= z.zHigh);
   return (px <= z.zHigh && px >= z.zLow);
}

bool StructureBreakAgainst(const int dir)
{
   if(!EarlyExit_StructureBreak) return false;

   double c[];
   ArraySetAsSeries(c, true);
   const int n = StructureSwingBars + 4;
   if(CopyClose(_Symbol, SignalTimeframe, 1, n, c) < n) return false;

   if(dir == 1)
   {
      double minC = c[1];
      for(int i = 2; i <= StructureSwingBars; i++)
         minC = MathMin(minC, c[i]);
      return (c[1] < minC - 2 * _Point);
   }
   double maxC = c[1];
   for(int j = 2; j <= StructureSwingBars; j++)
      maxC = MathMax(maxC, c[j]);
   return (c[1] > maxC + 2 * _Point);
}

void ManageOpenTrade()
{
   if(!g_Trade.isOpen) return;
   if(!PositionSelectByTicket(g_Trade.ticket))
   {
      ResetActiveTradeState();
      return;
   }

   const int dir = g_Trade.direction;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double entry = g_Trade.entryPrice;
   double sl = PositionGetDouble(POSITION_SL);
   const double tp = PositionGetDouble(POSITION_TP);
   const double rDist = MathAbs(entry - g_Trade.slInitial);
   if(rDist <= 0.0) return;

   const double px = (dir == 1) ? bid : ask;
   const double curR = (dir == 1) ? (px - entry) / rDist : (entry - px) / rDist;

   if(OpposingFVGShouldExit(dir) || StructureBreakAgainst(dir))
   {
      if(Trade.PositionClose(g_Trade.ticket))
         LogMsg(1, "Early exit: opposing FVG or structure / Sortie anticipée FVG/structure");
      ResetActiveTradeState();
      return;
   }

   const double pt = BrokerPoint();
   const double atr = GetATRSignal(1);

   // Breakeven at +1R / Breakeven +1R
   if(UseBreakeven && !g_Trade.beDone && curR >= BreakevenAtR)
   {
      double newSL = (dir == 1) ? NormalizeDouble(entry + 3 * pt, _Digits) : NormalizeDouble(entry - 3 * pt, _Digits);
      const bool better = (dir == 1) ? (newSL > sl + pt) : (newSL < sl - pt);
      if(better)
      {
         if(Trade.PositionModify(g_Trade.ticket, newSL, tp))
         {
            g_Trade.beDone = true;
            g_Trade.slCurrent = newSL;
            LogMsg(1, "Breakeven set / BE placé à +1R");
         }
      }
   }

   // Trailing / Trailing
   if(UseTrailing && curR >= TrailingStartR && atr > 0.0)
   {
      double trailDist = Trail_ATR_Mult * atr;
      double newSL2 = sl;

      if(!UseSwingTrail)
      {
         if(dir == 1)
            newSL2 = NormalizeDouble(bid - trailDist, _Digits);
         else
            newSL2 = NormalizeDouble(ask + trailDist, _Digits);
      }
      else
      {
         double lows[], highs[];
         ArraySetAsSeries(lows, true);
         ArraySetAsSeries(highs, true);
         if(CopyLow(_Symbol, SignalTimeframe, 1, 6, lows) >= 6 &&
            CopyHigh(_Symbol, SignalTimeframe, 1, 6, highs) >= 6)
         {
            if(dir == 1)
            {
               double ml = lows[1];
               for(int i = 2; i <= 5; i++) ml = MathMin(ml, lows[i]);
               newSL2 = NormalizeDouble(ml - 4 * pt, _Digits);
            }
            else
            {
               double mh = highs[1];
               for(int j = 2; j <= 5; j++) mh = MathMax(mh, highs[j]);
               newSL2 = NormalizeDouble(mh + 4 * pt, _Digits);
            }
         }
      }

      const bool improve = (dir == 1) ? (newSL2 > sl + pt) : (newSL2 < sl - pt);
      if(improve)
      {
         if(Trade.PositionModify(g_Trade.ticket, newSL2, tp))
         {
            g_Trade.trailActive = true;
            g_Trade.slCurrent = newSL2;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!SymbolIsGold())
   {
      Alert(g_EA_Name + " | ERROR: not gold symbol / ERREUR: symbole non-or (XAU/GOLD)");
      return INIT_FAILED;
   }

   if(SignalTimeframe != PERIOD_M5 && SignalTimeframe != PERIOD_M15)
      LogMsg(2, "Warning: SignalTimeframe not M5/M15 as spec / Attention: TF signal hors M5/M15");

   if(BiasTimeframe != PERIOD_H4 && BiasTimeframe != PERIOD_D1)
      LogMsg(2, "Warning: BiasTimeframe not H4/D1 as spec / Attention: biais HTF hors H4/D1");

   hEMA_Bias = iMA(_Symbol, BiasTimeframe, EMA_Period_Bias, 0, MODE_EMA, PRICE_CLOSE);
   hATR_Signal = iATR(_Symbol, SignalTimeframe, ATR_Period);
   hRSI_Signal = iRSI(_Symbol, SignalTimeframe, RSI_Period, PRICE_CLOSE);

   if(hEMA_Bias == INVALID_HANDLE || hATR_Signal == INVALID_HANDLE || hRSI_Signal == INVALID_HANDLE)
   {
      Alert(g_EA_Name + " | ERROR: indicator handles / ERREUR: handles indicateurs");
      return INIT_FAILED;
   }

   SymbolSelect(_Symbol, true);
   PrefetchHistory(BiasTimeframe, 420);
   PrefetchHistory(SignalTimeframe, 900);

   WaitIndicatorCalculated(hEMA_Bias, EMA_Period_Bias + 5, 12000);
   WaitIndicatorCalculated(hATR_Signal, ATR_Period + 5, 8000);
   WaitIndicatorCalculated(hRSI_Signal, RSI_Period + 5, 8000);

   Trade.SetExpertMagicNumber(MagicNumber);
   SetupTradeFillingMode();

   SymInfo.Name(_Symbol);
   SymInfo.RefreshRates();

   g_StartBalance = Account.Balance();
   g_DayStartEquity = Account.Equity();
   g_IntradayEquityPeak = g_DayStartEquity;
   g_LastDayChecked = TimeCurrent();
   g_LastSignalBarTime = iTime(_Symbol, SignalTimeframe, 0);

   ResetActiveTradeState();
   CheckExistingPositionAttach();

   LoadNewsEventsFromFile();

   LogMsg(1, "══════════════════════════════════════════════════════");
   LogMsg(1, g_EA_Name + " " + g_EA_Version + " | Initialized / Initialisé OK");
   LogMsg(1, "Symbol / Symbole: " + _Symbol + " | Chart / Graph: " + EnumToString((ENUM_TIMEFRAMES)_Period));
   LogMsg(1, "Bias TF / TF biais: " + EnumToString(BiasTimeframe) + " | Signal TF: " + EnumToString(SignalTimeframe));
   LogMsg(1, "Risk%=" + DoubleToString(RiskPercent, 2) + " MaxTrades/Day=" + IntegerToString(MaxTradesPerDay));
   LogMsg(1, "══════════════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA_Bias != INVALID_HANDLE) IndicatorRelease(hEMA_Bias);
   if(hATR_Signal != INVALID_HANDLE) IndicatorRelease(hATR_Signal);
   if(hRSI_Signal != INVALID_HANDLE) IndicatorRelease(hRSI_Signal);
   Comment("");
   LogMsg(1, g_EA_Name + " stopped / arrêt, reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckDayRollover();
   UpdateIntradayPeakEquity();

   if(!TerminalConnected())
   {
      LogMsg(3, "Terminal not connected / Terminal non connecté");
      UpdateDashboard();
      return;
   }

   if(!CheckDailyRiskHalts())
   {
      UpdateDashboard();
      return;
   }

   const datetime barTime = iTime(_Symbol, SignalTimeframe, 0);
   const bool isNewSignalBar = (barTime != g_LastSignalBarTime);
   if(isNewSignalBar)
      g_LastSignalBarTime = barTime;

   if(g_Trade.isOpen)
      ManageOpenTrade();

   if(!isNewSignalBar)
   {
      UpdateDashboard();
      return;
   }

   // New bar processing on closed bar [1] logic in functions using shift 1
   OnNewSignalBar();
   UpdateDashboard();
}

void OnNewSignalBar()
{
   if(g_Trade.isOpen)
   {
      LogMsg(3, "Active trade: skip new signal / Trade actif: skip signal");
      return;
   }
   if(g_DailyHalt) return;
   if(g_DailyTradeCount >= MaxTradesPerDay) return;
   if(!SpreadOK())
   {
      LogMsg(3, "Spread too high / Spread trop élevé");
      return;
   }
   if(IsNewsBlackout())
   {
      LogMsg(3, "News blackout / Fenêtre news");
      return;
   }

   SBiasHTF bias = CalculateBiasEMA200();
   if(!bias.valid)
   {
      LogMsg(3, "No HTF bias / Pas de biais HTF");
      return;
   }

   const double atr1 = GetATRSignal(1);
   if(atr1 <= 0.0) return;

   SOrderBlock ob = DetectOrderBlock(bias.direction);
   SFVGZone fvg;
   const bool hasFvg = FindRecentFVG(bias.direction, fvg);

   SSwingLevels sw;
   const int look = MathMin(SwingLookbackMax, MathMax(SwingLookbackMin, 30));
   FindRecentSwings(sw, look);

   SConfluenceScore cf = BuildConfluence(bias, ob, fvg, sw, atr1);

   g_UI_BiasLabel = bias.label;
   g_UI_Confluence = cf.detail;
   g_UI_Score = cf.score;

   if(DrawZonesOnChart)
   {
      if(ob.valid) DrawOrderBlock(ob);
      if(hasFvg) DrawFVG(fvg, ob.valid ? ob.obTime : TimeCurrent());
      if(sw.valid) DrawLiquidityLines(sw);
   }

   const int minReq = (int)MathMin(6, MathMax(1, MinConfluenceRequired));
   if(cf.score < minReq)
   {
      LogMsg(3, "Confluence insufficient / Confluence insuffisante: " + cf.detail);
      return;
   }
   if(!ob.valid)
   {
      LogMsg(3, "OB invalid / OB invalide");
      return;
   }
   if(!hasFvg)
   {
      LogMsg(3, "No FVG / Pas de FVG");
      return;
   }

   OpenTradeFromSetup(bias, ob, fvg, sw, cf);
}

//+------------------------------------------------------------------+
