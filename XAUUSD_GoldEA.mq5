//+------------------------------------------------------------------+
//|                                                XAUUSD_GoldEA.mq5 |
//|   XAUUSD-only Expert Advisor (MT5) - Trend+Pullback+ATR Risk      |
//+------------------------------------------------------------------+
#property strict
#property version "1.10"

#include <Trade/Trade.mqh>

CTrade trade;

//------------------------- Inputs ----------------------------------//
input string           InpSymbolLock          = "XAUUSD";     // Symbol prefix lock (supports suffix)
input ENUM_TIMEFRAMES  InpExecTF              = PERIOD_M5;    // Execution timeframe
input ENUM_TIMEFRAMES  InpTrendTF1            = PERIOD_H1;    // Trend TF 1
input ENUM_TIMEFRAMES  InpTrendTF2            = PERIOD_H4;    // Trend TF 2

input int              InpEMAFast             = 20;           // EMA fast
input int              InpEMASlow             = 50;           // EMA slow
input int              InpSMASlow             = 100;          // SMA slow

input int              InpRSIPeriod           = 14;           // RSI period (Exec TF)
input double           InpRSILongMin          = 52.0;         // RSI threshold for longs
input double           InpRSIShortMax         = 48.0;         // RSI threshold for shorts

input int              InpATRPeriod           = 14;           // ATR period (Exec TF)
input double           InpATRMin              = 0.0;          // Min ATR filter (0 disables)
input double           InpATRMax              = 0.0;          // Max ATR filter (0 disables)

input double           InpSL_ATR_Mult         = 1.5;          // StopLoss = ATR * mult
input double           InpTP_R_Mult           = 1.4;          // TakeProfit = SL * R-mult

input double           InpRiskPercent         = 0.50;         // Risk per trade (% of equity)
input int              InpMaxTradesPerDay     = 6;            // Max trades per day
input double           InpDailyLossLimitPct   = 2.0;          // Stop trading for day if equity drops this % from day start

input int              InpMaxSpreadPoints     = 60;           // Max spread (points) allowed
input long             InpMagic               = 20251225;     // Magic number
input bool             InpVerboseLogs         = true;         // Print decision logs

//------------------------- Globals ---------------------------------//
int hATR = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;

int hEmaFast_TF1 = INVALID_HANDLE;
int hEmaSlow_TF1 = INVALID_HANDLE;
int hSmaSlow_TF1 = INVALID_HANDLE;

int hEmaFast_TF2 = INVALID_HANDLE;
int hEmaSlow_TF2 = INVALID_HANDLE;
int hSmaSlow_TF2 = INVALID_HANDLE;

datetime g_lastBarTime = 0;

// daily tracking
int      g_dayKey = -1;           // yyyymmdd
double   g_dayStartEquity = 0.0;
int      g_tradesToday = 0;

//------------------------- Utilities --------------------------------//
bool SymbolMatchesLock()
{
   // allow suffixes: "XAUUSD", "XAUUSDm", "XAUUSD.i"
   return (StringFind(_Symbol, InpSymbolLock) == 0);
}

int MakeDayKey(datetime t)
{
   MqlDateTime s; TimeToStruct(t, s);
   return (s.year * 10000 + s.mon * 100 + s.day);
}

void ResetDailyIfNeeded()
{
   int dk = MakeDayKey(TimeCurrent());
   if(dk != g_dayKey)
   {
      g_dayKey = dk;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday = 0;
      if(InpVerboseLogs)
         Print("Daily reset: dayKey=", g_dayKey, " dayStartEquity=", DoubleToString(g_dayStartEquity, 2));
   }
}

bool DailyLimitsOk()
{
   ResetDailyIfNeeded();

   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
   {
      if(InpVerboseLogs) Print("Daily limit hit: tradesToday=", g_tradesToday, " max=", InpMaxTradesPerDay);
      return false;
   }

   if(InpDailyLossLimitPct > 0.0 && g_dayStartEquity > 0.0)
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = 100.0 * (g_dayStartEquity - eq) / g_dayStartEquity;
      if(ddPct >= InpDailyLossLimitPct)
      {
         if(InpVerboseLogs)
            Print("Daily loss limit hit: ddPct=", DoubleToString(ddPct, 2), "% limit=", DoubleToString(InpDailyLossLimitPct,2), "%");
         return false;
      }
   }
   return true;
}

bool SpreadOk()
{
   int spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints > 0 && spreadPoints > InpMaxSpreadPoints)
   {
      if(InpVerboseLogs) Print("Spread filter: spreadPoints=", spreadPoints, " > max=", InpMaxSpreadPoints);
      return false;
   }
   return true;
}

bool Copy1(int handle, double &val, int shift=0)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return false;
   val = buf[0];
   return true;
}

bool Copy2(int handle, double &val0, double &val1)
{
   // shift 0 and 1
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 0, 2, buf) != 2)
      return false;
   val0 = buf[0];
   val1 = buf[1];
   return true;
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpExecTF, 0);
   if(t == 0) return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

bool HasOpenPosition()
{
   // One position per symbol+magic
   int total = PositionsTotal();
   for(int idx = total - 1; idx >= 0; --idx)
   {
      ulong ticket = PositionGetTicket(idx);
      if(ticket == 0) continue;

      if(!PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long magic = (long)PositionGetInteger(POSITION_MAGIC);

      if(sym == _Symbol && magic == InpMagic)
         return true;
   }
   return false;
}

double NormalizeVolume(double vol)
{
   double vMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vol < vMin) vol = vMin;
   if(vol > vMax) vol = vMax;

   // round down to step
   double steps = MathFloor(vol / vStep);
   double out = steps * vStep;
   // ensure not below min after rounding
   if(out < vMin) out = vMin;
   return out;
}

double CalcLotsByRisk(double sl_points)
{
   if(sl_points <= 0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);
   if(riskMoney <= 0) return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickValue <= 0 || tickSize <= 0 || point <= 0) return 0.0;

   // value per point for 1.0 lot:
   // 1 point = point price movement
   // value per point = tickValue * (point / tickSize)
   double valuePerPointPerLot = tickValue * (point / tickSize);
   if(valuePerPointPerLot <= 0) return 0.0;

   double lots = riskMoney / (sl_points * valuePerPointPerLot);
   return NormalizeVolume(lots);
}

//------------------------- Strategy logic ---------------------------//
bool TrendLong()
{
   double efast1, eslow1, ssma1;
   double efast2, eslow2, ssma2;

   if(!Copy1(hEmaFast_TF1, efast1) || !Copy1(hEmaSlow_TF1, eslow1) || !Copy1(hSmaSlow_TF1, ssma1)) return false;
   if(!Copy1(hEmaFast_TF2, efast2) || !Copy1(hEmaSlow_TF2, eslow2) || !Copy1(hSmaSlow_TF2, ssma2)) return false;

   return (efast1 > eslow1 && eslow1 > ssma1) && (efast2 > eslow2 && eslow2 > ssma2);
}

bool TrendShort()
{
   double efast1, eslow1, ssma1;
   double efast2, eslow2, ssma2;

   if(!Copy1(hEmaFast_TF1, efast1) || !Copy1(hEmaSlow_TF1, eslow1) || !Copy1(hSmaSlow_TF1, ssma1)) return false;
   if(!Copy1(hEmaFast_TF2, efast2) || !Copy1(hEmaSlow_TF2, eslow2) || !Copy1(hSmaSlow_TF2, ssma2)) return false;

   return (efast1 < eslow1 && eslow1 < ssma1) && (efast2 < eslow2 && eslow2 < ssma2);
}

bool AtrOk(double atr)
{
   if(InpATRMin > 0.0 && atr < InpATRMin) return false;
   if(InpATRMax > 0.0 && atr > InpATRMax) return false;
   return true;
}

void TryEnter()
{
   if(!DailyLimitsOk()) return;
   if(!SpreadOk()) return;
   if(HasOpenPosition())
   {
      if(InpVerboseLogs) Print("Skip: already in position.");
      return;
   }

   // Read ATR/RSI on ExecTF
   double atr=0.0, rsi=0.0;
   if(!Copy1(hATR, atr) || !Copy1(hRSI, rsi))
   {
      if(InpVerboseLogs) Print("Indicator read failed (ATR/RSI). err=", GetLastError());
      return;
   }
   if(!AtrOk(atr))
   {
      if(InpVerboseLogs) Print("ATR filter blocked. ATR=", DoubleToString(atr, Digits()));
      return;
   }

   // Pullback-to-EMA20 entry conditions on ExecTF
   double emaFast0=0.0, emaFast1=0.0;
   int hEmaFastExec = iMA(_Symbol, InpExecTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   if(hEmaFastExec == INVALID_HANDLE)
   {
      if(InpVerboseLogs) Print("Failed to create temp Exec EMA handle.");
      return;
   }
   if(!Copy2(hEmaFastExec, emaFast0, emaFast1))
   {
      IndicatorRelease(hEmaFastExec);
      if(InpVerboseLogs) Print("Failed to read Exec EMA.");
      return;
   }
   IndicatorRelease(hEmaFastExec);

   double close1 = iClose(_Symbol, InpExecTF, 1);
   double low1   = iLow(_Symbol, InpExecTF, 1);
   double high1  = iHigh(_Symbol, InpExecTF, 1);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // SL/TP distance from ATR
   double sl_price_dist = atr * InpSL_ATR_Mult;
   if(sl_price_dist <= 0) return;

   double sl_points = sl_price_dist / point;
   double lots = CalcLotsByRisk(sl_points);
   if(lots <= 0)
   {
      if(InpVerboseLogs) Print("Lot calc produced 0. Check symbol properties / risk settings.");
      return;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   // Long setup
   bool wantLongTrend = TrendLong();
   bool pullbackLong  = (low1 <= emaFast1) && (close1 > emaFast1) && (rsi >= InpRSILongMin);

   // Short setup
   bool wantShortTrend = TrendShort();
   bool pullbackShort  = (high1 >= emaFast1) && (close1 < emaFast1) && (rsi <= InpRSIShortMax);

   if(InpVerboseLogs)
   {
      Print("Decision: ATR=", DoubleToString(atr, Digits()),
            " RSI=", DoubleToString(rsi, 2),
            " trendL=", (wantLongTrend?"Y":"N"),
            " pbL=", (pullbackLong?"Y":"N"),
            " trendS=", (wantShortTrend?"Y":"N"),
            " pbS=", (pullbackShort?"Y":"N"),
            " lots=", DoubleToString(lots, 2));
   }

   if(!( (wantLongTrend && pullbackLong) || (wantShortTrend && pullbackShort) ))
      return;

   // Prices
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(wantLongTrend && pullbackLong)
   {
      double sl = ask - sl_price_dist;
      double tp = ask + (sl_price_dist * InpTP_R_Mult);

      if(trade.Buy(lots, _Symbol, ask, sl, tp, "TrendPullback-L"))
      {
         g_tradesToday++;
         if(InpVerboseLogs) Print("BUY placed. lots=", lots, " SL=", DoubleToString(sl, Digits()), " TP=", DoubleToString(tp, Digits()));
      }
      else
      {
         if(InpVerboseLogs) Print("BUY failed. ret=", trade.ResultRetcode(), " err=", GetLastError());
      }
      return;
   }

   if(wantShortTrend && pullbackShort)
   {
      double sl = bid + sl_price_dist;
      double tp = bid - (sl_price_dist * InpTP_R_Mult);

      if(trade.Sell(lots, _Symbol, bid, sl, tp, "TrendPullback-S"))
      {
         g_tradesToday++;
         if(InpVerboseLogs) Print("SELL placed. lots=", lots, " SL=", DoubleToString(sl, Digits()), " TP=", DoubleToString(tp, Digits()));
      }
      else
      {
         if(InpVerboseLogs) Print("SELL failed. ret=", trade.ResultRetcode(), " err=", GetLastError());
      }
      return;
   }
}

//------------------------- MT5 Events --------------------------------//
int OnInit()
{
   if(!SymbolMatchesLock())
   {
      Print("This EA is locked to symbol prefix: ", InpSymbolLock, " but chart is: ", _Symbol);
      return INIT_FAILED;
   }

   if(Period() != InpExecTF)
      Print("Note: Chart TF is ", Period(), " but EA ExecTF is ", InpExecTF, ". It will still work using iTime/iClose on ExecTF.");

   // Create indicator handles
   hATR = iATR(_Symbol, InpExecTF, InpATRPeriod);
   hRSI = iRSI(_Symbol, InpExecTF, InpRSIPeriod, PRICE_CLOSE);

   hEmaFast_TF1 = iMA(_Symbol, InpTrendTF1, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow_TF1 = iMA(_Symbol, InpTrendTF1, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hSmaSlow_TF1 = iMA(_Symbol, InpTrendTF1, InpSMASlow, 0, MODE_SMA, PRICE_CLOSE);

   hEmaFast_TF2 = iMA(_Symbol, InpTrendTF2, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow_TF2 = iMA(_Symbol, InpTrendTF2, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hSmaSlow_TF2 = iMA(_Symbol, InpTrendTF2, InpSMASlow, 0, MODE_SMA, PRICE_CLOSE);

   if(hATR==INVALID_HANDLE || hRSI==INVALID_HANDLE ||
      hEmaFast_TF1==INVALID_HANDLE || hEmaSlow_TF1==INVALID_HANDLE || hSmaSlow_TF1==INVALID_HANDLE ||
      hEmaFast_TF2==INVALID_HANDLE || hEmaSlow_TF2==INVALID_HANDLE || hSmaSlow_TF2==INVALID_HANDLE)
   {
      Print("OnInit failed: indicator handle creation failed. err=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);

   ResetDailyIfNeeded();
   Print("Initialized OK on ", _Symbol, " ExecTF=", InpExecTF);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);

   if(hEmaFast_TF1!=INVALID_HANDLE) IndicatorRelease(hEmaFast_TF1);
   if(hEmaSlow_TF1!=INVALID_HANDLE) IndicatorRelease(hEmaSlow_TF1);
   if(hSmaSlow_TF1!=INVALID_HANDLE) IndicatorRelease(hSmaSlow_TF1);

   if(hEmaFast_TF2!=INVALID_HANDLE) IndicatorRelease(hEmaFast_TF2);
   if(hEmaSlow_TF2!=INVALID_HANDLE) IndicatorRelease(hEmaSlow_TF2);
   if(hSmaSlow_TF2!=INVALID_HANDLE) IndicatorRelease(hSmaSlow_TF2);
}

void OnTick()
{
   if(!SymbolMatchesLock()) return;

   // Only evaluate once per new bar on ExecTF (more stable than tick-by-tick spam)
   if(!IsNewBar()) return;

   TryEnter();
}
//+------------------------------------------------------------------+
