//+------------------------------------------------------------------+
//|                  GoldLiquidityHunter_PRO v3.5                    |
//|               Auto Stops Level + Bias + Order Block             |
//|                     Version simplifiée et robuste               |
//+------------------------------------------------------------------+

#property copyright "EagleTrade"
#property link      ""
#property version   "3.50"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs
input double   RiskPercent           = 0.32;     // Risque par trade
input int      MagicNumber           = 123456;
input int      Slippage              = 30;

// Ajoute le reste du code ici - le fichier sera mis à jour correctement
print("Code v3.5 en cours de chargement...")