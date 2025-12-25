//+------------------------------------------------------------------+
//|                                                XAUUSD_GoldEA.mq5 |
//|              XAUUSD-only Expert Advisor (MT5, production spec)  |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/AccountInfo.mqh>

CTrade trade;
CPositionInfo position;
CAccountInfo account;

int g_atr_handle = INVALID_HANDLE;
int g_rsi_handle = INVALID_HANDLE;
int g_ema_fast_h1_handle = INVALID_HANDLE;
int g_ema_slow_h1_handle = INVALID_HANDLE;
int g_sma_slow_h1_handle = INVALID_HANDLE;
int g_ema_fast_h4_handle = INVALID_HANDLE;
int g_ema_slow_h4_handle = INVALID_HANDLE;
int g_sma_slow_h4_handle = INVALID_HANDLE;

//--- Inputs
input string InpSymbolLock             = "XAUUSD";     // Symbol lock (prefix)
input ENUM_TIMEFRAMES InpExecTF        = PERIOD_M5;    // Execution timeframe (M1-M15)
input ENUM_TIMEFRAMES InpTrendTF1      = PERIOD_H1;    // Trend TF 1
input ENUM_TIMEFRAMES InpTrendTF2      = PERIOD_H4;    // Trend TF 2

input int    InpEMAFast                = 20;           // EMA fast
input int    InpEMASlow                = 50;           // EMA slow
input int    InpSMASlow                = 100;          // SMA slow

input int    InpATRPeriod              = 14;           // ATR period
input double InpATRMin                 = 0.50;         // Min ATR filter (gold tuned)
input double InpATRMax                 = 8.00;         // Max ATR filter (gold tuned)
input double InpATRSLMult              = 1.2;          // SL ATR multiplier
input double InpATRTPMult              = 1.5;          // TP ATR multiplier

input int    InpRSIPeriod              = 14;           // RSI period
input double InpRSIBuy                 = 55.0;         // RSI buy threshold
input double InpRSISell                = 45.0;         // RSI sell threshold

input int    InpStructureLookback      = 5;            // Breakout lookback

input double InpMaxLossPerTradeUSD     = 20.0;         // Hard max loss per trade
input double InpMinTakeProfitUSD       = 20.01;        // Min TP in USD
input double InpMaxDailyDrawdownUSD    = 200.0;        // Daily max drawdown

input int    InpMaxSpreadPoints        = 250;          // Max spread (points)
input int    InpMaxSlippagePoints      = 50;           // Max slippage (points)

input bool   InpUseSessionFilter       = true;         // Use session filter
input int    InpLondonStartHourGMT     = 7;            // London session start (GMT)
input int    InpLondonEndHourGMT       = 16;           // London session end (GMT)
input int    InpNewYorkStartHourGMT    = 12;           // New York session start (GMT)
input int    InpNewYorkEndHourGMT      = 21;           // New York session end (GMT)

input bool   InpUseNewsFilter          = true;         // Use economic calendar filter
input int    InpNewsPauseBeforeMin     = 30;           // Pause before news (min)
input int    InpNewsPauseAfterMin      = 30;           // Pause after news (min)
input string InpNewsSchedule           = "";           // News schedule list (YYYY.MM.DD HH:MI;...)

input string InpTelegramToken          = "";           // Telegram bot token
input string InpTelegramChatId         = "";           // Telegram chat id

//--- State
bool   g_trading_enabled = true;
datetime g_day_start = 0;
double g_day_start_equity = 0.0;
int    g_last_summary_day = -1;

//+------------------------------------------------------------------+
//| Helpers                                                         |
//+------------------------------------------------------------------+
bool IsSymbolAllowed()
{
   string sym = Symbol();
   if(StringLen(sym) < StringLen(InpSymbolLock))
      return false;
   return StringFind(sym, InpSymbolLock, 0) == 0;
}

bool IsExecutionTF()
{
   return (InpExecTF == PERIOD_M1 || InpExecTF == PERIOD_M5 || InpExecTF == PERIOD_M15);
}

bool SpreadOK()
{
   long spread = (long)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   return spread > 0 && spread <= InpMaxSpreadPoints;
}

bool SlippageOK()
{
   // Slippage enforced on order send; this is a placeholder for logic extension.
   return true;
}

bool SessionOK()
{
   if(!InpUseSessionFilter)
      return true;

   datetime gmt = TimeGMT();
   MqlDateTime tm;
   TimeToStruct(gmt, tm);

   bool in_london = (tm.hour >= InpLondonStartHourGMT && tm.hour < InpLondonEndHourGMT);
   bool in_ny = (tm.hour >= InpNewYorkStartHourGMT && tm.hour < InpNewYorkEndHourGMT);

   return (in_london || in_ny);
}

bool NewsOK(datetime &next_news_time)
{
   next_news_time = 0;
   if(!InpUseNewsFilter)
      return true;

   if(StringLen(InpNewsSchedule) == 0)
      return true;

   string items[];
   int count = StringSplit(InpNewsSchedule, ';', items);
   if(count <= 0)
      return true;

   datetime now = TimeCurrent();
   for(int i = 0; i < count; i++)
   {
      string trimmed = TrimString(items[i]);
      if(StringLen(trimmed) == 0)
         continue;

      datetime event_time = StringToTime(trimmed);
      if(event_time <= 0)
         continue;

      datetime pause_from = event_time - (InpNewsPauseBeforeMin * 60);
      datetime pause_to = event_time + (InpNewsPauseAfterMin * 60);

      if(now >= pause_from && now <= pause_to)
      {
         next_news_time = event_time;
         return false;
      }
   }

   return true;
}

string TrimString(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

bool CopyLatestValue(const int handle, double &value)
{
   double buffer[];
   if(CopyBuffer(handle, 0, 0, 1, buffer) < 1)
      return false;
   value = buffer[0];
   return true;
}

bool TrendAligned(bool &bullish)
{
   double ema_fast_h1;
   double ema_slow_h1;
   double sma_slow_h1;
   double ema_fast_h4;
   double ema_slow_h4;
   double sma_slow_h4;

   if(!CopyLatestValue(g_ema_fast_h1_handle, ema_fast_h1) ||
      !CopyLatestValue(g_ema_slow_h1_handle, ema_slow_h1) ||
      !CopyLatestValue(g_sma_slow_h1_handle, sma_slow_h1) ||
      !CopyLatestValue(g_ema_fast_h4_handle, ema_fast_h4) ||
      !CopyLatestValue(g_ema_slow_h4_handle, ema_slow_h4) ||
      !CopyLatestValue(g_sma_slow_h4_handle, sma_slow_h4))
      return false;

   bool bull_h1 = (ema_fast_h1 > ema_slow_h1 && ema_slow_h1 > sma_slow_h1);
   bool bull_h4 = (ema_fast_h4 > ema_slow_h4 && ema_slow_h4 > sma_slow_h4);
   bool bear_h1 = (ema_fast_h1 < ema_slow_h1 && ema_slow_h1 < sma_slow_h1);
   bool bear_h4 = (ema_fast_h4 < ema_slow_h4 && ema_slow_h4 < sma_slow_h4);

   if(bull_h1 && bull_h4)
   {
      bullish = true;
      return true;
   }
   if(bear_h1 && bear_h4)
   {
      bullish = false;
      return true;
   }
   return false;
}

bool VolatilityOK(double &atr_value)
{
   if(!CopyLatestValue(g_atr_handle, atr_value))
      return false;
   return (atr_value >= InpATRMin && atr_value <= InpATRMax);
}

bool MomentumOK(bool bullish)
{
   double rsi;
   if(!CopyLatestValue(g_rsi_handle, rsi))
      return false;
   if(bullish)
      return rsi >= InpRSIBuy;
   return rsi <= InpRSISell;
}

bool PriceActionOK(bool bullish)
{
   MqlRates rates[];
   if(CopyRates(Symbol(), InpExecTF, 0, 3, rates) < 3)
      return false;

   // Simple engulfing
   bool bull_engulf = (rates[1].close < rates[1].open && rates[0].close > rates[0].open &&
                       rates[0].close > rates[1].open && rates[0].open < rates[1].close);
   bool bear_engulf = (rates[1].close > rates[1].open && rates[0].close < rates[0].open &&
                       rates[0].close < rates[1].open && rates[0].open > rates[1].close);

   // Breakout
   double highest = rates[1].high;
   double lowest = rates[1].low;
   for(int i = 1; i <= InpStructureLookback && i < ArraySize(rates); i++)
   {
      highest = MathMax(highest, rates[i].high);
      lowest = MathMin(lowest, rates[i].low);
   }
   bool bull_break = rates[0].close > highest;
   bool bear_break = rates[0].close < lowest;

   if(bullish)
      return bull_engulf || bull_break;
   return bear_engulf || bear_break;
}

bool HasOpenPosition()
{
   return position.Select(Symbol());
}

double CalcLot(double sl_points)
{
   double tick_value = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double point_value = tick_value / tick_size;

   if(sl_points <= 0.0 || point_value <= 0.0)
      return 0.0;

   double lot = InpMaxLossPerTradeUSD / (sl_points * point_value);

   double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lot = MathMax(min_lot, MathMin(lot, max_lot));
   lot = MathFloor(lot / step) * step;

   return lot;
}

bool DailyDrawdownOK()
{
   if(g_day_start_equity <= 0.0)
      return true;

   double dd = g_day_start_equity - account.Equity();
   if(dd >= InpMaxDailyDrawdownUSD)
      return false;

   return true;
}

datetime CurrentDayStart()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   tm.hour = 0;
   tm.min = 0;
   tm.sec = 0;
   return StructToTime(tm);
}

void ResetDailyTracking()
{
   g_day_start = CurrentDayStart();
   g_day_start_equity = account.Equity();
}

void SendTelegram(const string &message)
{
   if(StringLen(InpTelegramToken) == 0 || StringLen(InpTelegramChatId) == 0)
      return;

   string url = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string data = "chat_id=" + InpTelegramChatId + "&text=" + message;

   char post[];
   StringToCharArray(data, post);

   char result[];
   string headers;

   ResetLastError();
   int res = WebRequest("POST", url, "", 5000, post, result, headers);
   if(res == -1)
   {
      Print("Telegram error: ", GetLastError());
   }
}

void SendDailySummary()
{
   double equity = account.Equity();
   double pnl = equity - g_day_start_equity;
   string msg = StringFormat("Daily summary: trades=%d, PnL=%.2f", 
                             (int)HistoryDealsTotal(), pnl);
   SendTelegram(msg);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!IsSymbolAllowed())
   {
      Print("XAUUSD-only EA. Symbol rejected: ", Symbol());
      SendTelegram("EA refused to start: symbol is not XAUUSD.");
      return INIT_FAILED;
   }

   if(!IsExecutionTF())
   {
      Print("Execution timeframe must be M1/M5/M15.");
      SendTelegram("EA refused to start: invalid execution timeframe.");
      return INIT_FAILED;
   }

   if(InpUseNewsFilter && StringLen(InpNewsSchedule) == 0)
   {
      Print("News filter enabled but no schedule provided.");
      SendTelegram("News filter enabled but no schedule provided.");
   }

   g_atr_handle = iATR(Symbol(), InpExecTF, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle.");
      return INIT_FAILED;
   }

   g_rsi_handle = iRSI(Symbol(), InpExecTF, InpRSIPeriod, PRICE_CLOSE);
   if(g_rsi_handle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle.");
      IndicatorRelease(g_atr_handle);
      return INIT_FAILED;
   }

   g_ema_fast_h1_handle = iMA(Symbol(), InpTrendTF1, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_h1_handle = iMA(Symbol(), InpTrendTF1, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_sma_slow_h1_handle = iMA(Symbol(), InpTrendTF1, InpSMASlow, 0, MODE_SMA, PRICE_CLOSE);
   g_ema_fast_h4_handle = iMA(Symbol(), InpTrendTF2, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_h4_handle = iMA(Symbol(), InpTrendTF2, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   g_sma_slow_h4_handle = iMA(Symbol(), InpTrendTF2, InpSMASlow, 0, MODE_SMA, PRICE_CLOSE);

   if(g_ema_fast_h1_handle == INVALID_HANDLE || g_ema_slow_h1_handle == INVALID_HANDLE ||
      g_sma_slow_h1_handle == INVALID_HANDLE || g_ema_fast_h4_handle == INVALID_HANDLE ||
      g_ema_slow_h4_handle == INVALID_HANDLE || g_sma_slow_h4_handle == INVALID_HANDLE)
   {
      Print("Failed to create MA handles.");
      IndicatorRelease(g_atr_handle);
      IndicatorRelease(g_rsi_handle);
      if(g_ema_fast_h1_handle != INVALID_HANDLE)
         IndicatorRelease(g_ema_fast_h1_handle);
      if(g_ema_slow_h1_handle != INVALID_HANDLE)
         IndicatorRelease(g_ema_slow_h1_handle);
      if(g_sma_slow_h1_handle != INVALID_HANDLE)
         IndicatorRelease(g_sma_slow_h1_handle);
      if(g_ema_fast_h4_handle != INVALID_HANDLE)
         IndicatorRelease(g_ema_fast_h4_handle);
      if(g_ema_slow_h4_handle != INVALID_HANDLE)
         IndicatorRelease(g_ema_slow_h4_handle);
      if(g_sma_slow_h4_handle != INVALID_HANDLE)
         IndicatorRelease(g_sma_slow_h4_handle);
      return INIT_FAILED;
   }

   ResetDailyTracking();
   EventSetTimer(60);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   if(g_rsi_handle != INVALID_HANDLE)
      IndicatorRelease(g_rsi_handle);
   if(g_ema_fast_h1_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_fast_h1_handle);
   if(g_ema_slow_h1_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_slow_h1_handle);
   if(g_sma_slow_h1_handle != INVALID_HANDLE)
      IndicatorRelease(g_sma_slow_h1_handle);
   if(g_ema_fast_h4_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_fast_h4_handle);
   if(g_ema_slow_h4_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_slow_h4_handle);
   if(g_sma_slow_h4_handle != INVALID_HANDLE)
      IndicatorRelease(g_sma_slow_h4_handle);
}

//+------------------------------------------------------------------+
//| Timer for daily reset/summary                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   datetime today = CurrentDayStart();
   if(today != g_day_start)
   {
      SendDailySummary();
      ResetDailyTracking();
   }
}

//+------------------------------------------------------------------+
//| Trade transaction for exit alerts                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD &&
      (trans.deal_type == DEAL_TYPE_SELL || trans.deal_type == DEAL_TYPE_BUY))
   {
      if(trans.deal > 0)
      {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT)
            return;

         string deal_symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         double deal_price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
         double deal_profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         string msg = StringFormat("Exit %s at %.2f, P/L=%.2f",
                                   deal_symbol, deal_price, deal_profit);
         SendTelegram(msg);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_trading_enabled)
      return;

   if(!DailyDrawdownOK())
   {
      g_trading_enabled = false;
      SendTelegram("Trading halted: daily drawdown exceeded.");
      return;
   }

   if(HasOpenPosition())
      return;

   if(!SpreadOK() || !SlippageOK() || !SessionOK())
      return;

   datetime next_news_time;
   if(!NewsOK(next_news_time))
   {
      SendTelegram("Trading paused for high-impact USD news.");
      return;
   }

   bool bullish = false;
   if(!TrendAligned(bullish))
      return;

   double atr;
   if(!VolatilityOK(atr))
      return;

   if(!MomentumOK(bullish))
      return;

   if(!PriceActionOK(bullish))
      return;

   double sl_points = (atr * InpATRSLMult) / SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double tp_points = (atr * InpATRTPMult) / SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   double lot = CalcLot(sl_points);
   if(lot <= 0.0)
      return;

   // Enforce max loss and min TP in USD by recalculating monetary value
   double tick_value = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double point_value = tick_value / tick_size;

   double sl_usd = sl_points * point_value * lot;
   double tp_usd = tp_points * point_value * lot;
   if(sl_usd > InpMaxLossPerTradeUSD + 0.01)
      return;
   if(tp_usd < InpMinTakeProfitUSD)
      return;

   double price = bullish ? SymbolInfoDouble(Symbol(), SYMBOL_ASK) : SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double sl = bullish ? price - sl_points * SymbolInfoDouble(Symbol(), SYMBOL_POINT)
                       : price + sl_points * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double tp = bullish ? price + tp_points * SymbolInfoDouble(Symbol(), SYMBOL_POINT)
                       : price - tp_points * SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   trade.SetDeviationInPoints(InpMaxSlippagePoints);
   bool sent = false;

   if(bullish)
      sent = trade.Buy(lot, Symbol(), price, sl, tp, "XAUUSD bullish entry");
   else
      sent = trade.Sell(lot, Symbol(), price, sl, tp, "XAUUSD bearish entry");

   if(sent)
   {
      string side = bullish ? "BUY" : "SELL";
      string msg = StringFormat("Entry %s at %.2f SL %.2f TP %.2f Lot %.2f",
                                side, price, sl, tp, lot);
      SendTelegram(msg);
   }
   else
   {
      Print("Order send failed: ", GetLastError());
   }
}
//+------------------------------------------------------------------+
