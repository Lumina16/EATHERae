//+------------------------------------------------------------------+
//|              XAUUSD_TrendContinuation_V13.mq5                     |
//|                                                                   |
//|  V13 = MULTI-TIMEFRAME + MULTI-SETUP + MONEY-TARGET ARCHITECTURE  |
//|                                                                   |
//|  H1  = BIG DIRECTION                                              |
//|  M30 = SUPPORT/RESISTANCE FILTER (optional, fully switchable)     |
//|  M15 = MID-TREND CONFIRMATION                                     |
//|  M5  = ACTIVE REGIME                                              |
//|  M1  = ENTRY                                                      |
//|                                                                   |
//|  Trades have NO fixed SL/TP target.                               |
//|  Each position closes when its floating profit reaches a fixed    |
//|  USD target (default $0.50 per position).                         |
//|                                                                   |
//|  M1 setups are independent.                                       |
//|  One setup/trade must NOT block another setup/trade.              |
//|                                                                   |
//|  ---------------------------------------------------------------- |
//|  V13.1 - TIMEFRAME ENABLE/DISABLE SWITCHES (UseH1/UseM15/UseM5/   |
//|          UseM1). A disabled timeframe is COMPLETELY IGNORED by    |
//|          AlignedBias(); all TFs disabled => ALIGN_NOFILTER.       |
//|  V13.2 - (historical) M30 pivot/bias layer. REMOVED in V13.3.     |
//|  V13.3 - M30 pivot engine replaced by an M30 SUPPORT/RESISTANCE   |
//|          entry filter.                                            |
//|  ---------------------------------------------------------------- |
//|  V13.31 BUG-FIX RELEASE (this file)                               |
//|   1. UseSRFilter=false now disables the WHOLE M30 S/R module:     |
//|      no zone building, no break counters, no state evaluation,    |
//|      no drawing, no panel blocking text, no entry influence.      |
//|      Runtime OFF is detected each tick and DisableM30SR() wipes   |
//|      state + chart objects immediately.                           |
//|   2. Deterministic S/R chart-object cleanup (dedicated prefix,    |
//|      full sweep on rebuild / DebugMode off / disable / deinit).   |
//|   3. SRLookbackHours now really bounds the analysis window by     |
//|      M30 CANDLE TIMESTAMPS; extra bars are fetched only as pivot  |
//|      context and are never treated as part of the window.         |
//|   4. Breakout-confirmation state is PRESERVED across rebuilds by  |
//|      matching old/new zones with an ATR-based price tolerance.    |
//|      Confirmed-broken levels stay broken instead of resurrecting. |
//|   5. Array/index audit: every CopyX return value is checked, all  |
//|      loop bounds are derived from the ACTUAL copied count, no     |
//|      fixed-size writes past SR_MAX_ZONES, tracker/setup arrays    |
//|      bound-checked.                                               |
//|   6. Look-ahead audit: all S/R work uses completed candles only   |
//|      (shift>=1); shift 0 is used only for live tick pricing.      |
//|   7. The panel and the real entry filter now call the SAME        |
//|      function (SRBlockReasonForDirection) and the same prices     |
//|      (Ask for BUY, Bid for SELL) - they can no longer disagree.   |
//|   8. All numeric inputs are validated/clamped into effective      |
//|      globals; invalid S/R inputs disable the S/R module instead   |
//|      of producing silent nonsense.                                |
//|   9. OnInit ordering fixed (no S/R evaluation before data), the   |
//|      EA refuses to trade until initialization completed.          |
//|  10. crossActive/breakoutConsumed cannot get stuck: consumption   |
//|      stays one-shot per setup, and a retired setup is removed,    |
//|      so no stale BLOCKED state survives an S/R switch.            |
//|                                                                   |
//|  Price-action-first: NO RSI/MACD/EMA/ADX/etc. ATR is used only    |
//|  for pullback normalization and volatility protection.            |
//+------------------------------------------------------------------+
#property copyright "Research EA - use at your own risk"
#property version   "13.31"
#property strict

//=========================================================================
//                                INPUTS
//=========================================================================
input group "TIMEFRAME FILTERS"
input bool   UseH1  = true;
input bool   UseM15 = true;
input bool   UseM5  = true;
input bool   UseM1  = true;

input group "M30 SUPPORT/RESISTANCE FILTER"
input bool   UseSRFilter        = true;
input int    SRLookbackHours    = 1;
input int    SRPivotWidth       = 2;
input double SRZoneATRMult      = 0.5;
input double SRMergeATRMult     = 1.0;
input double SRNearATRMult      = 0.5;
input int    SRBreakConfirmBars = 2;

input group "MONEY & TRADING"
input double ProfitTargetUSD  = 0.50;
input double LotSize          = 0.01;
input int    MaxOpenTrades    = 5;

input group "SAFETY"
input double MaxFloatingLossUSD      = 10.0;
input bool   CloseAllOnEmergencyLoss = true;
input double DailyLossLimitPercent   = 1.5;
input int    ConsecutiveLossLimit    = 3;
input int    MaxSpreadPoints         = 350;

input group "TRADING HOURS"
input int    TradingStartHour = 7;
input int    TradingEndHour   = 20;

input group "ENTRY SETUP"
input int    PivotSize           = 2;
input int    ATRPeriod           = 14;
input double StructureExpansion  = 0.0;
input double MinPullback         = 0.5;
input double BreakoutBodyMinimum = 0.35;

input group "VOLATILITY"
input int    VolatilityLookback   = 50;
input double VolatilitySpikeLimit = 1.50;

input group "SETUP MANAGEMENT"
input int    MaxActiveSetups    = 10;
input int    SetupExpiryMinutes = 360;
input int    MaxEntryMarkers    = 20;

input group "SYSTEM"
input int    HTFWarmupBars     = 200;
input int    M1WarmupBars      = 300;
input long   MagicNumber       = 20260915;
input int    MaxSlippagePoints = 30;

input group "PANEL (DISPLAY ONLY)"
input int    PanelX                 = 10;    // panel left offset (px)
input int    PanelY                 = 18;    // panel top offset (px)
input int    PanelWidth             = 1000;  // total panel width (px, 900-1050)
input int    PanelMinHeight         = 0;     // 0 = auto height
input int    PanelRowHeight         = 15;    // row pitch (px)
input int    PanelFontSize          = 8;     // body font size
input int    PanelRefreshMs         = 300;   // dashboard refresh throttle (ms)
input int    PanelHistoryRefreshSec = 60;    // FULL history re-scan interval (s)

input group "DEBUG"
input bool   DebugMode  = false;
input bool   DebugHTF   = false;
input bool   DebugM1    = false;
input bool   DebugTrade = false;

//=========================================================================
//                                ENUMS
//=========================================================================
enum ENUM_BIAS       { BIAS_NEUTRAL, BIAS_BULLISH, BIAS_BEARISH };
enum ENUM_SWING_TYPE { SWING_LOW, SWING_HIGH };

enum ENUM_ALIGN_RESULT { ALIGN_BULLISH, ALIGN_BEARISH, ALIGN_CONFLICT, ALIGN_NOFILTER };

enum ENUM_M1_SETUP_STATE { MS_WAIT_B, MS_WAIT_C, MS_WAIT_TRIGGER, MS_WAIT_BREAK };

enum ENUM_REJECT_CAT { REJ_NONE, REJ_LOT, REJ_STOPS, REJ_MARGIN, REJ_FILLING, REJ_BROKER, REJ_OTHER };

enum ENUM_SR_STATE
{
   SR_DISABLED,
   SR_NEAR_SUPPORT,
   SR_NEAR_RESISTANCE,
   SR_BETWEEN,
   SR_BREAKING_SUPPORT,
   SR_BREAKING_RESISTANCE,
   SR_NO_VALID
};

//=========================================================================
//                                STRUCTS
//=========================================================================
struct TFStruct
{
   ENUM_BIAS bias;
   string    reason;

   double    SH, PSH;
   double    SL, PSL;
   datetime  SHt, PSHt, SLt, PSLt;

   bool      HH, HL, LH, LL;

   double    lastExpansion;
   double    requiredExpansion;
   bool      qualityOK;

   int       cntBull;
   int       cntBear;
};

struct M1Setup
{
   long      id;

   bool      active;
   ENUM_BIAS direction;
   ENUM_M1_SETUP_STATE state;

   double    A, B, C, trigger;
   datetime  At, Bt, Ct, triggerTime;

   bool      crossActive;
   bool      breakoutConsumed;

   double    impulseDistance;
   double    pullbackDistance;

   string    breakoutQuality;
   string    entryStatus;
   string    blockReason;

   datetime  createdTime;
};

struct PosTrack
{
   bool     used;
   ulong    posId;
   long     setupId;
   double   minFloat;
   datetime openTime;
};

struct SRZone
{
   double   upper;
   double   lower;
   bool     isResistance;
   int      touches;
   bool     valid;         // false once objectively/confirmedly broken
   int      breakCount;    // consecutive completed M1 closes beyond the zone
   datetime formedTime;
};

#define SR_MAX_ZONES 5
#define SR_OBJ_PREFIX "V13_SR_"

//=========================================================================
//                            GLOBAL STATE
//=========================================================================
int g_ATR_H1=INVALID_HANDLE, g_ATR_M30=INVALID_HANDLE, g_ATR_M15=INVALID_HANDLE,
    g_ATR_M5=INVALID_HANDLE, g_ATR_M1=INVALID_HANDLE;
datetime g_LastH1Bar=0, g_LastM30Bar=0, g_LastM15Bar=0, g_LastM5Bar=0, g_LastM1Bar=0;

TFStruct g_H1;
TFStruct g_M15;
TFStruct g_M5;

// ---- M30 Support/Resistance engine state ----
SRZone        g_SRZones[SR_MAX_ZONES];
int           g_SRZoneCount=0;
datetime      g_SRLastUpdate=0;
ENUM_SR_STATE g_SRState=SR_DISABLED;
double        g_SRNearestResistance=0;
double        g_SRNearestSupport=0;
bool          g_SRActive=false;        // master runtime switch for the whole module
bool          g_SRObjectsDrawn=false;  // were S/R chart objects ever created?

// ---- Effective (validated / clamped) parameters ----
int    g_SRLookbackHours=1;
int    g_SRPivotWidth=2;
double g_SRZoneATRMult=0.5;
double g_SRMergeATRMult=1.0;
double g_SRNearATRMult=0.5;
int    g_SRBreakConfirmBars=2;

int    g_PivotSize=2;
int    g_ATRPeriod=14;
double g_MinPullback=0.5;
double g_BreakoutBodyMinimum=0.35;
double g_StructureExpansion=0.0;
int    g_VolatilityLookback=50;
double g_VolatilitySpikeLimit=1.5;
int    g_MaxActiveSetups=10;
int    g_SetupExpiryMinutes=360;
int    g_MaxEntryMarkers=20;
int    g_MaxOpenTrades=5;
int    g_MaxSpreadPoints=350;
int    g_HTFWarmupBars=200;
int    g_M1WarmupBars=300;
int    g_MaxSlippagePoints=30;
double g_ProfitTargetUSD=0.5;
double g_LotSize=0.01;
double g_MaxFloatingLossUSD=10.0;
double g_DailyLossLimitPercent=1.5;
int    g_ConsecutiveLossLimit=3;
int    g_TradingStartHour=0;
int    g_TradingEndHour=0;

bool   g_InitComplete=false;   // EA must never trade before init finished

// ---- M1 pivot stream dedupe ----
datetime g_LastM1SwingLowTime=0, g_LastM1SwingHighTime=0;

// ---- THE multi-setup collection ----
M1Setup g_Setups[];
long    g_NextSetupId=0;

// ---- Per-position stat tracking ----
PosTrack g_Tracks[];

// ---- Daily risk tracking ----
int    g_Day=-1;
double g_DayBal=0, g_DayPL=0;
int    g_ConsLoss=0;
bool   g_HaltedDaily=false;
bool   g_HaltedConsec=false;
bool   g_HaltedFloat=false;

// ---- Live caches for panel ----
double g_TotalFloat=0;

// ---- Performance tracking ----
int    g_TotalTrades=0, g_Wins=0, g_Losses=0;
double g_SumWinProfit=0, g_SumLossProfit=0;
double g_TotalRealizedPL=0;
double g_LargestWin=0, g_LargestLoss=0;
int    g_LongTrades=0, g_ShortTrades=0;
int    g_MaxConsecLossPeak=0;
double g_PeakEquity=0, g_MaxDrawdownPct=0;

// ---- Money-target statistics ----
int    g_Cnt_TargetCloses=0;
double g_SumTargetProfit=0;
double g_SumTargetHoldSec=0;
double g_SumMAE=0;

// ---- M1 engine counters ----
int g_Cnt_M1PivotHigh=0, g_Cnt_M1PivotLow=0;
int g_Cnt_SetupsCreated=0, g_Cnt_SetupsInvalidated=0, g_Cnt_SetupsExpired=0, g_Cnt_SetupsSkippedCap=0;
int g_Cnt_Triggers=0;
int g_Cnt_Breakouts=0, g_Cnt_BOQualityPass=0, g_Cnt_BOQualityWeak=0;
int g_Cnt_EntryAttempts=0, g_Cnt_EntryExecuted=0, g_Cnt_EntryBlocked=0, g_Cnt_EntryFailed=0;

// ---- Execution rejection breakdown ----
int g_Cnt_RejectLot=0, g_Cnt_RejectStops=0, g_Cnt_RejectMargin=0;
int g_Cnt_RejectFilling=0, g_Cnt_RejectBroker=0, g_Cnt_RejectOther=0;

//=========================================================================
//  DASHBOARD PANEL SHARED STATE  (DISPLAY ONLY - ZERO TRADING INFLUENCE)
//
//  Nothing below this comment is ever read by the strategy, the S/R
//  engine, the setup state machine, risk management or order execution.
//  Every variable here is written by the engine (cheap assignments) or by
//  the throttled panel path, and read only by the renderer.
//=========================================================================
bool   g_PnHistoryDirty=true;   // a deeper (full) history re-scan is due
double g_PnDayPeakEquity=0;     // intraday equity peak (display drawdown)
double g_PnDayDDPct=0;          // intraday equity drawdown %

// ---- visibility + throttling ----
bool   g_PanelVisible=false;    // are panel objects currently on the chart?
uint   g_PanelLastDrawMs=0;     // GetTickCount() of the last dashboard render
bool   g_PanelDirty=true;       // force a render on the next throttle window
bool   g_TimerActive=false;     // was EventSetMillisecondTimer() installed?

// ---- chart-annotation dirty flags (event driven, never per tick) ----
bool   g_HTFVisualDirty=true;   // H1/M15/M5 swing markers need a redraw
bool   g_SRVisualDirty=true;    // M30 S/R rectangles need a redraw
bool   g_SetupVisualDirty=true; // M1 setup anchors/triggers need a redraw

// ---- cheap engine-maintained display cache ----
int    g_PanelOpenTradeCount=0; // refreshed by ManageOpenPositions()
int    g_PanelBuyCount=0;
int    g_PanelSellCount=0;
double g_PanelOpenVolume=0;
double g_PanelAvgBuy=0, g_PanelAvgSell=0;
double g_PanelFloatPL=0;

// ---- cached decision snapshots (filled ONLY in the throttled path) ----
bool              g_PanelEntryPermission=false;
string            g_PanelBlockReason="";
bool              g_PanelSRBlocked=false;
string            g_PanelSRReason="";
ENUM_ALIGN_RESULT g_PanelAlignedBias=ALIGN_CONFLICT;
bool              g_PanelSpreadOK=true;
bool              g_PanelVolOK=true;
bool              g_PanelInSession=true;
int               g_PanelActiveSetups=0;
int               g_PanelReadySetups=0;

// ---- LAST ACTION ----
string g_LastAction = "Initialized - replaying history";

// ---- Bounded entry-marker FIFO ----
string g_EntryMarkerQueue[];

//=========================================================================
//                       FORWARD DECLARATIONS
//=========================================================================
void   OnHTFBiasChanged();
void   InvalidateM1Setup(int idx,string reason);
void   CompactSetups();
void   DrawSetupAnchor(int id,string tag,double price,datetime time,color clr,int arrowCode);
void   DrawSetupTrigger(int id,double price,datetime fromTime,color clr);
void   DeleteSetupTrigger(int id);
void   DeleteSetupVisuals(int id);
void   DrawEntryMarker(ENUM_ORDER_TYPE ot,double price,datetime time,int setupId);
void   DrawSRZones();
void   DeleteSRObjects();
bool   CheckEntryPermissions(ENUM_BIAS dir,string &reason);
bool   ExecuteSetupTrade(M1Setup &s,double refPrice);
void   RefreshPanel();
void   ClearPanelObjects();
void   DetermineStatus(string &status,color &clr);
void   PnPushClosedTrade(datetime dtime,bool wasBuy,double profit);
void   UpdateChartVisuals();
bool   UpdateChartVisualsIfDirty();
void   PanelRefreshStateCache();
void   PnEnsureChrome();
void   PanelTick();
void   PrintBacktestSummary();
void   FeedPivotBullish(int idx,ENUM_SWING_TYPE type,double price,datetime time,double atrM1);
void   FeedPivotBearish(int idx,ENUM_SWING_TYPE type,double price,datetime time,double atrM1);
void   CheckSetupBreakout(int idx,MqlTick &tk);

//=========================================================================
//                     FORWARD-FREE SMALL HELPERS
//=========================================================================
string BiasToStr(ENUM_BIAS b)
{
   if(b==BIAS_BULLISH) return "BUY";
   if(b==BIAS_BEARISH) return "SELL";
   return "NONE";
}

string AlignResultToStr(ENUM_ALIGN_RESULT r)
{
   switch(r)
   {
      case ALIGN_BULLISH:  return "BUY";
      case ALIGN_BEARISH:  return "SELL";
      case ALIGN_NOFILTER: return "NO HTF FILTER";
      case ALIGN_CONFLICT: return "CONFLICT";
   }
   return "?";
}

string TFVoteStr(bool enabled,ENUM_BIAS bias)
{
   return enabled ? BiasToStr(bias) : "OFF";
}

string SetupStateToStr(ENUM_M1_SETUP_STATE s)
{
   switch(s)
   {
      case MS_WAIT_B:       return "IMPULSE (B)";
      case MS_WAIT_C:       return "PULLBACK (C)";
      case MS_WAIT_TRIGGER: return "RECOVERY (trigger search)";
      case MS_WAIT_BREAK:   return "READY (trigger locked)";
   }
   return "?";
}

string SRStateToStr(ENUM_SR_STATE s)
{
   switch(s)
   {
      case SR_DISABLED:            return "OFF";
      case SR_NEAR_SUPPORT:        return "Near Support";
      case SR_NEAR_RESISTANCE:     return "Near Resistance";
      case SR_BETWEEN:             return "Between S/R";
      case SR_BREAKING_SUPPORT:    return "Breaking Support";
      case SR_BREAKING_RESISTANCE: return "Breaking Resistance";
      case SR_NO_VALID:            return "No Valid S/R";
   }
   return "?";
}

string Trunc(string s,int n)
{
   if(n<4) return s;
   if(StringLen(s)>n) return StringSubstr(s,0,n-3)+"...";
   return s;
}

void SetLastAction(string s) { g_LastAction = s; }

void LogHTF(string msg)   { if(DebugHTF)   Print("[HTF] ",msg); }
void LogM1(string msg)    { if(DebugM1)    Print("[M1] ",msg); }
void LogTrade(string msg) { if(DebugTrade) Print(msg); }

bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &lastTime)
{
   datetime t=iTime(_Symbol,tf,0);
   if(t<=0) return false;
   if(t==lastTime) return false;
   lastTime=t;
   return true;
}

double AtrVal(int handle,int shift)
{
   if(handle==INVALID_HANDLE || shift<0) return 0.0;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(handle,0,shift,1,b)<1) return 0.0;
   if(b[0]<=0 || !MathIsValidNumber(b[0])) return 0.0;
   return b[0];
}

double AtrAvg(int handle,int period)
{
   if(handle==INVALID_HANDLE || period<1) return 0.0;
   double b[]; ArraySetAsSeries(b,true);
   int got=CopyBuffer(handle,0,1,period,b);
   if(got<1) return 0.0;
   double s=0; for(int i=0;i<got;i++) s+=b[i];
   return s/got;
}

bool InSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(g_TradingStartHour==g_TradingEndHour) return true;
   if(g_TradingStartHour<g_TradingEndHour)  return (dt.hour>=g_TradingStartHour && dt.hour<g_TradingEndHour);
   return (dt.hour>=g_TradingStartHour || dt.hour<g_TradingEndHour);
}

bool SpreadOK() { return ((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) <= g_MaxSpreadPoints); }

bool VolOK()
{
   double now=AtrVal(g_ATR_M1,1), avg=AtrAvg(g_ATR_M1,g_VolatilityLookback);
   if(avg<=0 || now<=0) return true;
   return (now <= avg*g_VolatilitySpikeLimit);
}

//=========================================================================
//              DIRECTION HIERARCHY: H1 -> M15 -> M5 -> M1
//=========================================================================
ENUM_ALIGN_RESULT AlignedBias()
{
   int total=0, bull=0, bear=0;

   if(UseH1)  { total++; if(g_H1.bias==BIAS_BULLISH) bull++;  else if(g_H1.bias==BIAS_BEARISH) bear++;  }
   if(UseM15) { total++; if(g_M15.bias==BIAS_BULLISH) bull++; else if(g_M15.bias==BIAS_BEARISH) bear++; }
   if(UseM5)  { total++; if(g_M5.bias==BIAS_BULLISH) bull++;  else if(g_M5.bias==BIAS_BEARISH) bear++;  }

   if(total==0)     return ALIGN_NOFILTER;
   if(bull==total)  return ALIGN_BULLISH;
   if(bear==total)  return ALIGN_BEARISH;
   return ALIGN_CONFLICT;
}

bool DirectionAllowed(ENUM_BIAS dir)
{
   ENUM_ALIGN_RESULT a=AlignedBias();
   if(a==ALIGN_NOFILTER) return true;
   if(a==ALIGN_BULLISH)  return (dir==BIAS_BULLISH);
   if(a==ALIGN_BEARISH)  return (dir==BIAS_BEARISH);
   return false;
}

//=========================================================================
//                          POSITION HELPERS
//=========================================================================
bool PositionIsMine()
{
   return (PositionGetString(POSITION_SYMBOL)==_Symbol &&
           PositionGetInteger(POSITION_MAGIC)==MagicNumber);
}

int CountPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionIsMine()) c++;
   }
   return c;
}

long ParseSetupIdFromComment(string comment)
{
   int p=StringFind(comment,"#");
   if(p<0) return 0;
   return (long)StringToInteger(StringSubstr(comment,p+1));
}

int FindTrack(ulong posId)
{
   for(int i=0;i<ArraySize(g_Tracks);i++)
      if(g_Tracks[i].used && g_Tracks[i].posId==posId) return i;
   return -1;
}

int TrackIndexFor(ulong posId,datetime openTime,long setupId)
{
   int idx=FindTrack(posId);
   if(idx<0)
   {
      idx=ArraySize(g_Tracks);
      if(ArrayResize(g_Tracks,idx+1)<=idx) return -1;
      g_Tracks[idx].used=true;
      g_Tracks[idx].posId=posId;
      g_Tracks[idx].setupId=setupId;
      g_Tracks[idx].minFloat=0;
      g_Tracks[idx].openTime=openTime;
   }
   return idx;
}

void TombstoneTrack(ulong posId)
{
   int idx=FindTrack(posId);
   if(idx>=0) g_Tracks[idx].used=false;
}

void CompactTracks()
{
   int w=0;
   for(int i=0;i<ArraySize(g_Tracks);i++)
      if(g_Tracks[i].used) { if(w!=i) g_Tracks[w]=g_Tracks[i]; w++; }
   ArrayResize(g_Tracks,w);
}

//=========================================================================
//                     DAILY / RISK STATE MACHINE
//=========================================================================
void CheckNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int today = dt.year*10000+dt.mon*100+dt.day;
   if(today==g_Day) return;
   g_Day=today;
   g_DayBal=AccountInfoDouble(ACCOUNT_BALANCE);
   g_DayPL=0; g_ConsLoss=0;
   g_HaltedDaily=false; g_HaltedConsec=false; g_HaltedFloat=false;
   g_PnDayPeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);   // panel: new day, new peak
   g_PnDayDDPct=0;
   g_PnHistoryDirty=true;                                  // panel: rebuild day buckets once
   g_PanelDirty=true;
}

bool EntriesHalted()
{
   return (g_HaltedDaily || g_HaltedConsec || g_HaltedFloat);
}

void UpdateDrawdownTracking()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_PeakEquity) g_PeakEquity=eq;
   if(g_PeakEquity>0)
   {
      double dd=(g_PeakEquity-eq)/g_PeakEquity*100.0;
      if(dd>g_MaxDrawdownPct) g_MaxDrawdownPct=dd;
   }

   // ---- panel-only intraday drawdown (never affects trading) ----
   if(eq>g_PnDayPeakEquity || g_PnDayPeakEquity<=0) g_PnDayPeakEquity=eq;
   if(g_PnDayPeakEquity>0)
   {
      double ddd=(g_PnDayPeakEquity-eq)/g_PnDayPeakEquity*100.0;
      if(ddd>g_PnDayDDPct) g_PnDayDDPct=ddd;
   }
}

//=========================================================================
//     GENERIC CAUSAL STRUCTURE ENGINE (used for H1, M15 and M5)
//
//  Pivot at slice index PivotSize+1 is only confirmed once `PivotSize`
//  NEWER bars exist - fully causal, no future data. shift=0 means the
//  evaluated pivot is already several CLOSED bars old, so the currently
//  forming bar never participates.
//=========================================================================
void UpdateTFStructure(TFStruct &st,ENUM_TIMEFRAMES tf,int atrHandle,int shift,bool live)
{
   if(shift<0) return;
   int need=g_PivotSize*2+2;
   double hi[],lo[]; datetime tm[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(tm,true);
   if(CopyHigh(_Symbol,tf,shift,need,hi)<need) return;
   if(CopyLow (_Symbol,tf,shift,need,lo) <need) return;
   if(CopyTime(_Symbol,tf,shift,need,tm) <need) return;

   int idx=g_PivotSize+1;
   if(idx+g_PivotSize>=need || idx-g_PivotSize<0) return;   // hard bounds guard

   bool isHigh=true, isLow=true;
   for(int k=1;k<=g_PivotSize;k++)
   {
      if(hi[idx]<=hi[idx-k]||hi[idx]<=hi[idx+k]) isHigh=false;
      if(lo[idx]>=lo[idx-k]||lo[idx]>=lo[idx+k]) isLow=false;
   }

   bool newHighPivot=false, newLowPivot=false;

   if(isHigh && tm[idx]>st.SHt)
   {
      st.PSH=st.SH; st.PSHt=st.SHt;
      st.SH=hi[idx]; st.SHt=tm[idx];
      newHighPivot=true;
   }
   if(isLow && tm[idx]>st.SLt)
   {
      st.PSL=st.SL; st.PSLt=st.SLt;
      st.SL=lo[idx]; st.SLt=tm[idx];
      newLowPivot=true;
   }

   if(!newHighPivot && !newLowPivot)
      return;

   if(live) g_HTFVisualDirty=true;   // display-only: swing markers moved

   double atr=AtrVal(atrHandle,shift+1);
   double expMin=(atr>0 && g_StructureExpansion>0) ? atr*g_StructureExpansion : 0.0;
   st.requiredExpansion=expMin;

   if(newHighPivot && st.PSH>0)
   {
      st.lastExpansion=MathAbs(st.SH-st.PSH);
      st.HH=(st.SH>st.PSH);
      st.LH=(st.SH<st.PSH);
      st.qualityOK=(expMin<=0)||(st.lastExpansion>=expMin);
   }
   else if(newLowPivot && st.PSL>0)
   {
      st.lastExpansion=MathAbs(st.SL-st.PSL);
      st.HL=(st.SL>st.PSL);
      st.LL=(st.SL<st.PSL);
      st.qualityOK=(expMin<=0)||(st.lastExpansion>=expMin);
   }

   bool bullishEvidence = st.HH && st.HL;
   bool bearishEvidence = st.LH && st.LL;

   ENUM_BIAS candidate=BIAS_NEUTRAL;
   if(bullishEvidence)      candidate=BIAS_BULLISH;
   else if(bearishEvidence) candidate=BIAS_BEARISH;

   ENUM_BIAS oldBias=st.bias;

   if(candidate==BIAS_BULLISH && st.bias!=BIAS_BULLISH)
   {
      if(st.qualityOK)
      {
         st.bias=BIAS_BULLISH;
         st.reason="Bullish structure confirmed (HH+HL)";
         if(live)
         {
            st.cntBull++;
            Print(StringFormat("[%s] BIAS -> BULLISH (SH=%.2f PSH=%.2f SL=%.2f PSL=%.2f)",
                  EnumToString(tf),st.SH,st.PSH,st.SL,st.PSL));
            OnHTFBiasChanged();
         }
      }
      else st.reason="Bullish shape present, expansion insufficient - holding prior bias";
   }
   else if(candidate==BIAS_BEARISH && st.bias!=BIAS_BEARISH)
   {
      if(st.qualityOK)
      {
         st.bias=BIAS_BEARISH;
         st.reason="Bearish structure confirmed (LH+LL)";
         if(live)
         {
            st.cntBear++;
            Print(StringFormat("[%s] BIAS -> BEARISH (SH=%.2f PSH=%.2f SL=%.2f PSL=%.2f)",
                  EnumToString(tf),st.SH,st.PSH,st.SL,st.PSL));
            OnHTFBiasChanged();
         }
      }
      else st.reason="Bearish shape present, expansion insufficient - holding prior bias";
   }
   else if(candidate==BIAS_NEUTRAL)
   {
      if(st.bias==BIAS_BULLISH)
         st.reason = (st.LH||st.LL) ? "Bullish regime weakening (contrary pivot) - holding BUY"
                                    : "Bullish regime intact";
      else if(st.bias==BIAS_BEARISH)
         st.reason = (st.HH||st.HL) ? "Bearish regime weakening (contrary pivot) - holding SELL"
                                    : "Bearish regime intact";
      else
         st.reason = "Insufficient structure";
   }
   else
      st.reason = (st.bias==BIAS_BULLISH) ? "Bullish regime persists (HH+HL maintained)"
                                          : "Bearish regime persists (LH+LL maintained)";

   if(live && oldBias!=st.bias)
      SetLastAction(EnumToString(tf)+string(" bias -> ")+BiasToStr(st.bias));
}

//=========================================================================
//   WHAT HAPPENS WHEN THE HIERARCHY MOVES
//=========================================================================
void OnHTFBiasChanged()
{
   ENUM_ALIGN_RESULT aligned=AlignedBias();

   Print(StringFormat("[ALIGN] H1=%s M15=%s M5=%s -> aligned=%s",
         TFVoteStr(UseH1,g_H1.bias),
         TFVoteStr(UseM15,g_M15.bias),TFVoteStr(UseM5,g_M5.bias),
         AlignResultToStr(aligned)));

   for(int i=0;i<ArraySize(g_Setups);i++)
   {
      if(!g_Setups[i].active) continue;
      if(!DirectionAllowed(g_Setups[i].direction))
         InvalidateM1Setup(i,"HTF alignment no longer supports "+BiasToStr(g_Setups[i].direction));
   }
   CompactSetups();
}

//=========================================================================
//                 M30 SUPPORT/RESISTANCE ENGINE  (V13.31)
//
//  MASTER SWITCH: g_SRActive. It is true ONLY when UseSRFilter==true AND
//  every S/R input validated successfully. When it is false the module
//  performs NO work at all:
//     - BuildM30SRZones()      -> returns immediately
//     - UpdateSRBreakCounters()-> returns immediately
//     - EvaluateSRState()      -> returns immediately (state=SR_DISABLED)
//     - SRBlockReasonForDirection() -> always "allow"
//     - DrawSRZones()          -> returns immediately
//  and DisableM30SR() wipes state + chart objects the moment the switch
//  is observed OFF (including a runtime change).
//
//  CAUSALITY: all zone math uses COMPLETED M30 candles only (shift>=1).
//  Live tick prices (shift 0 / MqlTick) are used only for classification
//  and for the entry filter, never to create or move zone geometry.
//=========================================================================
void ResetSRState()
{
   g_SRZoneCount=0;
   g_SRLastUpdate=0;
   g_SRState=(UseSRFilter?SR_NO_VALID:SR_DISABLED);
   g_SRNearestResistance=0;
   g_SRNearestSupport=0;
   for(int i=0;i<SR_MAX_ZONES;i++)
   {
      g_SRZones[i].upper=0;
      g_SRZones[i].lower=0;
      g_SRZones[i].isResistance=false;
      g_SRZones[i].touches=0;
      g_SRZones[i].valid=false;
      g_SRZones[i].breakCount=0;
      g_SRZones[i].formedTime=0;
   }
}

// Delete EVERY chart object this EA created for the S/R module.
// Uses a dedicated prefix so unrelated objects can never be hit.
void DeleteSRObjects()
{
   ObjectsDeleteAll(0,SR_OBJ_PREFIX);
   g_SRObjectsDrawn=false;
}

// THE single "make the module vanish" helper required by the spec.
void DisableM30SR()
{
   bool hadSomething = (g_SRActive || g_SRZoneCount>0 || g_SRObjectsDrawn);
   g_SRActive=false;
   ResetSRState();
   g_SRState=SR_DISABLED;
   DeleteSRObjects();
   g_SRVisualDirty=false;   // nothing left to draw
   g_PanelDirty=true;
   if(hadSomething)
      Print("[SR] M30 Support/Resistance module DISABLED - state cleared, chart objects removed.");
}

// Validate the S/R inputs. Returns false (module disabled) when a value
// is unusable; individual out-of-range values are clamped instead of
// silently producing nonsense.
bool ValidateSRInputs()
{
   if(!UseSRFilter) return false;

   bool ok=true;

   g_SRLookbackHours=SRLookbackHours;
   if(g_SRLookbackHours<1)    { g_SRLookbackHours=1;    Print("[SR] SRLookbackHours<1 -> clamped to 1"); }
   if(g_SRLookbackHours>240)  { g_SRLookbackHours=240;  Print("[SR] SRLookbackHours>240 -> clamped to 240"); }

   g_SRPivotWidth=SRPivotWidth;
   if(g_SRPivotWidth<1)  { g_SRPivotWidth=1;  Print("[SR] SRPivotWidth<1 -> clamped to 1"); }
   if(g_SRPivotWidth>20) { g_SRPivotWidth=20; Print("[SR] SRPivotWidth>20 -> clamped to 20"); }

   g_SRZoneATRMult=SRZoneATRMult;
   if(g_SRZoneATRMult<=0.0) { Print("[SR] SRZoneATRMult must be > 0 - S/R module disabled."); ok=false; }
   else if(g_SRZoneATRMult>10.0) { g_SRZoneATRMult=10.0; Print("[SR] SRZoneATRMult>10 -> clamped to 10"); }

   g_SRMergeATRMult=SRMergeATRMult;
   if(g_SRMergeATRMult<0.0)  { g_SRMergeATRMult=0.0;  Print("[SR] SRMergeATRMult<0 -> clamped to 0"); }
   if(g_SRMergeATRMult>10.0) { g_SRMergeATRMult=10.0; Print("[SR] SRMergeATRMult>10 -> clamped to 10"); }

   g_SRNearATRMult=SRNearATRMult;
   if(g_SRNearATRMult<=0.0) { Print("[SR] SRNearATRMult must be > 0 - S/R module disabled."); ok=false; }
   else if(g_SRNearATRMult>10.0) { g_SRNearATRMult=10.0; Print("[SR] SRNearATRMult>10 -> clamped to 10"); }

   g_SRBreakConfirmBars=SRBreakConfirmBars;
   if(g_SRBreakConfirmBars<1)   { g_SRBreakConfirmBars=1;   Print("[SR] SRBreakConfirmBars<1 -> clamped to 1"); }
   if(g_SRBreakConfirmBars>100) { g_SRBreakConfirmBars=100; Print("[SR] SRBreakConfirmBars>100 -> clamped to 100"); }

   return ok;
}

// Match a rebuilt zone against the previous zone set so live breakout
// confirmation state survives the 30-minute rebuild.
// LIMITATION (documented on purpose): zones are geometric, not identity-
// bearing objects. Matching is therefore a best-effort nearest-centre
// match of the SAME type within `tol` price units. If no old zone is
// close enough the new zone legitimately starts with breakCount=0.
int FindMatchingOldZone(SRZone &oldZones[],int oldCount,SRZone &z,double tol)
{
   int best=-1; double bestDist=tol;
   double c=(z.upper+z.lower)/2.0;
   for(int i=0;i<oldCount && i<SR_MAX_ZONES;i++)
   {
      if(oldZones[i].isResistance!=z.isResistance) continue;
      if(oldZones[i].upper<=0 && oldZones[i].lower<=0) continue;
      double oc=(oldZones[i].upper+oldZones[i].lower)/2.0;
      double d=MathAbs(oc-c);
      if(d<=bestDist) { bestDist=d; best=i; }
   }
   return best;
}

// Rebuild the M30 S/R zone list from COMPLETED M30 candles inside the
// SRLookbackHours window. Called once per new M30 bar close (and once at
// OnInit) - never on every tick.
void BuildM30SRZones()
{
   if(!g_SRActive) return;

   // --- how many CLOSED M30 bars belong to the requested window? ---
   int windowBars = g_SRLookbackHours*2;               // 2 M30 bars per hour
   if(windowBars<g_SRPivotWidth*2+1)                   // need at least one testable pivot
      windowBars=g_SRPivotWidth*2+1;

   // extra bars on BOTH sides are context only (left neighbours for the
   // oldest pivot, right neighbours to CONFIRM the newest pivot).
   int fetchCount = windowBars + g_SRPivotWidth*2;

   int avail=(int)Bars(_Symbol,PERIOD_M30);
   if(avail<fetchCount+2)
   {
      LogHTF(StringFormat("M30 S/R: only %d M30 bars available, %d needed - skipping rebuild",
             avail,fetchCount+2));
      return;
   }

   double hi[],lo[],cl[]; datetime tm[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   ArraySetAsSeries(cl,true); ArraySetAsSeries(tm,true);

   // shift=1 -> skip the currently forming M30 candle: completed bars only.
   if(CopyHigh (_Symbol,PERIOD_M30,1,fetchCount,hi)<fetchCount) return;
   if(CopyLow  (_Symbol,PERIOD_M30,1,fetchCount,lo)<fetchCount) return;
   if(CopyClose(_Symbol,PERIOD_M30,1,fetchCount,cl)<fetchCount) return;
   if(CopyTime (_Symbol,PERIOD_M30,1,fetchCount,tm)<fetchCount) return;

   double atr=AtrVal(g_ATR_M30,1);
   if(atr<=0) { LogHTF("M30 S/R: ATR(M30) unavailable, skipping rebuild"); return; }
   double half=atr*g_SRZoneATRMult;
   if(half<=0) return;

   // --- the lookback WINDOW, expressed in real candle timestamps ---
   datetime newestTime = tm[0];
   datetime windowStart= (datetime)((long)newestTime - (long)g_SRLookbackHours*3600);
   // index range that may CONTAIN pivots: needs g_SRPivotWidth neighbours
   // on both sides, and must lie inside the timestamp window.
   int firstIdx=g_SRPivotWidth;
   int lastIdx =fetchCount-1-g_SRPivotWidth;
   if(lastIdx<firstIdx) { LogHTF("M30 S/R: window too small for pivots"); return; }

   // touch counting / breakout validation must also stay inside the
   // window - find the oldest index still inside it.
   int windowOldestIdx=0;
   for(int i=0;i<fetchCount;i++)
   {
      if(tm[i]>=windowStart) windowOldestIdx=i;
      else break;
   }
   if(windowOldestIdx<firstIdx) windowOldestIdx=MathMin(firstIdx,fetchCount-1);
   if(lastIdx>windowOldestIdx)  lastIdx=windowOldestIdx;   // no pivots older than the window
   if(lastIdx<firstIdx) { LogHTF("M30 S/R: no candle inside requested lookback window"); return; }

   // --- snapshot the old zones so confirmation state can be preserved ---
   SRZone oldZones[SR_MAX_ZONES];
   int oldCount=g_SRZoneCount;
   for(int i=0;i<SR_MAX_ZONES;i++) oldZones[i]=g_SRZones[i];

   // ---- Step 1: causal fractal pivot detection inside the window ----
   SRZone raw[]; int rawCount=0;
   int rawCapacity=(lastIdx-firstIdx+1)*2+2;
   if(ArrayResize(raw,rawCapacity)<rawCapacity) return;

   for(int idx=firstIdx; idx<=lastIdx; idx++)
   {
      bool isHigh=true, isLow=true;
      for(int k=1;k<=g_SRPivotWidth;k++)
      {
         if(hi[idx]<=hi[idx-k] || hi[idx]<=hi[idx+k]) isHigh=false;
         if(lo[idx]>=lo[idx-k] || lo[idx]>=lo[idx+k]) isLow=false;
      }

      if(isHigh && rawCount<rawCapacity)
      {
         SRZone z;
         z.upper=hi[idx]+half; z.lower=hi[idx]-half;
         z.isResistance=true; z.touches=0; z.valid=true; z.breakCount=0;
         z.formedTime=tm[idx];
         // Objective validity: has a COMPLETED candle CLOSED beyond it since?
         for(int j=idx-1;j>=0;j--)
            if(cl[j]>z.upper) { z.valid=false; break; }
         // Strength: highs inside the zone, counted inside the window only.
         for(int j=0;j<=windowOldestIdx;j++)
            if(hi[j]>=z.lower && hi[j]<=z.upper) z.touches++;
         raw[rawCount++]=z;
      }
      if(isLow && rawCount<rawCapacity)
      {
         SRZone z;
         z.upper=lo[idx]+half; z.lower=lo[idx]-half;
         z.isResistance=false; z.touches=0; z.valid=true; z.breakCount=0;
         z.formedTime=tm[idx];
         for(int j=idx-1;j>=0;j--)
            if(cl[j]<z.lower) { z.valid=false; break; }
         for(int j=0;j<=windowOldestIdx;j++)
            if(lo[j]>=z.lower && lo[j]<=z.upper) z.touches++;
         raw[rawCount++]=z;
      }
   }

   // Keep only objectively-unbroken zones.
   SRZone stage1[]; int s1Count=0;
   if(rawCount>0)
   {
      if(ArrayResize(stage1,rawCount)<rawCount) return;
      for(int i=0;i<rawCount;i++)
         if(raw[i].valid) stage1[s1Count++]=raw[i];
   }

   if(s1Count<=0)
   {
      for(int i=0;i<SR_MAX_ZONES;i++) { g_SRZones[i].valid=false; }
      g_SRZoneCount=0;
      g_SRLastUpdate=TimeCurrent();
      LogHTF(StringFormat("M30 S/R rebuilt: lookback=%dh window %s..%s, pivots=%d, zones=0",
             g_SRLookbackHours,
             TimeToString(tm[MathMin(windowOldestIdx,fetchCount-1)],TIME_DATE|TIME_MINUTES),
             TimeToString(newestTime,TIME_DATE|TIME_MINUTES),
             rawCount));
      g_SRVisualDirty=true;   // redrawn by the throttled visual path
      g_PanelDirty=true;
      return;
   }

   // ---- Step 2: merge nearby/overlapping same-type zones ----
   double mergeDist=atr*g_SRMergeATRMult;
   bool used[]; ArrayResize(used,s1Count); ArrayInitialize(used,false);
   SRZone merged[]; int mCount=0;
   if(ArrayResize(merged,s1Count)<s1Count) return;

   for(int i=0;i<s1Count;i++)
   {
      if(used[i]) continue;
      SRZone z=stage1[i]; used[i]=true;
      for(int j=i+1;j<s1Count;j++)
      {
         if(used[j] || stage1[j].isResistance!=z.isResistance) continue;
         bool overlap = !(stage1[j].lower>z.upper+mergeDist || stage1[j].upper<z.lower-mergeDist);
         if(overlap)
         {
            z.lower=MathMin(z.lower,stage1[j].lower);
            z.upper=MathMax(z.upper,stage1[j].upper);
            z.touches+=stage1[j].touches;
            if(stage1[j].formedTime>z.formedTime) z.formedTime=stage1[j].formedTime;
            used[j]=true;
         }
      }
      merged[mCount++]=z;
   }

   // ---- Step 3: rank by strength (touch count) and keep the top N ----
   for(int i=0;i<mCount-1;i++)
      for(int j=i+1;j<mCount;j++)
         if(merged[j].touches>merged[i].touches)
         { SRZone t=merged[i]; merged[i]=merged[j]; merged[j]=t; }

   int keep=MathMin(mCount,SR_MAX_ZONES);
   double tol=atr*MathMax(0.25,g_SRZoneATRMult);   // matching tolerance

   int preserved=0, resurrectSuppressed=0;
   for(int i=0;i<keep;i++)
   {
      SRZone z=merged[i];
      int m=FindMatchingOldZone(oldZones,oldCount,z,tol);
      if(m>=0)
      {
         // Preserve live breakout-confirmation progress for the SAME level.
         z.breakCount=oldZones[m].breakCount;
         // A level that was already CONFIRMED broken must not come back
         // as a fresh unbroken zone just because the rebuild re-found it.
         if(!oldZones[m].valid)
         {
            z.valid=false;
            z.breakCount=MathMax(oldZones[m].breakCount,g_SRBreakConfirmBars);
            resurrectSuppressed++;
         }
         preserved++;
      }
      else
         z.breakCount=0;
      g_SRZones[i]=z;
   }
   for(int i=keep;i<SR_MAX_ZONES;i++)
   {
      g_SRZones[i].valid=false;
      g_SRZones[i].breakCount=0;
      g_SRZones[i].upper=0;
      g_SRZones[i].lower=0;
      g_SRZones[i].touches=0;
      g_SRZones[i].formedTime=0;
   }

   g_SRZoneCount=keep;
   g_SRLastUpdate=TimeCurrent();

   LogHTF(StringFormat("M30 S/R rebuilt: lookback=%dh  window %s .. %s  candlesInWindow=%d  pivots=%d  zones=%d (state preserved on %d, broken kept broken on %d)  ATR=%.2f",
          g_SRLookbackHours,
          TimeToString(tm[MathMin(windowOldestIdx,fetchCount-1)],TIME_DATE|TIME_MINUTES),
          TimeToString(newestTime,TIME_DATE|TIME_MINUTES),
          windowOldestIdx+1,rawCount,g_SRZoneCount,preserved,resurrectSuppressed,atr));

   g_SRVisualDirty=true;   // redrawn by the throttled visual path
   g_PanelDirty=true;
}

// Once per COMPLETED M1 candle: advance each zone's breakout-confirmation
// counter using the CLOSED M1 bar (shift 1) - never the forming bar.
void UpdateSRBreakCounters()
{
   if(!g_SRActive) return;
   if(g_SRZoneCount<=0) return;

   double closePrice=iClose(_Symbol,PERIOD_M1,1);
   if(closePrice<=0) return;

   for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
   {
      if(!g_SRZones[i].valid) continue;
      bool beyond = g_SRZones[i].isResistance ? (closePrice>g_SRZones[i].upper)
                                              : (closePrice<g_SRZones[i].lower);
      if(beyond)
      {
         g_SRZones[i].breakCount++;
         if(g_SRZones[i].breakCount>=g_SRBreakConfirmBars)
         {
            g_SRZones[i].valid=false;
            LogHTF(StringFormat("M30 S/R zone[%d] (%s %.2f-%.2f) CONFIRMED BROKEN after %d closes",
                   i,(g_SRZones[i].isResistance?"R":"S"),g_SRZones[i].lower,g_SRZones[i].upper,
                   g_SRZones[i].breakCount));
         }
      }
      else
         g_SRZones[i].breakCount=0;
   }
}

//-------------------------------------------------------------------------
//  THE single source of truth for S/R trade permission.
//  BUY  decisions use ASK (the price a long actually pays)
//  SELL decisions use BID (the price a short actually receives)
//  A BUY is blocked only by RESISTANCE, a SELL only by SUPPORT:
//     - price within SRNearATRMult*ATR(M30) of the zone (or inside it), or
//     - price beyond the zone but the breakout is NOT yet confirmed.
//  A confirmed breakout retires the zone (valid=false) so the obstacle
//  disappears and trading resumes.
//  Returns true when the direction is BLOCKED, with a reason.
//-------------------------------------------------------------------------
bool SRBlockReasonForDirection(ENUM_BIAS dir,string &reason)
{
   reason="";
   if(!g_SRActive)      return false;
   if(g_SRZoneCount<=0) return false;

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) return false;   // fail safe: never block
   double price=(dir==BIAS_BULLISH)?tk.ask:tk.bid;
   if(price<=0) return false;

   double atr=AtrVal(g_ATR_M30,1);                 // completed-bar ATR (causal)
   if(atr<=0) return false;                        // fail safe
   double nearDist=atr*g_SRNearATRMult;

   for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
   {
      if(!g_SRZones[i].valid) continue;
      if(dir==BIAS_BULLISH && !g_SRZones[i].isResistance) continue;
      if(dir==BIAS_BEARISH &&  g_SRZones[i].isResistance) continue;

      double up=g_SRZones[i].upper, lo=g_SRZones[i].lower;

      if(dir==BIAS_BULLISH)
      {
         if(price>up)                                    // above an unconfirmed resistance
         { reason="Breaking Resistance (unconfirmed)"; return true; }
         if(price>=lo)                                   // inside the zone
         { reason="Near Resistance"; return true; }
         if((lo-price)<=nearDist)                        // approaching from below
         { reason="Near Resistance"; return true; }
      }
      else if(dir==BIAS_BEARISH)
      {
         if(price<lo)
         { reason="Breaking Support (unconfirmed)"; return true; }
         if(price<=up)
         { reason="Near Support"; return true; }
         if((price-up)<=nearDist)
         { reason="Near Support"; return true; }
      }
   }
   return false;
}

// Thin wrapper kept for readability at the call sites.
bool SRFilterAllows(ENUM_BIAS dir,string &reason)
{
   return !SRBlockReasonForDirection(dir,reason);
}

// Display-only classification of the CURRENT price against the zones.
// Uses exactly the same prices/ATR as the filter so the panel and the
// filter can never disagree.
void EvaluateSRState()
{
   if(!g_SRActive)
   {
      g_SRState=SR_DISABLED;
      g_SRNearestResistance=0;
      g_SRNearestSupport=0;
      return;
   }

   g_SRNearestResistance=0;
   g_SRNearestSupport=0;

   if(g_SRZoneCount<=0) { g_SRState=SR_NO_VALID; return; }

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) { g_SRState=SR_NO_VALID; return; }

   double atr=AtrVal(g_ATR_M30,1);
   double nearDist=(atr>0) ? atr*g_SRNearATRMult : 0.0;

   double bestResDist=DBL_MAX, bestSupDist=DBL_MAX;
   int    bestResIdx=-1, bestSupIdx=-1;
   bool   anyValid=false, breakingRes=false, breakingSup=false;

   for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
   {
      if(!g_SRZones[i].valid) continue;
      anyValid=true;

      if(g_SRZones[i].isResistance)
      {
         double p=tk.ask;                                   // long-relevant price
         double dist=(p<g_SRZones[i].lower) ? (g_SRZones[i].lower-p) : 0.0;
         if(dist<bestResDist) { bestResDist=dist; bestResIdx=i; }
         if(p>g_SRZones[i].upper) breakingRes=true;
      }
      else
      {
         double p=tk.bid;                                   // short-relevant price
         double dist=(p>g_SRZones[i].upper) ? (p-g_SRZones[i].upper) : 0.0;
         if(dist<bestSupDist) { bestSupDist=dist; bestSupIdx=i; }
         if(p<g_SRZones[i].lower) breakingSup=true;
      }
   }

   if(bestResIdx>=0) g_SRNearestResistance=(g_SRZones[bestResIdx].upper+g_SRZones[bestResIdx].lower)/2.0;
   if(bestSupIdx>=0) g_SRNearestSupport   =(g_SRZones[bestSupIdx].upper+g_SRZones[bestSupIdx].lower)/2.0;

   if(!anyValid)   { g_SRState=SR_NO_VALID; return; }
   if(breakingRes) { g_SRState=SR_BREAKING_RESISTANCE; return; }
   if(breakingSup) { g_SRState=SR_BREAKING_SUPPORT; return; }

   bool nearRes=(bestResIdx>=0 && bestResDist<=nearDist);
   bool nearSup=(bestSupIdx>=0 && bestSupDist<=nearDist);

   if(nearRes && nearSup) { g_SRState=(bestResDist<=bestSupDist)?SR_NEAR_RESISTANCE:SR_NEAR_SUPPORT; return; }
   if(nearRes) { g_SRState=SR_NEAR_RESISTANCE; return; }
   if(nearSup) { g_SRState=SR_NEAR_SUPPORT; return; }

   g_SRState=SR_BETWEEN;
}

// Panel helper: is a trigger-locked setup blocked by the S/R filter right
// now? Uses the SAME function as CheckEntryPermissions -> always
// consistent. Display-only; never changes trading behavior.
bool SRIsBlockingReadySetup(string &reason)
{
   reason="";
   if(!g_SRActive) return false;
   for(int i=0;i<ArraySize(g_Setups);i++)
   {
      if(!g_Setups[i].active || g_Setups[i].state!=MS_WAIT_BREAK) continue;
      if(SRBlockReasonForDirection(g_Setups[i].direction,reason))
         return true;
   }
   reason="";
   return false;
}

// Called every tick: keeps the runtime ON/OFF switch honest.
void SyncSRModuleSwitch()
{
   if(!UseSRFilter)
   {
      if(g_SRActive || g_SRZoneCount>0 || g_SRObjectsDrawn)
         DisableM30SR();
      return;
   }

   if(!g_SRActive)
   {
      // Switched ON at runtime (or re-enabled after validation): rebuild.
      if(ValidateSRInputs())
      {
         g_SRActive=true;
         ResetSRState();
         g_SRState=SR_NO_VALID;
         Print("[SR] M30 Support/Resistance module ENABLED - rebuilding zones.");
         BuildM30SRZones();
      }
      else
         DisableM30SR();
   }

   // Debug drawing turned off at runtime: remove leftover S/R objects.
   if(!DebugMode && g_SRObjectsDrawn)
      DeleteSRObjects();
}

//=========================================================================
//              M1 CAUSAL PIVOT DETECTION (same window logic)
//=========================================================================
void DetectM1Pivots(int shift,
                    bool &foundLow,double &lowVal,datetime &lowTime,
                    bool &foundHigh,double &highVal,datetime &highTime)
{
   foundLow=false; foundHigh=false;
   lowVal=0; highVal=0; lowTime=0; highTime=0;
   if(shift<0) return;

   int need=g_PivotSize*2+2;
   double hi[],lo[]; datetime tm[];
   ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true); ArraySetAsSeries(tm,true);
   if(CopyHigh(_Symbol,PERIOD_M1,shift,need,hi)<need) return;
   if(CopyLow (_Symbol,PERIOD_M1,shift,need,lo) <need) return;
   if(CopyTime(_Symbol,PERIOD_M1,shift,need,tm) <need) return;

   int idx=g_PivotSize+1;
   if(idx+g_PivotSize>=need || idx-g_PivotSize<0) return;

   bool isHigh=true, isLow=true;
   for(int k=1;k<=g_PivotSize;k++)
   {
      if(hi[idx]<=hi[idx-k]||hi[idx]<=hi[idx+k]) isHigh=false;
      if(lo[idx]>=lo[idx-k]||lo[idx]>=lo[idx+k]) isLow=false;
   }
   if(isHigh){ foundHigh=true; highVal=hi[idx]; highTime=tm[idx]; }
   if(isLow) { foundLow=true;  lowVal=lo[idx];  lowTime=tm[idx];  }
}

//=========================================================================
//                     MULTI-SETUP COLLECTION UTILITIES
//=========================================================================
int CountActiveSetups()
{
   int c=0;
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active) c++;
   return c;
}

int CountReadySetups()
{
   int c=0;
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active && g_Setups[i].state==MS_WAIT_BREAK) c++;
   return c;
}

void CompactSetups()
{
   int w=0;
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active) { if(w!=i) g_Setups[w]=g_Setups[i]; w++; }
   ArrayResize(g_Setups,w);
}

bool SetupWithAnchorExists(ENUM_BIAS dir,datetime aTime)
{
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active && g_Setups[i].direction==dir && g_Setups[i].At==aTime)
         return true;
   return false;
}

//=========================================================================
//                         SETUP LIFECYCLE
//=========================================================================
void CreateM1Setup(ENUM_BIAS dir,double aPrice,datetime aTime)
{
   if(aPrice<=0 || aTime<=0) return;

   if(CountActiveSetups()>=g_MaxActiveSetups)
   {
      g_Cnt_SetupsSkippedCap++;
      LogM1(StringFormat("Setup cap (%d) reached - pivot NOT seeded",g_MaxActiveSetups));
      return;
   }
   if(SetupWithAnchorExists(dir,aTime))
      return;

   int n=ArraySize(g_Setups);
   if(ArrayResize(g_Setups,n+1)<=n) return;

   M1Setup s;
   s.id                = ++g_NextSetupId;
   s.active            = true;
   s.direction         = dir;
   s.state             = MS_WAIT_B;
   s.A                 = aPrice;
   s.B                 = 0; s.C=0; s.trigger=0;
   s.At                = aTime;
   s.Bt                = 0; s.Ct=0; s.triggerTime=0;
   s.crossActive       = false;
   s.breakoutConsumed  = false;
   s.impulseDistance   = 0;
   s.pullbackDistance  = 0;
   s.breakoutQuality   = "-";
   s.entryStatus       = "";
   s.blockReason       = "";
   s.createdTime       = TimeCurrent();

   g_Setups[n]=s;
   g_Cnt_SetupsCreated++;
   g_SetupVisualDirty=true; g_PanelDirty=true;

   LogM1(StringFormat("New %s setup #%d seeded at A=%.2f @ %s",
         BiasToStr(dir),(int)s.id,aPrice,TimeToString(aTime,TIME_MINUTES)));

   g_SetupVisualDirty=true;
}

void InvalidateM1Setup(int idx,string reason)
{
   if(idx<0 || idx>=ArraySize(g_Setups)) return;
   if(!g_Setups[idx].active) return;

   string dir=BiasToStr(g_Setups[idx].direction);
   long   id =g_Setups[idx].id;

   g_Cnt_SetupsInvalidated++;
   LogM1(StringFormat("Setup #%d INVALIDATED: %s",(int)id,reason));
   SetLastAction(dir+" #"+IntegerToString((int)id)+" invalidated: "+reason);

   DeleteSetupVisuals((int)id);
   g_Setups[idx].active=false;
   g_SetupVisualDirty=true; g_PanelDirty=true;
}

void ExpireOldSetups()
{
   if(g_SetupExpiryMinutes<=0) return;
   datetime now=TimeCurrent();
   for(int i=0;i<ArraySize(g_Setups);i++)
   {
      if(!g_Setups[i].active) continue;
      if((long)now - (long)g_Setups[i].createdTime > (long)g_SetupExpiryMinutes*60)
      {
         g_Cnt_SetupsExpired++;
         InvalidateM1Setup(i,"setup expired (age limit)");
      }
   }
}

//=========================================================================
//     PER-SETUP EVENT-DRIVEN A/B/C STATE MACHINE (multi-instance)
//=========================================================================
void FeedPivotToSetup(int idx,ENUM_SWING_TYPE type,double price,datetime time,double atrM1)
{
   if(idx<0 || idx>=ArraySize(g_Setups)) return;
   if(!g_Setups[idx].active) return;

   if(g_Setups[idx].direction==BIAS_BULLISH)
      FeedPivotBullish(idx,type,price,time,atrM1);
   else if(g_Setups[idx].direction==BIAS_BEARISH)
      FeedPivotBearish(idx,type,price,time,atrM1);
}

//------------------------------------------------------------- BULLISH ---
void FeedPivotBullish(int idx,ENUM_SWING_TYPE type,double price,datetime time,double atrM1)
{
   M1Setup s=g_Setups[idx];

   switch(s.state)
   {
      case MS_WAIT_B:
         if(type==SWING_HIGH && time>s.At && price>s.A)
         {
            s.B=price; s.Bt=time;
            s.impulseDistance=s.B-s.A;
            s.state=MS_WAIT_C;
            LogM1(StringFormat("#%d BULL B=%.2f (impulse %.2f->%.2f)",(int)s.id,s.B,s.A,s.B));
            g_SetupVisualDirty=true;
         }
         break;

      case MS_WAIT_C:
         if(type==SWING_LOW && time>s.Bt)
         {
            if(price<=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"pullback broke <= A");
               return;
            }
            if(s.Ct==0 || price<s.C)
            {
               s.C=price; s.Ct=time;
               g_SetupVisualDirty=true;
            }
            double pullback=s.B-s.C;
            s.pullbackDistance=pullback;
            if(atrM1>0 && pullback>=atrM1*g_MinPullback)
            {
               s.state=MS_WAIT_TRIGGER;
               LogM1(StringFormat("#%d BULL C qualified=%.2f pullback=%.2f ATR=%.2f",(int)s.id,s.C,pullback,atrM1));
            }
         }
         else if(type==SWING_HIGH && time>s.Bt && price>s.B)
         {
            s.B=price; s.Bt=time; s.C=0; s.Ct=0;
            s.impulseDistance=s.B-s.A;
            LogM1(StringFormat("#%d BULL B extended -> %.2f",(int)s.id,s.B));
            g_SetupVisualDirty=true;
         }
         break;

      case MS_WAIT_TRIGGER:
         if(type==SWING_LOW && time>s.Ct)
         {
            if(price<=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"pullback deepened <= A");
               return;
            }
            if(price<s.C)
            {
               s.C=price; s.Ct=time;
               s.pullbackDistance=s.B-s.C;
               g_SetupVisualDirty=true;
            }
         }
         else if(type==SWING_HIGH && time>s.Ct && price>s.C)
         {
            s.trigger=price; s.triggerTime=time;
            s.state=MS_WAIT_BREAK;
            s.crossActive=false;
            s.breakoutConsumed=false;   // fresh trigger => fresh one-shot episode
            s.entryStatus="WAITING";
            s.blockReason="";
            g_Cnt_Triggers++;
            LogM1(StringFormat("#%d BULL TRIGGER LOCKED=%.2f",(int)s.id,s.trigger));
            SetLastAction("BUY #"+IntegerToString((int)s.id)+" trigger locked");
            g_SetupVisualDirty=true; g_PanelDirty=true;
         }
         break;

      case MS_WAIT_BREAK:
         if(type==SWING_LOW && time>s.Ct)
         {
            if(price<=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"broke <= A while waiting for break");
               return;
            }
            if(price<s.C)
            {
               s.C=price; s.Ct=time;
               s.pullbackDistance=s.B-s.C;
               s.trigger=0; s.triggerTime=0;
               s.state=MS_WAIT_TRIGGER;
               s.crossActive=false;
               s.breakoutConsumed=false;
               s.entryStatus="";
               s.blockReason="";
               LogM1(StringFormat("#%d BULL recovery failed -> C=%.2f (trigger reset)",(int)s.id,s.C));
               g_SetupVisualDirty=true;
               DeleteSetupTrigger((int)s.id);
               g_SetupVisualDirty=true; g_PanelDirty=true;
            }
         }
         break;
   }

   g_Setups[idx]=s;
}

//------------------------------------------------------------- BEARISH ---
void FeedPivotBearish(int idx,ENUM_SWING_TYPE type,double price,datetime time,double atrM1)
{
   M1Setup s=g_Setups[idx];

   switch(s.state)
   {
      case MS_WAIT_B:
         if(type==SWING_LOW && time>s.At && price<s.A)
         {
            s.B=price; s.Bt=time;
            s.impulseDistance=s.A-s.B;
            s.state=MS_WAIT_C;
            LogM1(StringFormat("#%d BEAR B=%.2f (impulse %.2f->%.2f)",(int)s.id,s.B,s.A,s.B));
            g_SetupVisualDirty=true;
         }
         break;

      case MS_WAIT_C:
         if(type==SWING_HIGH && time>s.Bt)
         {
            if(price>=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"pullback broke >= A");
               return;
            }
            if(s.Ct==0 || price>s.C)
            {
               s.C=price; s.Ct=time;
               g_SetupVisualDirty=true;
            }
            double pullback=s.C-s.B;
            s.pullbackDistance=pullback;
            if(atrM1>0 && pullback>=atrM1*g_MinPullback)
            {
               s.state=MS_WAIT_TRIGGER;
               LogM1(StringFormat("#%d BEAR C qualified=%.2f pullback=%.2f ATR=%.2f",(int)s.id,s.C,pullback,atrM1));
            }
         }
         else if(type==SWING_LOW && time>s.Bt && price<s.B)
         {
            s.B=price; s.Bt=time; s.C=0; s.Ct=0;
            s.impulseDistance=s.A-s.B;
            LogM1(StringFormat("#%d BEAR B extended -> %.2f",(int)s.id,s.B));
            g_SetupVisualDirty=true;
         }
         break;

      case MS_WAIT_TRIGGER:
         if(type==SWING_HIGH && time>s.Ct)
         {
            if(price>=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"pullback deepened >= A");
               return;
            }
            if(price>s.C)
            {
               s.C=price; s.Ct=time;
               s.pullbackDistance=s.C-s.B;
               g_SetupVisualDirty=true;
            }
         }
         else if(type==SWING_LOW && time>s.Ct && price<s.C)
         {
            s.trigger=price; s.triggerTime=time;
            s.state=MS_WAIT_BREAK;
            s.crossActive=false;
            s.breakoutConsumed=false;
            s.entryStatus="WAITING";
            s.blockReason="";
            g_Cnt_Triggers++;
            LogM1(StringFormat("#%d BEAR TRIGGER LOCKED=%.2f",(int)s.id,s.trigger));
            SetLastAction("SELL #"+IntegerToString((int)s.id)+" trigger locked");
            g_SetupVisualDirty=true; g_PanelDirty=true;
         }
         break;

      case MS_WAIT_BREAK:
         if(type==SWING_HIGH && time>s.Ct)
         {
            if(price>=s.A)
            {
               g_Setups[idx]=s;
               InvalidateM1Setup(idx,"broke >= A while waiting for break");
               return;
            }
            if(price>s.C)
            {
               s.C=price; s.Ct=time;
               s.pullbackDistance=s.C-s.B;
               s.trigger=0; s.triggerTime=0;
               s.state=MS_WAIT_TRIGGER;
               s.crossActive=false;
               s.breakoutConsumed=false;
               s.entryStatus="";
               s.blockReason="";
               LogM1(StringFormat("#%d BEAR recovery failed -> C=%.2f (trigger reset)",(int)s.id,s.C));
               g_SetupVisualDirty=true;
               DeleteSetupTrigger((int)s.id);
               g_SetupVisualDirty=true; g_PanelDirty=true;
            }
         }
         break;
   }

   g_Setups[idx]=s;
}

//=========================================================================
//       M1 PIVOT PROCESSING - one new pivot = broadcast + maybe seed
//=========================================================================
void ProcessM1PivotsAtShift(int shift,bool live)
{
   if(!UseM1) return;

   bool fLow,fHigh; double lowV=0,highV=0; datetime lowT=0,highT=0;
   DetectM1Pivots(shift,fLow,lowV,lowT,fHigh,highV,highT);

   double atrM1=AtrVal(g_ATR_M1,shift+1);
   ENUM_ALIGN_RESULT aligned=AlignedBias();

   if(fLow && lowT>g_LastM1SwingLowTime)
   {
      g_LastM1SwingLowTime=lowT;
      g_Cnt_M1PivotLow++;

      for(int i=0;i<ArraySize(g_Setups);i++)
         FeedPivotToSetup(i,SWING_LOW,lowV,lowT,atrM1);
      CompactSetups();

      if(aligned==ALIGN_BULLISH || aligned==ALIGN_NOFILTER)
         CreateM1Setup(BIAS_BULLISH,lowV,lowT);
   }

   if(fHigh && highT>g_LastM1SwingHighTime)
   {
      g_LastM1SwingHighTime=highT;
      g_Cnt_M1PivotHigh++;

      for(int i=0;i<ArraySize(g_Setups);i++)
         FeedPivotToSetup(i,SWING_HIGH,highV,highT,atrM1);
      CompactSetups();

      if(aligned==ALIGN_BEARISH || aligned==ALIGN_NOFILTER)
         CreateM1Setup(BIAS_BEARISH,highV,highT);
   }
}

//=========================================================================
//        BREAKOUT QUALITY CLASSIFIER (diagnostic only - NEVER gates)
//=========================================================================
bool EvaluateBreakoutQuality(ENUM_ORDER_TYPE ot,double o,double h,double l,double c,
                             double &bodyOut,double &rangeOut,double &ratioOut,string &reasonOut)
{
   bodyOut =MathAbs(c-o);
   rangeOut=h-l;

   if(rangeOut<=0)
   {
      ratioOut=0;
      reasonOut="zero-range candle";
      return false;
   }
   ratioOut=bodyOut/rangeOut;

   bool directionOK=(ot==ORDER_TYPE_BUY) ? (c>o) : (c<o);
   if(!directionOK)
   {
      reasonOut="candle color against breakout direction";
      return false;
   }
   if(ratioOut<g_BreakoutBodyMinimum)
   {
      reasonOut=StringFormat("body ratio %.2f < min %.2f",ratioOut,g_BreakoutBodyMinimum);
      return false;
   }
   reasonOut="PASS";
   return true;
}

//=========================================================================
//          TICK-LEVEL PER-SETUP INVALIDATION + BREAKOUT ENGINE
//=========================================================================
void ProcessSetupsOnTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol,tk)) return;

   ExpireOldSetups();

   for(int i=0;i<ArraySize(g_Setups);i++)
   {
      if(!g_Setups[i].active) continue;

      if(g_Setups[i].direction==BIAS_BULLISH && tk.bid<=g_Setups[i].A)
      {
         InvalidateM1Setup(i,"price traded back through A (live)");
         continue;
      }
      if(g_Setups[i].direction==BIAS_BEARISH && tk.ask>=g_Setups[i].A)
      {
         InvalidateM1Setup(i,"price traded back through A (live)");
         continue;
      }

      if(g_Setups[i].state!=MS_WAIT_BREAK || g_Setups[i].trigger<=0)
         continue;

      CheckSetupBreakout(i,tk);
   }

   CompactSetups();
}

void CheckSetupBreakout(int idx,MqlTick &tk)
{
   if(idx<0 || idx>=ArraySize(g_Setups)) return;

   M1Setup s=g_Setups[idx];
   string dir=BiasToStr(s.direction);

   double priceNow=(s.direction==BIAS_BULLISH) ? tk.ask : tk.bid;
   if(priceNow<=0) return;

   bool beyond=(s.direction==BIAS_BULLISH) ? (priceNow>s.trigger) : (priceNow<s.trigger);

   if(!beyond)
   {
      s.crossActive=false;
      if(!s.breakoutConsumed) s.entryStatus="WAITING";
      g_Setups[idx]=s;
      return;
   }

   if(s.crossActive || s.breakoutConsumed)
   {
      g_Setups[idx]=s;
      return;
   }

   s.crossActive=true;
   s.breakoutConsumed=true;     // one setup + one trigger = ONE attempt
   g_Cnt_Breakouts++;

   LogTrade(StringFormat("%s breakout detected on setup #%d. Trigger = %.5f  Price = %.5f",
            dir,(int)s.id,s.trigger,priceNow));

   // ---- Quality = diagnostic classification ONLY. Never gates entry. ----
   double o0=iOpen(_Symbol,PERIOD_M1,0);
   double h0=iHigh(_Symbol,PERIOD_M1,0);
   double l0=iLow (_Symbol,PERIOD_M1,0);
   double c0=priceNow;
   if(o0<=0) o0=c0;
   if(h0<c0) h0=c0;
   if(l0>c0 || l0<=0) l0=c0;

   ENUM_ORDER_TYPE ot=(s.direction==BIAS_BULLISH) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double body,range,ratio; string qReason;
   bool qualityOK=EvaluateBreakoutQuality(ot,o0,h0,l0,c0,body,range,ratio,qReason);

   s.breakoutQuality=qualityOK ? "PASS" : "WEAK";
   if(qualityOK) g_Cnt_BOQualityPass++; else g_Cnt_BOQualityWeak++;

   s.entryStatus="ATTEMPT";
   SetLastAction(dir+" #"+IntegerToString((int)s.id)+" breakout - attempting entry");

   string blockReason="";
   if(CheckEntryPermissions(s.direction,blockReason))
   {
      g_Cnt_EntryAttempts++;
      if(ExecuteSetupTrade(s,priceNow))
      {
         s.entryStatus="EXECUTED";
         g_Cnt_EntryExecuted++;
      }
      else
      {
         s.entryStatus="FAILED";
         g_Cnt_EntryFailed++;
      }
   }
   else
   {
      g_Cnt_EntryBlocked++;
      s.entryStatus="BLOCKED";
      s.blockReason=blockReason;
      LogTrade(dir+" #"+IntegerToString((int)s.id)+" entry blocked: "+blockReason);
      SetLastAction(dir+" #"+IntegerToString((int)s.id)+" blocked: "+blockReason);
   }

   // Setup has produced its one episode -> retire it (no stale state can
   // survive; a new setup will be seeded by the next qualifying pivot).
   DeleteSetupVisuals((int)s.id);
   s.active=false;
   g_SetupVisualDirty=true; g_PanelDirty=true;
   g_Setups[idx]=s;
}

//=========================================================================
//             ENTRY PERMISSIONS (entry filters ONLY)
//=========================================================================
bool CheckEntryPermissions(ENUM_BIAS dir,string &reason)
{
   reason="";
   if(!g_InitComplete)                 { reason="initialization incomplete";   return false; }
   if(g_HaltedDaily)                   { reason="daily loss halt";             return false; }
   if(g_HaltedConsec)                  { reason="consecutive loss halt";       return false; }
   if(g_HaltedFloat)                   { reason="floating loss halt";          return false; }
   if(!DirectionAllowed(dir))          { reason="HTF alignment lost";          return false; }
   if(CountPositions()>=g_MaxOpenTrades){ reason="position limit";             return false; }
   if(!InSession())                    { reason="outside session";             return false; }
   if(!SpreadOK())                     { reason="spread too high";             return false; }
   if(!VolOK())                        { reason="volatility spike";            return false; }

   // M30 Support/Resistance filter - completely inert when g_SRActive==false.
   if(g_SRActive)
   {
      string srReason;
      if(SRBlockReasonForDirection(dir,srReason)) { reason=srReason; return false; }
   }

   return true;
}

//=========================================================================
//      FIXED-LOT VOLUME MODEL (no stop => no stop-based risk sizing)
//=========================================================================
double NormalizeLot(double lot,double &minL,double &maxL,double &step)
{
   minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   double v=MathFloor(lot/step)*step;
   v=NormalizeDouble(v,2);
   if(maxL>0 && v>maxL) v=maxL;
   return v;
}

string TradeComment(long setupId)
{
   return "V13#"+IntegerToString((int)setupId);
}

//=========================================================================
//                    BROKER RETCODE / PERMISSION HELPERS
//=========================================================================
string RetcodeToString(int code)
{
   switch(code)
   {
      case TRADE_RETCODE_REQUOTE:            return "REQUOTE";
      case TRADE_RETCODE_REJECT:             return "REJECT";
      case TRADE_RETCODE_CANCEL:             return "CANCEL (client)";
      case TRADE_RETCODE_PLACED:             return "PLACED";
      case TRADE_RETCODE_DONE:               return "DONE";
      case TRADE_RETCODE_DONE_PARTIAL:       return "DONE_PARTIAL";
      case TRADE_RETCODE_ERROR:              return "ERROR (processing)";
      case TRADE_RETCODE_TIMEOUT:            return "TIMEOUT";
      case TRADE_RETCODE_INVALID:            return "INVALID_REQUEST";
      case TRADE_RETCODE_INVALID_VOLUME:     return "INVALID_VOLUME";
      case TRADE_RETCODE_INVALID_PRICE:      return "INVALID_PRICE";
      case TRADE_RETCODE_INVALID_STOPS:      return "INVALID_STOPS";
      case TRADE_RETCODE_TRADE_DISABLED:     return "TRADE_DISABLED";
      case TRADE_RETCODE_MARKET_CLOSED:      return "MARKET_CLOSED";
      case TRADE_RETCODE_NO_MONEY:           return "NO_MONEY (insufficient margin)";
      case TRADE_RETCODE_PRICE_CHANGED:      return "PRICE_CHANGED";
      case TRADE_RETCODE_PRICE_OFF:          return "PRICE_OFF (no quotes)";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "INVALID_EXPIRATION";
      case TRADE_RETCODE_ORDER_CHANGED:      return "ORDER_CHANGED";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:  return "TOO_MANY_REQUESTS";
      case TRADE_RETCODE_NO_CHANGES:         return "NO_CHANGES";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "SERVER_DISABLES_AUTOTRADING";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "CLIENT_DISABLES_AUTOTRADING";
      case TRADE_RETCODE_LOCKED:             return "LOCKED";
      case TRADE_RETCODE_FROZEN:             return "FROZEN";
      case TRADE_RETCODE_INVALID_FILL:       return "INVALID_FILL (unsupported filling mode)";
      case TRADE_RETCODE_CONNECTION:         return "NO_CONNECTION";
      case TRADE_RETCODE_ONLY_REAL:          return "ONLY_REAL_ACCOUNTS";
      case TRADE_RETCODE_LIMIT_ORDERS:       return "LIMIT_ORDERS_REACHED";
      case TRADE_RETCODE_LIMIT_VOLUME:       return "LIMIT_VOLUME_REACHED";
      case TRADE_RETCODE_INVALID_ORDER:      return "INVALID_ORDER_TYPE";
      case TRADE_RETCODE_POSITION_CLOSED:    return "POSITION_ALREADY_CLOSED";
      default: return StringFormat("UNKNOWN_RETCODE(%d)",code);
   }
}

bool PreTradePermissionCheck(string &reason)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   { reason="Algo trading disabled in terminal (AutoTrading button off)"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   { reason="EA trading not allowed ('Allow Algo Trading' unchecked for this EA)"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   { reason="Account trading disabled by broker"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   { reason="Expert Advisor trading disabled on this account"; return false; }
   ENUM_SYMBOL_TRADE_MODE tm=(ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(tm==SYMBOL_TRADE_MODE_DISABLED)
   { reason="Symbol trading disabled by broker"; return false; }
   if(tm==SYMBOL_TRADE_MODE_CLOSEONLY)
   { reason="Symbol is CLOSE-ONLY - cannot open new positions"; return false; }
   return true;
}

void RegisterRejectionCategory(ENUM_REJECT_CAT cat)
{
   switch(cat)
   {
      case REJ_LOT:      g_Cnt_RejectLot++;      break;
      case REJ_STOPS:    g_Cnt_RejectStops++;    break;
      case REJ_MARGIN:   g_Cnt_RejectMargin++;   break;
      case REJ_FILLING:  g_Cnt_RejectFilling++;  break;
      case REJ_BROKER:   g_Cnt_RejectBroker++;   break;
      default:           g_Cnt_RejectOther++;    break;
   }
}

//=========================================================================
//        ORDER SUBMISSION WITH FILLING-MODE FALLBACK (FOK/IOC/RETURN)
//=========================================================================
bool SubmitOrder(MqlTradeRequest &req,MqlTradeResult &res,string &fillingUsed,
                 int &lastRetcode,string &lastErrorText)
{
   ENUM_ORDER_TYPE_FILLING tryOrder[3] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   int fillMask=(int)SymbolInfoInteger(req.symbol,SYMBOL_FILLING_MODE);

   fillingUsed="";
   lastRetcode=0;
   lastErrorText="no filling mode attempted";

   for(int i=0;i<3;i++)
   {
      ENUM_ORDER_TYPE_FILLING candidate=tryOrder[i];
      if(fillMask!=0)
      {
         if(candidate==ORDER_FILLING_FOK && (fillMask & SYMBOL_FILLING_FOK)==0) continue;
         if(candidate==ORDER_FILLING_IOC && (fillMask & SYMBOL_FILLING_IOC)==0) continue;
      }

      req.type_filling=candidate;
      ZeroMemory(res);

      if(!OrderSend(req,res))
      {
         int err=GetLastError();
         lastErrorText="OrderSend false, GetLastError="+IntegerToString(err);
         ResetLastError();
         continue;
      }

      lastRetcode=(int)res.retcode;

      if(res.retcode==TRADE_RETCODE_DONE || res.retcode==TRADE_RETCODE_DONE_PARTIAL)
      {
         fillingUsed=EnumToString(candidate);
         return true;
      }
      lastErrorText=RetcodeToString((int)res.retcode)+" | "+res.comment;
   }
   return false;
}

//=========================================================================
//                    ENTRY EXECUTION (fixed lot, NO SL/TP)
//=========================================================================
bool ExecuteSetupTrade(M1Setup &s,double refPrice)
{
   string dir=(s.direction==BIAS_BULLISH)?"BUY":"SELL";
   string cmt=TradeComment(s.id);

   string permReason;
   if(!PreTradePermissionCheck(permReason))
   {
      RegisterRejectionCategory(REJ_BROKER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: %s",dir,(int)s.id,permReason);
      SetLastAction(dir+" rejected: "+permReason);
      return false;
   }

   double minL,maxL,step;
   double lot=NormalizeLot(g_LotSize,minL,maxL,step);
   if(lot<minL || lot<=0)
   {
      RegisterRejectionCategory(REJ_LOT);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: fixed lot %.4f below broker minimum %.2f (step %.2f)",
                  dir,(int)s.id,g_LotSize,minL,step);
      SetLastAction(dir+" rejected: fixed lot below broker minimum");
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
   {
      RegisterRejectionCategory(REJ_OTHER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: no tick data",dir,(int)s.id);
      return false;
   }

   ENUM_ORDER_TYPE ot=(s.direction==BIAS_BULLISH) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry=(ot==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   if(entry<=0)
   {
      RegisterRejectionCategory(REJ_OTHER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: invalid price",dir,(int)s.id);
      return false;
   }

   MqlTradeRequest chk; MqlTradeCheckResult chkRes;
   ZeroMemory(chk); ZeroMemory(chkRes);
   chk.action =TRADE_ACTION_DEAL;
   chk.symbol =_Symbol;
   chk.volume =lot;
   chk.type   =ot;
   chk.price  =entry;
   if(!OrderCheck(chk,chkRes))
   {
      ENUM_REJECT_CAT cat=REJ_BROKER;
      if(chkRes.retcode==TRADE_RETCODE_NO_MONEY)            cat=REJ_MARGIN;
      else if(chkRes.retcode==TRADE_RETCODE_INVALID_VOLUME) cat=REJ_LOT;
      RegisterRejectionCategory(cat);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: ORDER_CHECK_FAILED %s | %s  Entry=%.5f Lot=%.2f MarginReq=%.2f Free=%.2f",
                  dir,(int)s.id,RetcodeToString((int)chkRes.retcode),chkRes.comment,
                  entry,lot,chkRes.margin,chkRes.margin_free);
      SetLastAction(dir+" rejected: "+RetcodeToString((int)chkRes.retcode));
      return false;
   }

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lot;
   req.type      = ot;
   req.price     = entry;
   req.sl        = 0;      // intentional: no order-level SL
   req.tp        = 0;      // intentional: exit is the money target
   req.deviation = (ulong)g_MaxSlippagePoints;
   req.magic     = (ulong)MagicNumber;
   req.comment   = cmt;

   string fillingUsed, errText; int lastRet;
   if(!SubmitOrder(req,res,fillingUsed,lastRet,errText))
   {
      ENUM_REJECT_CAT cat=REJ_BROKER;
      if(lastRet==TRADE_RETCODE_INVALID_FILL)        cat=REJ_FILLING;
      else if(lastRet==TRADE_RETCODE_NO_MONEY)       cat=REJ_MARGIN;
      else if(lastRet==TRADE_RETCODE_INVALID_VOLUME) cat=REJ_LOT;
      RegisterRejectionCategory(cat);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: %s  Entry=%.5f Lot=%.2f",dir,(int)s.id,errText,entry,lot);
      SetLastAction(dir+" rejected: "+RetcodeToString(lastRet));
      return false;
   }

   if(ot==ORDER_TYPE_BUY) g_LongTrades++; else g_ShortTrades++;

   PrintFormat("[TRADE] %s #%d ACCEPTED  lot=%.2f entry=%.5f SL=none TP=none filling=%s comment=%s",
               dir,(int)s.id,lot,entry,fillingUsed,cmt);
   PrintFormat("Anchors: A=%.5f B=%.5f C=%.5f Trigger=%.5f  Impulse=%.2f Pullback=%.2f Quality=%s",
               s.A,s.B,s.C,s.trigger,s.impulseDistance,s.pullbackDistance,s.breakoutQuality);

   DrawEntryMarker(ot,entry,TimeCurrent(),(int)s.id);
   SetLastAction(StringFormat("%s #%d opened %.2f lots (target $%.2f)",dir,(int)s.id,lot,g_ProfitTargetUSD));
   return true;
}

//=========================================================================
//                     POSITION CLOSING (money target engine)
//=========================================================================
bool CloseOnePosition(ulong ticket,string reason)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double vol=PositionGetDouble(POSITION_VOLUME);
   if(vol<=0) return false;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = vol;
   req.type      = (pt==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price     = (req.type==ORDER_TYPE_SELL) ? tick.bid : tick.ask;
   req.deviation = (ulong)g_MaxSlippagePoints;
   req.magic     = (ulong)MagicNumber;
   req.comment   = "V13-close";

   ENUM_ACCOUNT_MARGIN_MODE mm=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      req.position=ticket;

   string fillingUsed, errText; int lastRet;
   if(!SubmitOrder(req,res,fillingUsed,lastRet,errText))
   {
      PrintFormat("[CLOSE] ticket=%I64u FAILED (%s) - will retry next tick",ticket,errText);
      return false;
   }
   PrintFormat("[CLOSE] ticket=%I64u closed (%s) filling=%s",ticket,reason,fillingUsed);
   return true;
}

void CloseAllEAPositions(string reason)
{
   PrintFormat("[EMERGENCY] Closing ALL EA positions. Reason = %s",reason);
   int guard=0;
   for(int i=PositionsTotal()-1;i>=0 && guard<1000;i--,guard++)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      CloseOnePosition(t,reason);
   }
   SetLastAction("EMERGENCY close-all: "+reason);
}

//=========================================================================
//          PER-TICK POSITION MANAGEMENT
//  ALWAYS runs, regardless of UseH1/UseM15/UseM5/UseM1/UseSRFilter.
//=========================================================================
void ManageOpenPositions()
{
   double totalFloat=0;

   // display-only accumulators (cost: a few adds inside a loop the engine
   // already runs every tick - the panel never re-walks the positions).
   int    pnTotal=0, pnBuys=0, pnSells=0;
   double pnVol=0, pnBuyVP=0, pnBuyV=0, pnSellVP=0, pnSellV=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;

      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      long   setupId=ParseSetupIdFromComment(PositionGetString(POSITION_COMMENT));
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);

      int ti=TrackIndexFor(t,opened,setupId);
      if(ti<0) continue;
      if(profit<g_Tracks[ti].minFloat) g_Tracks[ti].minFloat=profit;

      totalFloat+=profit;

      {
         double pvol=PositionGetDouble(POSITION_VOLUME);
         double popen=PositionGetDouble(POSITION_PRICE_OPEN);
         pnTotal++; pnVol+=pvol;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         { pnBuys++;  pnBuyV+=pvol;  pnBuyVP+=popen*pvol; }
         else
         { pnSells++; pnSellV+=pvol; pnSellVP+=popen*pvol; }
      }

      if(profit>=g_ProfitTargetUSD)
      {
         double mae=(g_Tracks[ti].minFloat<0) ? -g_Tracks[ti].minFloat : 0.0;
         long holdSec=(long)TimeCurrent()-(long)g_Tracks[ti].openTime;

         if(CloseOnePosition(t,StringFormat("money target +$%.2f reached (+$%.2f)",g_ProfitTargetUSD,profit)))
         {
            g_Cnt_TargetCloses++;
            g_SumTargetProfit+=profit;
            g_SumTargetHoldSec+=(double)holdSec;
            g_SumMAE+=mae;
            TombstoneTrack(t);

            PrintFormat("[TARGET] #%d ticket=%I64u floating=+$%.2f >= $%.2f -> CLOSED  hold=%ds  MAE=$%.2f",
                        (int)setupId,t,profit,g_ProfitTargetUSD,(int)holdSec,mae);
            SetLastAction(StringFormat("#%d target hit +$%.2f",(int)setupId,profit));
         }
      }
   }

   g_TotalFloat=totalFloat;

   // ---- publish the open-trade snapshot for the dashboard ----
   g_PanelOpenTradeCount=pnTotal;
   g_PanelBuyCount=pnBuys;
   g_PanelSellCount=pnSells;
   g_PanelOpenVolume=pnVol;
   g_PanelFloatPL=totalFloat;
   g_PanelAvgBuy =(pnBuyV >0)?pnBuyVP /pnBuyV :0.0;
   g_PanelAvgSell=(pnSellV>0)?pnSellVP/pnSellV:0.0;

   if(g_MaxFloatingLossUSD>0 && totalFloat<=-g_MaxFloatingLossUSD && !g_HaltedFloat)
   {
      g_HaltedFloat=true;
      PrintFormat("[EMERGENCY] Combined floating loss $%.2f <= -$%.2f -> new entries HALTED",
                  totalFloat,g_MaxFloatingLossUSD);
      if(CloseAllOnEmergencyLoss)
         CloseAllEAPositions("max floating loss breached");
      else
         SetLastAction("EMERGENCY: floating loss halt (close-all disabled)");
   }

   CompactTracks();
}

//=========================================================================
//                     COMPLETED-TRADE ACCOUNTING
//=========================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal))         return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=MagicNumber) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);

   long posId=(long)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   TombstoneTrack((ulong)posId);

   g_DayPL += profit;
   g_ConsLoss = (profit<0) ? g_ConsLoss+1 : 0;
   if(g_ConsLoss>g_MaxConsecLossPeak) g_MaxConsecLossPeak=g_ConsLoss;

   if(g_DayBal>0 && g_DailyLossLimitPercent>0 &&
      g_DayPL<=-(g_DayBal*g_DailyLossLimitPercent/100.0))
      g_HaltedDaily=true;
   if(g_ConsecutiveLossLimit>0 && g_ConsLoss>=g_ConsecutiveLossLimit)
      g_HaltedConsec=true;

   g_TotalTrades++;
   g_TotalRealizedPL += profit;
   if(profit>0)      { g_Wins++;   g_SumWinProfit+=profit;  if(profit>g_LargestWin)  g_LargestWin=profit; }
   else if(profit<0) { g_Losses++; g_SumLossProfit+=profit; if(profit<g_LargestLoss) g_LargestLoss=profit; }

   // ---- DISPLAY CACHE: update incrementally, do NOT rescan history ----
   {
      long dtype=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
      datetime dtime=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
      PnPushClosedTrade(dtime,(dtype==DEAL_TYPE_SELL),profit);
   }
   g_PanelDirty=true;

   g_LastAction=StringFormat("Trade closed  P/L $%.2f  (Total $%.2f)",profit,g_TotalRealizedPL);
   PrintFormat("[TRADE] Closed positionId=%I64d profit=%.2f | Total=%.2f Wins=%d Losses=%d Streak=%d",
               posId,profit,g_TotalRealizedPL,g_Wins,g_Losses,g_ConsLoss);
}

//=========================================================================
//                     INITIALIZATION / DEINITIALIZATION
//=========================================================================
void ResetTFStruct(TFStruct &st)
{
   st.bias=BIAS_NEUTRAL; st.reason="No confirmed structure yet";
   st.SH=0; st.PSH=0; st.SL=0; st.PSL=0;
   st.SHt=0; st.PSHt=0; st.SLt=0; st.PSLt=0;
   st.HH=false; st.HL=false; st.LH=false; st.LL=false;
   st.lastExpansion=0; st.requiredExpansion=0; st.qualityOK=false;
   st.cntBull=0; st.cntBear=0;
}

void WarmupTF(TFStruct &st,ENUM_TIMEFRAMES tf,int atrHandle,int bars)
{
   int need=g_PivotSize*2+2;
   int avail=(int)Bars(_Symbol,tf);
   if(avail<need+2) return;
   int maxShift=(int)MathMin(bars,avail-need-1);
   if(maxShift<1) return;
   for(int s=maxShift;s>=0;s--)
      UpdateTFStructure(st,tf,atrHandle,s,false);
}

// Validate every non-S/R input into the effective globals.
bool ValidateGeneralInputs()
{
   if(PivotSize<1)         { Print("[INIT] PivotSize must be >= 1"); return false; }
   if(ATRPeriod<1)         { Print("[INIT] ATRPeriod must be >= 1"); return false; }
   if(ProfitTargetUSD<=0)  { Print("[INIT] ProfitTargetUSD must be > 0"); return false; }
   if(LotSize<=0)          { Print("[INIT] LotSize must be > 0"); return false; }
   if(MaxOpenTrades<1)     { Print("[INIT] MaxOpenTrades must be >= 1"); return false; }
   if(MaxActiveSetups<1)   { Print("[INIT] MaxActiveSetups must be >= 1"); return false; }
   if(MaxFloatingLossUSD<=0){Print("[INIT] MaxFloatingLossUSD must be > 0"); return false; }

   g_PivotSize=MathMin(PivotSize,20);
   g_ATRPeriod=MathMin(ATRPeriod,500);
   g_ProfitTargetUSD=ProfitTargetUSD;
   g_LotSize=LotSize;
   g_MaxOpenTrades=MathMin(MaxOpenTrades,200);
   g_MaxActiveSetups=MathMin(MaxActiveSetups,500);
   g_MaxFloatingLossUSD=MaxFloatingLossUSD;

   g_StructureExpansion=MathMax(0.0,MathMin(StructureExpansion,10.0));
   g_MinPullback=MathMax(0.0,MathMin(MinPullback,10.0));
   g_BreakoutBodyMinimum=MathMax(0.0,MathMin(BreakoutBodyMinimum,1.0));

   g_VolatilityLookback=MathMax(2,MathMin(VolatilityLookback,1000));
   g_VolatilitySpikeLimit=(VolatilitySpikeLimit<=0)?1.5:MathMin(VolatilitySpikeLimit,100.0);

   g_SetupExpiryMinutes=MathMax(0,MathMin(SetupExpiryMinutes,10080));
   g_MaxEntryMarkers=MathMax(1,MathMin(MaxEntryMarkers,500));

   g_MaxSpreadPoints=MathMax(1,MathMin(MaxSpreadPoints,100000));
   g_DailyLossLimitPercent=MathMax(0.0,MathMin(DailyLossLimitPercent,100.0));
   g_ConsecutiveLossLimit=MathMax(0,MathMin(ConsecutiveLossLimit,1000));

   g_HTFWarmupBars=MathMax(0,MathMin(HTFWarmupBars,5000));
   g_M1WarmupBars=MathMax(0,MathMin(M1WarmupBars,10000));
   g_MaxSlippagePoints=MathMax(0,MathMin(MaxSlippagePoints,10000));

   g_TradingStartHour=TradingStartHour;
   g_TradingEndHour=TradingEndHour;
   if(g_TradingStartHour<0 || g_TradingStartHour>23 ||
      g_TradingEndHour<0   || g_TradingEndHour>23)
   {
      Print("[INIT] Trading hours out of range (0..23) - session filter disabled (24h trading).");
      g_TradingStartHour=0; g_TradingEndHour=0;
   }
   return true;
}

int OnInit()
{
   g_InitComplete=false;

   if(!ValidateGeneralInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_ATR_H1  = iATR(_Symbol, PERIOD_H1,  g_ATRPeriod);
   g_ATR_M30 = iATR(_Symbol, PERIOD_M30, g_ATRPeriod);
   g_ATR_M15 = iATR(_Symbol, PERIOD_M15, g_ATRPeriod);
   g_ATR_M5  = iATR(_Symbol, PERIOD_M5,  g_ATRPeriod);
   g_ATR_M1  = iATR(_Symbol, PERIOD_M1,  g_ATRPeriod);
   if(g_ATR_H1==INVALID_HANDLE || g_ATR_M30==INVALID_HANDLE || g_ATR_M15==INVALID_HANDLE ||
      g_ATR_M5==INVALID_HANDLE  || g_ATR_M1==INVALID_HANDLE)
      return INIT_FAILED;

   ObjectsDeleteAll(0,"V13_");    // covers S/R, setups, panel and markers

   ResetTFStruct(g_H1);
   ResetTFStruct(g_M15);
   ResetTFStruct(g_M5);
   ArrayResize(g_Setups,0);
   ArrayResize(g_Tracks,0);
   ArrayResize(g_EntryMarkerQueue,0);

   g_Day=-1;
   g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_MaxDrawdownPct=0;

   // ---- S/R module: enabled ONLY when requested AND valid ----
   if(UseSRFilter && ValidateSRInputs())
   {
      g_SRActive=true;
      ResetSRState();
      g_SRState=SR_NO_VALID;
   }
   else
      DisableM30SR();   // guarantees "as if the module does not exist"

   // ---- 1) rebuild H1/M15/M5 causally ----
   WarmupTF(g_H1, PERIOD_H1,  g_ATR_H1,  g_HTFWarmupBars);
   WarmupTF(g_M15,PERIOD_M15, g_ATR_M15, g_HTFWarmupBars);
   WarmupTF(g_M5, PERIOD_M5,  g_ATR_M5,  g_HTFWarmupBars);

   // ---- 1b) initial M30 S/R build (no-op when the module is off) ----
   BuildM30SRZones();

   PrintFormat("[INIT] H1=%s M15=%s M5=%s aligned=%s  M30 S/R=%s zones=%d",
               TFVoteStr(UseH1,g_H1.bias),TFVoteStr(UseM15,g_M15.bias),TFVoteStr(UseM5,g_M5.bias),
               AlignResultToStr(AlignedBias()),(g_SRActive?"ON":"OFF"),g_SRZoneCount);

   // ---- 2) rebuild the M1 setup pool causally (no entries possible) ----
   if(UseM1)
   {
      int need=g_PivotSize*2+2;
      int avail=(int)Bars(_Symbol,PERIOD_M1);
      int maxShift=(int)MathMin(g_M1WarmupBars,avail-need-1);
      for(int s=maxShift;s>=1;s--)
         ProcessM1PivotsAtShift(s,false);
      CompactSetups();

      MqlTick tk;
      if(SymbolInfoTick(_Symbol,tk))
      {
         for(int i=0;i<ArraySize(g_Setups);i++)
         {
            if(!g_Setups[i].active) continue;
            if(g_Setups[i].state==MS_WAIT_BREAK && g_Setups[i].trigger>0)
            {
               double px=(g_Setups[i].direction==BIAS_BULLISH) ? tk.ask : tk.bid;
               bool beyond=(g_Setups[i].direction==BIAS_BULLISH) ? (px>g_Setups[i].trigger)
                                                                 : (px<g_Setups[i].trigger);
               g_Setups[i].crossActive=beyond;   // no fake retro-entry at startup
            }
         }
      }
   }

   // ---- 3) prime new-bar detection ----
   g_LastH1Bar =iTime(_Symbol,PERIOD_H1,0);
   g_LastM30Bar=iTime(_Symbol,PERIOD_M30,0);
   g_LastM15Bar=iTime(_Symbol,PERIOD_M15,0);
   g_LastM5Bar =iTime(_Symbol,PERIOD_M5,0);
   g_LastM1Bar =iTime(_Symbol,PERIOD_M1,0);

   EvaluateSRState();   // safe: returns SR_DISABLED when the module is off

   // ---- dashboard: install the refresh timer (live only; the tester has
   //      no real time base, so it falls back to GetTickCount throttling
   //      driven from OnTick - see PanelTick()). ----
   // ONE-TIME cleanup of any orphaned panel objects left behind by an
   // earlier renderer generation (older builds encoded pixel offsets into
   // object names, e.g. "L12_173"). Runs ONLY here in OnInit - never on a
   // refresh - and touches nothing outside PN_PREFIX.
   ClearPanelObjects();

   g_PanelVisible=false;
   g_PanelDirty=true;
   g_PanelLastDrawMs=GetTickCount();
   g_HTFVisualDirty=true; g_SRVisualDirty=g_SRActive; g_SetupVisualDirty=true;
   g_TimerActive=false;
   if(DebugMode && !MQLInfoInteger(MQL_TESTER))
   {
      int ms=MathMax(50,MathMin(PanelRefreshMs,5000));
      if(EventSetMillisecondTimer(ms)) g_TimerActive=true;
   }

   g_InitComplete=true;

   SetLastAction("Initialized - "+IntegerToString(CountActiveSetups())+" setups warmed, scanning live");
   PrintFormat("[INIT] V13.31 ready. UseH1=%s UseM15=%s UseM5=%s UseM1=%s SRFilter=%s  Active setups=%d  Open EA positions=%d",
               (UseH1?"ON":"OFF"),(UseM15?"ON":"OFF"),(UseM5?"ON":"OFF"),(UseM1?"ON":"OFF"),
               (g_SRActive?"ON":"OFF"),CountActiveSetups(),CountPositions());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_InitComplete=false;

   if(g_ATR_H1 !=INVALID_HANDLE) IndicatorRelease(g_ATR_H1);
   if(g_ATR_M30!=INVALID_HANDLE) IndicatorRelease(g_ATR_M30);
   if(g_ATR_M15!=INVALID_HANDLE) IndicatorRelease(g_ATR_M15);
   if(g_ATR_M5 !=INVALID_HANDLE) IndicatorRelease(g_ATR_M5);
   if(g_ATR_M1 !=INVALID_HANDLE) IndicatorRelease(g_ATR_M1);
   g_ATR_H1=g_ATR_M30=g_ATR_M15=g_ATR_M5=g_ATR_M1=INVALID_HANDLE;

   if(g_TimerActive) { EventKillTimer(); g_TimerActive=false; }

   DeleteSRObjects();
   ClearPanelObjects();
   ObjectsDeleteAll(0,"V13_");
   ChartRedraw(0);

   PrintBacktestSummary();
}

//=========================================================================
//                          MAIN TICK PROCESSING
//=========================================================================
void OnTick()
{
   if(!g_InitComplete) return;

   CheckNewDay();
   UpdateDrawdownTracking();

   // ---- runtime S/R ON/OFF handling (must happen BEFORE any S/R work) ----
   SyncSRModuleSwitch();

   if(IsNewBar(PERIOD_H1, g_LastH1Bar))
      UpdateTFStructure(g_H1, PERIOD_H1, g_ATR_H1, 0,true);

   // ---- M30 S/R zones: only on a new M30 candle close, only when ON ----
   bool newM30=IsNewBar(PERIOD_M30,g_LastM30Bar);
   if(g_SRActive && newM30)
      BuildM30SRZones();

   if(IsNewBar(PERIOD_M15,g_LastM15Bar))
      UpdateTFStructure(g_M15,PERIOD_M15,g_ATR_M15,0,true);
   if(IsNewBar(PERIOD_M5, g_LastM5Bar))
      UpdateTFStructure(g_M5, PERIOD_M5, g_ATR_M5, 0,true);

   if(IsNewBar(PERIOD_M1, g_LastM1Bar))
   {
      if(g_SRActive) UpdateSRBreakCounters();
      ProcessM1PivotsAtShift(0,true);
   }

   if(g_SRActive) EvaluateSRState();

   ProcessSetupsOnTick();
   ManageOpenPositions();

   // ---- UI: throttled. In the tester (and if the timer failed to
   //      install) this is the only driver; it early-outs in a couple of
   //      instructions when the refresh window has not elapsed, so heavy
   //      tick streams cost essentially nothing. ----
   if(!g_TimerActive)
      PanelTick();
}

//=========================================================================
//   TIMER: the ONLY dashboard driver in live mode (250-500 ms typical).
//   The strategy never runs here - OnTick keeps full control of trading.
//=========================================================================
void OnTimer()
{
   if(!g_InitComplete) return;
   PanelTick();
}

//=========================================================================
//   THROTTLED UI ENTRY POINT  (display only, side-effect free)
//
//   - honours DebugMode with a visibility latch: when the panel is turned
//     off its objects are removed exactly ONCE, never per tick;
//   - enforces the PanelRefreshMs window with GetTickCount(), which works
//     identically in live mode and in the Strategy Tester;
//   - redraws chart annotations only when their dirty flag is set;
//   - issues at most ONE ChartRedraw() per actual visual change.
//=========================================================================
void PanelTick()
{
   // ---- visibility latch: create/delete only on a transition ----
   if(!DebugMode)
   {
      if(g_PanelVisible)
      {
         ClearPanelObjects();
         DeleteSRObjects();
         ObjectsDeleteAll(0,"V13_H1_");
         ObjectsDeleteAll(0,"V13_M15_");
         ObjectsDeleteAll(0,"V13_M5_");
         ObjectsDeleteAll(0,"V13_S");
         ObjectsDeleteAll(0,"V13_Entry_");
         ArrayResize(g_EntryMarkerQueue,0);
         g_HTFVisualDirty=true; g_SRVisualDirty=g_SRActive; g_SetupVisualDirty=true;
         g_PanelVisible=false;
         ChartRedraw(0);
      }
      return;   // <- nothing else happens while the panel is hidden
   }

   // ---- time throttle (works in live mode AND in the tester) ----
   uint now=GetTickCount();
   uint every=(uint)MathMax(50,MathMin(PanelRefreshMs,5000));
   if(g_PanelVisible && !g_PanelDirty && (now-g_PanelLastDrawMs)<every)
      return;
   g_PanelLastDrawMs=now;
   g_PanelDirty=false;

   // ---- refresh the cheap decision cache ONCE per render, not per tick ----
   PanelRefreshStateCache();

   // ---- event-driven chart annotations ----
   bool visualChanged=UpdateChartVisualsIfDirty();

   // ---- the dashboard itself ----
   RefreshPanel();
   g_PanelVisible=true;

   ChartRedraw(0);   // exactly one redraw per throttled update
   if(visualChanged) { /* already covered by the redraw above */ }
}

//=========================================================================
//                          DIAGNOSTIC SUMMARY
//=========================================================================
void PrintBacktestSummary()
{
   Print("===== V13 MULTI-SETUP / MONEY-TARGET SUMMARY =====");
   PrintFormat("Timeframe filters: UseH1=%s UseM15=%s UseM5=%s UseM1=%s  SRFilter=%s",
               (UseH1?"ON":"OFF"),(UseM15?"ON":"OFF"),(UseM5?"ON":"OFF"),(UseM1?"ON":"OFF"),
               (UseSRFilter?"ON":"OFF"));
   double pf=(g_SumLossProfit<0) ? (g_SumWinProfit/MathAbs(g_SumLossProfit)) : 0.0;
   double wr=(g_Wins+g_Losses>0) ? (100.0*g_Wins/(g_Wins+g_Losses)) : 0.0;
   double avgWin =(g_Wins>0)   ? g_SumWinProfit/g_Wins     : 0.0;
   double avgLoss=(g_Losses>0) ? g_SumLossProfit/g_Losses  : 0.0;
   PrintFormat("Trades=%d  Long=%d Short=%d  Wins=%d Losses=%d  WinRate=%.1f%%  ProfitFactor=%.2f",
               g_TotalTrades,g_LongTrades,g_ShortTrades,g_Wins,g_Losses,wr,pf);
   PrintFormat("TotalP/L=$%.2f  AvgWin=$%.2f  AvgLoss=$%.2f  LargestWin=$%.2f  LargestLoss=$%.2f  MaxConsecLoss=%d  MaxDD=%.2f%%",
               g_TotalRealizedPL,avgWin,avgLoss,g_LargestWin,g_LargestLoss,g_MaxConsecLossPeak,g_MaxDrawdownPct);
   Print("---- HTF confirmations (LIVE) ----");
   PrintFormat("H1: Bull=%d Bear=%d | M15: Bull=%d Bear=%d | M5: Bull=%d Bear=%d",
               g_H1.cntBull,g_H1.cntBear,g_M15.cntBull,g_M15.cntBear,g_M5.cntBull,g_M5.cntBear);
   Print("---- M30 Support/Resistance filter ----");
   if(!g_SRActive)
      Print("Module OFF - no zones, no filtering, no chart objects.");
   else
      PrintFormat("Zones=%d/%d  LastUpdate=%s  CurrentState=%s",
                  g_SRZoneCount,SR_MAX_ZONES,
                  (g_SRLastUpdate>0?TimeToString(g_SRLastUpdate,TIME_DATE|TIME_MINUTES):"-"),
                  SRStateToStr(g_SRState));
   Print("---- M1 multi-setup pipeline ----");
   PrintFormat("Setups created=%d  invalidated=%d  expired=%d  skipped(cap)=%d  active-now=%d",
               g_Cnt_SetupsCreated,g_Cnt_SetupsInvalidated,g_Cnt_SetupsExpired,
               g_Cnt_SetupsSkippedCap,CountActiveSetups());
   PrintFormat("Triggers=%d  Breakouts=%d  Quality PASS=%d  WEAK=%d",
               g_Cnt_Triggers,g_Cnt_Breakouts,g_Cnt_BOQualityPass,g_Cnt_BOQualityWeak);
   PrintFormat("Entry attempts=%d  executed=%d  blocked=%d  failed=%d",
               g_Cnt_EntryAttempts,g_Cnt_EntryExecuted,g_Cnt_EntryBlocked,g_Cnt_EntryFailed);
   Print("---- Money-target statistics ----");
   double avgTP  =(g_Cnt_TargetCloses>0) ? g_SumTargetProfit/g_Cnt_TargetCloses   : 0.0;
   double avgHold=(g_Cnt_TargetCloses>0) ? g_SumTargetHoldSec/g_Cnt_TargetCloses  : 0.0;
   double avgMae =(g_Cnt_TargetCloses>0) ? g_SumMAE/g_Cnt_TargetCloses            : 0.0;
   PrintFormat("Closed at target ($%.2f): %d  AvgProfit=$%.2f  AvgHold=%.0fs  AvgMAE=$%.2f",
               g_ProfitTargetUSD,g_Cnt_TargetCloses,avgTP,avgHold,avgMae);
   Print("---- Execution rejection breakdown ----");
   PrintFormat("Lot=%d  Stops=%d  Margin=%d  Filling=%d  Broker=%d  Other=%d",
               g_Cnt_RejectLot,g_Cnt_RejectStops,g_Cnt_RejectMargin,
               g_Cnt_RejectFilling,g_Cnt_RejectBroker,g_Cnt_RejectOther);
   Print("==================================================");
}

//=========================================================================
//                         CHART VISUALIZATION
//=========================================================================
void DrawHTFMarker(string prefix,string tag,double price,datetime time,color clr,int arrowCode,int fontSize)
{
   if(!DebugMode || time<=0) return;
   string name=prefix+tag;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_ARROW,0,time,price);
   else
      ObjectMove(0,name,0,time,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,arrowCode);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);   // behind the opaque panel

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,time,price);
   else
      ObjectMove(0,label,0,time,price);
   ObjectSetString(0,label,OBJPROP_TEXT," "+tag);
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,fontSize);
   ObjectSetInteger(0,label,OBJPROP_BACK,true);
}

void DrawTFMarkers(string prefix,TFStruct &st,color highClr,color lowClr)
{
   DrawHTFMarker(prefix,"HiL",st.SH, st.SHt, highClr,234,7);
   DrawHTFMarker(prefix,"HiP",st.PSH,st.PSHt,highClr,159,7);
   DrawHTFMarker(prefix,"LoL",st.SL, st.SLt, lowClr, 233,7);
   DrawHTFMarker(prefix,"LoP",st.PSL,st.PSLt,lowClr, 159,7);
}

void DrawHTFVisuals()
{
   DrawTFMarkers("V13_H1_", g_H1, clrGold,        clrOrange);
   DrawTFMarkers("V13_M15_",g_M15,clrDodgerBlue,  clrAqua);
   DrawTFMarkers("V13_M5_", g_M5, clrLime,        clrRed);
}

// ---- M30 S/R zone rectangles. Dedicated prefix, fully cleaned up. ----
void DrawSRZones()
{
   if(!g_SRActive) { DeleteSRObjects(); return; }
   if(!DebugMode)  { if(g_SRObjectsDrawn) DeleteSRObjects(); return; }

   // Full sweep first: no stale rectangles can survive a rebuild.
   ObjectsDeleteAll(0,SR_OBJ_PREFIX);

   datetime rightEdge=TimeCurrent()+PeriodSeconds(PERIOD_M30)*4;
   bool drewSomething=false;

   for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
   {
      SRZone z=g_SRZones[i];
      if(!z.valid || z.formedTime<=0) continue;

      string name =SR_OBJ_PREFIX+"Zone_"+IntegerToString(i);
      string label=name+"_txt";
      color clr = z.isResistance ? clrTomato : clrLimeGreen;

      if(!ObjectCreate(0,name,OBJ_RECTANGLE,0,z.formedTime,z.upper,rightEdge,z.lower))
         continue;
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_FILL,true);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);

      if(ObjectCreate(0,label,OBJ_TEXT,0,rightEdge,(z.upper+z.lower)/2.0))
      {
         ObjectSetInteger(0,label,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,label,OBJPROP_HIDDEN,true);
         ObjectSetInteger(0,label,OBJPROP_FONTSIZE,7);
         ObjectSetString(0,label,OBJPROP_TEXT,
            StringFormat(" %s x%d",(z.isResistance?"R":"S"),z.touches));
         ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
      }
      drewSomething=true;
   }

   g_SRObjectsDrawn=drewSomething;
}

// ---- Per-setup M1 visuals ----
string SetupObjName(int id,string tag) { return "V13_S"+IntegerToString(id)+"_"+tag; }

void DrawSetupAnchor(int id,string tag,double price,datetime time,color clr,int arrowCode)
{
   if(!DebugMode || time<=0) return;
   string name=SetupObjName(id,tag);
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_ARROW,0,time,price);
   else
      ObjectMove(0,name,0,time,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,arrowCode);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);   // behind the opaque panel

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,time,price);
   else
      ObjectMove(0,label,0,time,price);
   ObjectSetString(0,label,OBJPROP_TEXT,StringFormat(" #%d %s",id,tag));
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,label,OBJPROP_BACK,true);
}

void DrawSetupTrigger(int id,double price,datetime fromTime,color clr)
{
   if(!DebugMode || fromTime<=0) return;
   string name=SetupObjName(id,"TRIG");
   datetime endTime=fromTime+PeriodSeconds(PERIOD_M1)*200;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_TREND,0,fromTime,price,endTime,price);
   else
   {
      ObjectMove(0,name,0,fromTime,price);
      ObjectMove(0,name,1,endTime,price);
   }
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASH);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);   // behind the opaque panel

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,fromTime,price);
   else
      ObjectMove(0,label,0,fromTime,price);
   ObjectSetString(0,label,OBJPROP_TEXT,StringFormat(" #%d TRIGGER",id));
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,label,OBJPROP_BACK,true);
}

void DeleteSetupTrigger(int id)
{
   string name=SetupObjName(id,"TRIG");
   ObjectDelete(0,name);
   ObjectDelete(0,name+"_txt");
}

void DeleteSetupVisuals(int id)
{
   string tags[4]={"A","B","C","TRIG"};
   for(int i=0;i<4;i++)
   {
      string name=SetupObjName(id,tags[i]);
      ObjectDelete(0,name);
      ObjectDelete(0,name+"_txt");
   }
}

void DrawAllSetupVisuals()
{
   for(int i=0;i<ArraySize(g_Setups);i++)
   {
      if(!g_Setups[i].active) continue;
      M1Setup s=g_Setups[i];
      if(s.At>0) DrawSetupAnchor((int)s.id,"A",s.A,s.At,clrDodgerBlue,159);
      if(s.Bt>0)
         DrawSetupAnchor((int)s.id,"B",s.B,s.Bt,
                         (s.direction==BIAS_BULLISH?clrLime:clrTomato),159);
      if(s.Ct>0) DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
      if(s.triggerTime>0 && s.state==MS_WAIT_BREAK)
         DrawSetupTrigger((int)s.id,s.trigger,s.triggerTime,
                          (s.direction==BIAS_BULLISH?clrAqua:clrMagenta));
   }
}

// ---- Entry markers (FIFO, tagged with setup id) ----
void AddEntryMarkerToQueue(string baseName)
{
   int n=ArraySize(g_EntryMarkerQueue);
   if(ArrayResize(g_EntryMarkerQueue,n+1)<=n) return;
   g_EntryMarkerQueue[n]=baseName;

   int cap=MathMax(1,g_MaxEntryMarkers);
   while(ArraySize(g_EntryMarkerQueue)>cap)
   {
      string oldest=g_EntryMarkerQueue[0];
      ObjectDelete(0,oldest);
      ObjectDelete(0,oldest+"_txt");
      int cnt=ArraySize(g_EntryMarkerQueue);
      for(int i=0;i<cnt-1;i++) g_EntryMarkerQueue[i]=g_EntryMarkerQueue[i+1];
      ArrayResize(g_EntryMarkerQueue,cnt-1);
   }
}

void DrawEntryMarker(ENUM_ORDER_TYPE ot,double price,datetime time,int setupId)
{
   if(!DebugMode) return;
   string name="V13_Entry_"+TimeToString(time,TIME_DATE|TIME_MINUTES|TIME_SECONDS)
               +"_"+IntegerToString((int)(GetMicrosecondCount()%100000));
   int  code=(ot==ORDER_TYPE_BUY) ? 233 : 234;
   color clr=(ot==ORDER_TYPE_BUY) ? clrLime : clrRed;
   if(!ObjectCreate(0,name,OBJ_ARROW,0,time,price)) return;
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,code);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,3);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);   // behind the opaque panel

   string label=name+"_txt";
   if(ObjectCreate(0,label,OBJ_TEXT,0,time,price))
   {
      ObjectSetString(0,label,OBJPROP_TEXT,StringFormat("%s #%d",(ot==ORDER_TYPE_BUY?" BUY":" SELL"),setupId));
      ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,label,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,label,OBJPROP_BACK,true);
   }

   AddEntryMarkerToQueue(name);
}

//=========================================================================
//        V13.4 PROFESSIONAL DASHBOARD PANEL  (UI ONLY - NO TRADING LOGIC)
//
//  Single expanded two-column HUD panel:
//     HEADER  : EA name/version, symbol, timeframe, live status lamp
//     LEFT    : Account & Risk / Trade Safety / Multi-Timeframe Bias +
//               M30 S/R Filter / Open Trades + Setup Status / Today
//     RIGHT   : Max Floating Loss / Daily Profit history / Recent Trades
//     FOOTER  : local time, next action + M1 check progress, server time,
//               broker/server name, connection state
//
//  Rendering rules (performance + stability):
//   - every label is a persistent OBJ_LABEL with a stable name; objects
//     are created once and only their TEXT/COLOR are updated afterwards,
//     so there is no flicker and no per-tick object churn;
//   - the row pool is reused and any surplus row from a previous, longer
//     frame is hidden (empty text) rather than deleted/recreated;
//   - the expensive history scans (daily P/L series, recent trade list)
//     are cached and refreshed at most once per PanelHistoryRefreshSec,
//     or immediately when a deal closes (g_PnHistoryDirty);
//   - the panel reads state only. It never calls a function that can
//     change EA state, never opens/closes/filters trades, and is only
//     invoked from OnTick() behind the existing DebugMode switch.
//=========================================================================
#define PN_PREFIX "V13_P_"
#define PN_RPAD    14          // guaranteed right-side padding (px)

// ---- forward declarations (MQL5 requires declaration before use) ----
double PnCharW();
int    PnTextW(int chars);
void   PnLabel(string id,int x,int y,string text,color clr,int fontSize,string font="Consolas");
void   PnRect(string id,int x,int y,int w,int h,color border,color bg,int zorder,bool back);
void   PnSlotL(string role,int row,int x,string text,color clr);
void   PnSlotR(string role,int row,int x,string text,color clr);
void   PnHideExisting(string id);
string PnFit(string s,int maxChars);
void   DetermineStatus(string &status,color &clr);
int    LatestSetupIndex();
void   PnRebuildHistory();


// ---- Layout (all derived from the configurable inputs) ----
int  g_PnX=0, g_PnY=0, g_PnW=0, g_PnH=0;
int  g_PnRowH=0, g_PnFont=0;
int  g_PnLeftX=0, g_PnRightX=0, g_PnSepX=0, g_PnColW=0;
// Four computed field zones for the left column (label|value|label|value)
// and two for the right column. All derived from PanelWidth / PanelFontSize
// at render time, so the layout adapts instead of relying on magic offsets.
int  g_PnZ1=0, g_PnZ2=0, g_PnZ3=0, g_PnZ4=0;   // left col field origins (px)
int  g_PnZ1W=0, g_PnZ2W=0, g_PnZ3W=0, g_PnZ4W=0; // field widths in CHARACTERS
int  g_PnRZ1=0, g_PnRZ2=0;                     // right col label/value origins
int  g_PnRZ1W=0, g_PnRZ2W=0;
int  g_PnLeftCols=0, g_PnRightCols=0;          // section-rule widths (chars)
// HARD RIGHT BOUNDARY - no panel text may ever render past this x.
int  g_PnRightEdge=0;                          // absolute px, = X+W-PN_RPAD
// RECENT TRADES: four independent column origins (absolute px) + budgets.
int  g_PnTrXTime=0, g_PnTrXType=0, g_PnTrXRes=0, g_PnTrXPL=0;
int  g_PnTrWTime=0, g_PnTrWType=0, g_PnTrWRes=0, g_PnTrWPL=0;
int  g_PnBodyTop=0, g_PnFooterY=0;

// ---- Dashboard colour scheme (dark navy HUD) ----
color clrPnBG      = C'8,12,24';        // dark navy background
color clrPnBorder  = C'0,160,200';      // cyan border
color clrPnSection = C'0,200,235';      // cyan section headers
color clrPnSep     = C'0,80,110';       // thin cyan separators
color clrPnLabel   = C'190,200,215';    // light grey labels
color clrPnValue   = C'225,235,245';    // near-white values
color clrPnGood    = C'0,230,118';      // green
color clrPnBad     = C'255,82,82';      // red
color clrPnWarn    = C'255,193,7';      // amber
color clrPnDim     = C'110,125,145';    // dimmed / N/A
color clrPnTitle   = C'64,196,255';     // header text

// Legacy aliases kept so any other code referring to them still compiles.
color clrPanelBG     = C'8,12,24';
color clrPanelBorder = C'0,160,200';
color clrTitle       = C'64,196,255';
color clrNormal      = C'225,235,245';
color clrGood        = C'0,230,118';
color clrBad         = C'255,82,82';
color clrWarn        = C'255,193,7';
color clrBuyC        = C'0,230,118';
color clrSellC       = C'255,82,82';
color clrDim         = C'110,125,145';

#define PN_MAX_ROWS 80
int    g_PnLeftUsed=0,  g_PnLeftPrev=0;
int    g_PnRightUsed=0, g_PnRightPrev=0;

// ---- Cached history (daily series + recent trades) ----
#define PN_DAYS   7
#define PN_TRADES 8

string   g_PnDayLabel[PN_DAYS];
double   g_PnDayPL[PN_DAYS];
bool     g_PnDayUsed[PN_DAYS];
int      g_PnDayCount=0;

string   g_PnTrTime[PN_TRADES];
string   g_PnTrType[PN_TRADES];
double   g_PnTrPL[PN_TRADES];
int      g_PnTrCount=0;

double   g_PnTodayWinSum=0, g_PnTodayLossSum=0;
int      g_PnTodayTrades=0, g_PnTodayWins=0, g_PnTodayLosses=0;
int      g_PnConsWins=0;
datetime g_PnHistoryLast=0;

//-------------------------------------------------------------------------
//  Small formatting helpers (display only)
//-------------------------------------------------------------------------
string PnMoney(double v,bool sign)
{
   if(sign) return StringFormat("%+.2f USD",v);
   return StringFormat("%.2f USD",v);
}

string PnPct(double num,double den)
{
   if(den==0.0) return "--";
   return StringFormat("(%.2f%%)",100.0*num/den);
}

color PnPLColor(double v)
{
   if(v>0) return clrPnGood;
   if(v<0) return clrPnBad;
   return clrPnValue;
}

// Truncate-only fit. Never pads: each field is its own positioned
// OBJ_LABEL, so trailing spaces serve no purpose and only crowd neighbours.
string PnFit(string s,int maxChars)
{
   if(maxChars<=0) return "";
   if(StringLen(s)<=maxChars) return s;
   if(maxChars<=3) return StringSubstr(s,0,maxChars);
   return StringSubstr(s,0,maxChars-3)+"...";
}

// Right-align a string inside a fixed character width (numeric columns).
string PnPadLeft(string s,int width)
{
   int n=StringLen(s);
   if(n>=width)
   {
      if(width<4) return StringSubstr(s,0,width);
      return StringSubstr(s,0,width-1)+".";
   }
   string out="";
   for(int i=n;i<width;i++) out+=" ";
   return out+s;
}

string PnPad(string s,int width)
{
   int n=StringLen(s);
   if(n>=width)
   {
      if(width<4) return StringSubstr(s,0,width);
      return StringSubstr(s,0,width-1)+".";
   }
   string out=s;
   for(int i=n;i<width;i++) out+=" ";
   return out;
}

string PnTFName(ENUM_TIMEFRAMES tf)
{
   string s=EnumToString(tf);
   int p=StringFind(s,"PERIOD_");
   if(p==0) s=StringSubstr(s,7);
   return s;
}

//-------------------------------------------------------------------------
//  Object primitives - create once, then update text/colour only.
//-------------------------------------------------------------------------
void PnLabel(string id,int x,int y,string text,color clr,int fontSize,string font)
{
   string name=PN_PREFIX+id;
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0)) return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_ZORDER,10);
      ObjectSetString (0,name,OBJPROP_FONT,font);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}

void PnRect(string id,int x,int y,int w,int h,color border,color bg,int zorder,bool back)
{
   if(w<1) w=1; if(h<1) h=1;
   string name=PN_PREFIX+id;
   if(ObjectFind(0,name)<0)
   {
      if(!ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0)) return;
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   }
   // OBJPROP_BACK is the ACTUAL layering mechanism for chart objects.
   // The background pane is drawn in the chart background so no label can
   // ever be hidden by it; the thin rules sit in the foreground but are
   // 1 px wide and therefore never overlap text.
   ObjectSetInteger(0,name,OBJPROP_BACK,back);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zorder);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
}

// A dashed-line section header:  ------- TITLE -------
string PnSectionText(string title,int width)
{
   int inner=width-StringLen(title)-2;
   if(inner<2) return title;
   int left=inner/2, right=inner-left;
   string s="";
   for(int i=0;i<left;i++)  s+="-";
   s+=" "+title+" ";
   for(int i=0;i<right;i++) s+="-";
   return s;
}

//-------------------------------------------------------------------------
//  CHROME FIRST.
//
//  MQL5 paints same-layer chart objects in creation order, so a background
//  rectangle created AFTER the labels covers them (this was the rendering
//  bug). Two independent safeguards are applied:
//    1. the background pane and the rules are CREATED before any label
//       (this function runs at the very top of RefreshPanel);
//    2. the background pane is flagged OBJPROP_BACK=true, which puts it in
//       the chart background layer regardless of creation order.
//  The objects are persistent - this only creates them once, then each
//  refresh just repositions/resizes them.
//-------------------------------------------------------------------------
void PnEnsureChrome()
{
   // The pane is OPAQUE and lives in the FOREGROUND (OBJPROP_BACK=false)
   // so candles, HTF markers, A/B/C/TRIGGER anchors, entry arrows and S/R
   // rectangles are all hidden wherever they fall under the dashboard.
   // Those chart annotations are themselves flagged OBJPROP_BACK=true, so
   // they stay in the chart background layer and remain fully visible
   // OUTSIDE the panel - nothing is ever deleted to achieve this.
   // Creating the pane BEFORE any label guarantees the labels (also
   // foreground) paint on top of it.
   PnRect("BG",     g_PnX,   g_PnY,   g_PnW, MathMax(40,g_PnH), clrPnBorder, clrPnBG,  0, false);
   PnRect("HdrLine",g_PnX+4, g_PnY+1, g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
   PnRect("Sep",    g_PnSepX,g_PnY+1, 1,       1, clrPnSep,    clrPnSep,    2, false);
   PnRect("FtLine", g_PnX+4, g_PnY+1, g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
}

//-------------------------------------------------------------------------
//  Row writers. Rows are pooled per column so objects are reused.
//-------------------------------------------------------------------------
int PnRowY(int row) { return g_PnBodyTop + row*g_PnRowH; }

//-------------------------------------------------------------------------
//  STABLE SEMANTIC SLOTS.
//
//  Object identity NEVER encodes a pixel offset. A slot is addressed by
//  (role, row) only, so changing PanelWidth / PanelFontSize / PanelRowHeight
//  / PanelX / PanelY merely MOVES existing objects instead of spawning a
//  second generation of orphaned labels.
//
//     LS_<row>  left  section rule        RS_<row>  right section rule
//     L1_<row>  left  label  1            RL_<row>  right label
//     V1_<row>  left  value  1            RV_<row>  right value
//     L2_<row>  left  label  2            RD_<i>    daily-profit value
//     V2_<row>  left  value  2            RT_<i>    recent-trade value
//-------------------------------------------------------------------------
void PnSlotL(string role,int row,int x,string text,color clr)
{
   if(row<0 || row>=PN_MAX_ROWS) return;
   PnLabel(role+"_"+IntegerToString(row),g_PnLeftX+x,PnRowY(row),text,clr,g_PnFont);
   if(row+1>g_PnLeftUsed) g_PnLeftUsed=row+1;
}

void PnSlotR(string role,int row,int x,string text,color clr)
{
   if(row<0 || row>=PN_MAX_ROWS) return;
   PnLabel(role+"_"+IntegerToString(row),g_PnRightX+x,PnRowY(row),text,clr,g_PnFont);
   if(row+1>g_PnRightUsed) g_PnRightUsed=row+1;
}

// Blank every semantic slot that can live on a LEFT row.
void PnLeftBlankRow(int row)
{
   string sr=IntegerToString(row);
   PnHideExisting("LS_"+sr);
   PnHideExisting("L1_"+sr); PnHideExisting("V1_"+sr);
   PnHideExisting("L2_"+sr); PnHideExisting("V2_"+sr);
}

// Blank every semantic slot that can live on a RIGHT row, including the
// recent-trade sub-columns and the daily-profit value. A spacer row MUST
// use this instead of a bare rr++ or a stale title survives on that row.
void PnRightBlankRow(int row)
{
   string sr=IntegerToString(row);
   PnHideExisting("RS_"+sr);
   PnHideExisting("RL_"+sr);
   PnHideExisting("RV_"+sr);
   PnHideExisting("RT_TIME_"+sr);
   PnHideExisting("RT_TYPE_"+sr);
   PnHideExisting("RT_RES_"+sr);
   PnHideExisting("RT_PL_"+sr);
   PnHideExisting("RD_"+sr);
}

// Blank every right-row slot EXCEPT the named role (used when a row holds
// a single spanning message such as "No closed trades yet").
void PnRightBlankRowExcept(int row,string keep)
{
   string sr=IntegerToString(row);
   if(keep!="RS")      PnHideExisting("RS_"+sr);
   if(keep!="RL")      PnHideExisting("RL_"+sr);
   if(keep!="RV")      PnHideExisting("RV_"+sr);
   if(keep!="RT_TIME") PnHideExisting("RT_TIME_"+sr);
   if(keep!="RT_TYPE") PnHideExisting("RT_TYPE_"+sr);
   if(keep!="RT_RES")  PnHideExisting("RT_RES_"+sr);
   if(keep!="RT_PL")   PnHideExisting("RT_PL_"+sr);
   if(keep!="RD")      PnHideExisting("RD_"+sr);
}

// Blank an ALREADY EXISTING slot. Never creates an object, so this can
// never leave MT5's default "Label" placeholder behind.
void PnHideExisting(string id)
{
   string name=PN_PREFIX+id;
   if(ObjectFind(0,name)>=0)
      ObjectSetString(0,name,OBJPROP_TEXT," ");
}

// Section header row
void PnLeftSection(int row,string title)
{
   PnSlotL("LS",row,0,PnSectionText(title,g_PnLeftCols),clrPnSection);
   PnHideExisting("L1_"+IntegerToString(row)); PnHideExisting("V1_"+IntegerToString(row));
   PnHideExisting("L2_"+IntegerToString(row)); PnHideExisting("V2_"+IntegerToString(row));
}
void PnRightSection(int row,string title)
{
   PnSlotR("RS",row,0,PnSectionText(title,g_PnRightCols),clrPnSection);
   string sr=IntegerToString(row);
   PnHideExisting("RL_"+sr);      PnHideExisting("RV_"+sr);
   PnHideExisting("RT_TIME_"+sr); PnHideExisting("RT_TYPE_"+sr);
   PnHideExisting("RT_RES_"+sr);  PnHideExisting("RT_PL_"+sr);
   PnHideExisting("RD_"+sr);
}

//-------------------------------------------------------------------------
//  FOUR-ZONE LEFT ROW:   [label1][value1]   [label2][value2]
//  Each zone has a computed pixel origin AND a character budget, so a long
//  value is truncated inside its own zone and can never touch the next
//  field or cross the divider.
//
//  Pass l2=="" for a wide single-pair row: value1 then gets the combined
//  width of zones 2..4, which is how long texts such as
//  "Breaking Resistance" or a block reason are displayed without squeezing.
//-------------------------------------------------------------------------
void PnLeftKV2(int row,string l1,string v1,color c1,string l2,string v2,color c2)
{
   PnSlotL("L1",row,g_PnZ1,PnFit(l1,g_PnZ1W),clrPnLabel);

   if(l2!="")
   {
      PnSlotL("V1",row,g_PnZ2,PnFit(v1,g_PnZ2W),c1);
      PnSlotL("L2",row,g_PnZ3,PnFit(l2,g_PnZ3W),clrPnLabel);
      PnSlotL("V2",row,g_PnZ4,PnFit(v2,g_PnZ4W),c2);
   }
   else
   {
      // FULL-WIDTH ROW: value 1 spans zones 2..4; the second pair's slots
      // are blanked IN PLACE (never re-created) so no "Label" can appear.
      PnSlotL("V1",row,g_PnZ2,PnFit(v1,g_PnZ2W+g_PnZ3W+g_PnZ4W),c1);
      PnHideExisting("L2_"+IntegerToString(row));
      PnHideExisting("V2_"+IntegerToString(row));
   }
   PnHideExisting("LS_"+IntegerToString(row));   // this row is not a section
}

//  RIGHT ROW: [label][value]  - same computed-zone principle.
void PnRightKV(int row,string label,string value,color vClr)
{
   PnSlotR("RL",row,g_PnRZ1,PnFit(label,g_PnRZ1W),clrPnLabel);
   // budget re-measured against the HARD right edge every frame
   int maxChars=(int)MathFloor((double)(g_PnRightEdge-(g_PnRightX+g_PnRZ2))/PnCharW());
   PnSlotR("RV",row,g_PnRZ2,PnFit(value,MathMin(g_PnRZ2W,maxChars)),vClr);
   PnHideExisting("RS_"+IntegerToString(row));
   PnHideExisting("RT_TIME_"+IntegerToString(row));
   PnHideExisting("RT_TYPE_"+IntegerToString(row));
   PnHideExisting("RT_RES_" +IntegerToString(row));
   PnHideExisting("RT_PL_"  +IntegerToString(row));
}

// Monospace advance width (px per character) for the configured font size.
double PnCharW()
{
   return g_PnFont*0.62+0.85;        // Consolas ~0.6em advance
}

// Approximate pixel width of N monospace characters.
int PnTextW(int chars)
{
   return (int)MathRound(chars*PnCharW());
}

//-------------------------------------------------------------------------
//  Blank the slots that a previous, longer frame used and this frame does
//  not. It knows NOTHING about pixel offsets, font size or geometry - it
//  only addresses stable semantic slot names, and only ever blanks objects
//  that already exist (so it can never create a stray "Label").
//-------------------------------------------------------------------------
void PnHideSurplus()
{
   // Blanks EVERY slot type that any previous frame could have created on
   // that row - section title, label/value pair, the four recent-trade
   // sub-columns and the daily-profit value.
   for(int r=g_PnLeftUsed;r<g_PnLeftPrev && r<PN_MAX_ROWS;r++)
      PnLeftBlankRow(r);
   for(int r=g_PnRightUsed;r<g_PnRightPrev && r<PN_MAX_ROWS;r++)
      PnRightBlankRow(r);

   g_PnLeftPrev =g_PnLeftUsed;
   g_PnRightPrev=g_PnRightUsed;
}

//-------------------------------------------------------------------------
//  Cached history scan: daily P/L series + recent closed trades + today's
//  win/loss statistics. Filtered strictly by this EA's MagicNumber and
//  _Symbol, closing deals only (DEAL_ENTRY_OUT), like OnTradeTransaction.
//-------------------------------------------------------------------------
void PnRebuildHistory()
{
   for(int i=0;i<PN_DAYS;i++)  { g_PnDayUsed[i]=false; g_PnDayPL[i]=0; g_PnDayLabel[i]="--"; }
   g_PnDayCount=0;
   g_PnTrCount=0;
   g_PnTodayWinSum=0; g_PnTodayLossSum=0;
   g_PnTodayTrades=0; g_PnTodayWins=0; g_PnTodayLosses=0;
   g_PnConsWins=0;

   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime todayStart=StructToTime(dt);                       // server-day boundary
   datetime from=todayStart-(datetime)((PN_DAYS-1)*86400);

   if(!HistorySelect(from,now+60)) return;

   int deals=HistoryDealsTotal();
   // Build the day buckets (index 0 = today, 1 = yesterday, ...).
   for(int d=0;d<PN_DAYS;d++)
   {
      datetime ds=todayStart-(datetime)(d*86400);
      MqlDateTime dd; TimeToStruct(ds,dd);
      g_PnDayLabel[d]=(d==0)?"Today":StringFormat("%02d/%02d",dd.mon,dd.day);
   }

   // Newest-first walk so the recent-trade list and the win streak are easy.
   bool streakOpen=true;
   for(int i=deals-1;i>=0;i--)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;

      double pl = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                + HistoryDealGetDouble(ticket,DEAL_SWAP)
                + HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      datetime tt=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);

      // Deal direction of the CLOSING deal is inverted vs the position.
      long dtype=HistoryDealGetInteger(ticket,DEAL_TYPE);
      string side=(dtype==DEAL_TYPE_SELL)?"Buy":"Sell";

      int dayIdx=(int)((long)(todayStart+86400-1-tt)/86400);
      if(tt>=todayStart) dayIdx=0;
      if(dayIdx>=0 && dayIdx<PN_DAYS)
      {
         g_PnDayPL[dayIdx]+=pl;
         g_PnDayUsed[dayIdx]=true;
      }

      if(tt>=todayStart)
      {
         g_PnTodayTrades++;
         if(pl>0)      { g_PnTodayWins++;   g_PnTodayWinSum+=pl; }
         else if(pl<0) { g_PnTodayLosses++; g_PnTodayLossSum+=pl; }
      }

      if(g_PnTrCount<PN_TRADES)
      {
         MqlDateTime td; TimeToStruct(tt,td);
         g_PnTrTime[g_PnTrCount]=StringFormat("%02d/%02d %02d:%02d",td.mon,td.day,td.hour,td.min);
         g_PnTrType[g_PnTrCount]=side;
         g_PnTrPL[g_PnTrCount]=pl;
         g_PnTrCount++;
      }

      if(streakOpen)
      {
         if(pl>0) g_PnConsWins++;
         else     streakOpen=false;
      }
   }

   for(int d=0;d<PN_DAYS;d++)
      if(g_PnDayUsed[d]) g_PnDayCount++;

   g_PnHistoryLast=now;
   g_PnHistoryDirty=false;
}

//-------------------------------------------------------------------------
//  INCREMENTAL cache update - called from OnTradeTransaction for each
//  closed deal of THIS EA. O(1): it shifts the recent-trade ring and adds
//  the profit to today's bucket. No HistorySelect(), no deal walk, so a
//  burst of small money-target closes costs essentially nothing.
//-------------------------------------------------------------------------
void PnPushClosedTrade(datetime dtime,bool wasBuy,double profit)
{
   // recent-trade ring: newest first
   for(int i=PN_TRADES-1;i>0;i--)
   {
      g_PnTrTime[i]=g_PnTrTime[i-1];
      g_PnTrType[i]=g_PnTrType[i-1];
      g_PnTrPL[i]  =g_PnTrPL[i-1];
   }
   MqlDateTime td; TimeToStruct(dtime,td);
   g_PnTrTime[0]=StringFormat("%02d/%02d %02d:%02d",td.mon,td.day,td.hour,td.min);
   g_PnTrType[0]=(wasBuy?"Buy":"Sell");
   g_PnTrPL[0]  =profit;
   if(g_PnTrCount<PN_TRADES) g_PnTrCount++;

   // today's bucket + statistics
   if(g_PnDayCount>0) g_PnDayPL[0]+=profit; else { g_PnDayPL[0]=profit; g_PnDayCount=1; }
   g_PnDayUsed[0]=true;
   g_PnTodayTrades++;
   if(profit>0)      { g_PnTodayWins++;   g_PnTodayWinSum+=profit;  g_PnConsWins++; }
   else if(profit<0) { g_PnTodayLosses++; g_PnTodayLossSum+=profit; g_PnConsWins=0; }
}

//-------------------------------------------------------------------------
//  The expensive full rebuild runs at most once per PanelHistoryRefreshSec
//  (default 60 s) or when a new day starts. Everything in between is
//  served from the incremental cache above.
//-------------------------------------------------------------------------
void PnMaybeRebuildHistory()
{
   int every=MathMax(5,PanelHistoryRefreshSec);
   if(g_PnHistoryDirty || g_PnHistoryLast==0 ||
      (long)TimeCurrent()-(long)g_PnHistoryLast>=every)
      PnRebuildHistory();
}

//-------------------------------------------------------------------------
//  DISPLAY STATE CACHE - refreshed once per throttled panel update.
//  This is the ONLY place where the renderer is allowed to consult the
//  engine's read-only predicates; the render code itself then reads the
//  cached values. All of these functions are pure (no state mutation),
//  so calling them here cannot influence trading in any way.
//-------------------------------------------------------------------------
void PanelRefreshStateCache()
{
   g_PanelAlignedBias=AlignedBias();
   g_PanelSpreadOK   =SpreadOK();
   g_PanelVolOK      =VolOK();
   g_PanelInSession  =InSession();
   g_PanelActiveSetups=CountActiveSetups();
   g_PanelReadySetups =CountReadySetups();

   ENUM_BIAS probe=(g_PanelAlignedBias==ALIGN_BEARISH)?BIAS_BEARISH:BIAS_BULLISH;

   string why="";
   g_PanelEntryPermission=CheckEntryPermissions(probe,why);
   g_PanelBlockReason=why;

   g_PanelSRBlocked=false;
   g_PanelSRReason="";
   if(g_SRActive)
   {
      string srWhy="";
      g_PanelSRBlocked=SRIsBlockingReadySetup(srWhy);
      if(!g_PanelSRBlocked)
         g_PanelSRBlocked=SRBlockReasonForDirection(probe,srWhy);
      g_PanelSRReason=srWhy;
   }
}

//-------------------------------------------------------------------------
//  EVENT-DRIVEN CHART ANNOTATIONS.
//  Each family redraws only when its own dirty flag is set, i.e. when a
//  pivot/zone/setup actually changed. Returns true if anything was drawn.
//-------------------------------------------------------------------------
bool UpdateChartVisualsIfDirty()
{
   bool changed=false;

   if(g_HTFVisualDirty)
   {
      DrawHTFVisuals();
      g_HTFVisualDirty=false;
      changed=true;
   }

   if(g_SRVisualDirty)
   {
      DrawSRZones();          // internally a no-op when the module is OFF
      g_SRVisualDirty=false;
      changed=true;
   }

   if(g_SetupVisualDirty)
   {
      DrawAllSetupVisuals();
      g_SetupVisualDirty=false;
      changed=true;
   }

   return changed;
}

// Kept as a named entry point for clarity / future use.
void UpdateChartVisuals()
{
   g_HTFVisualDirty=true; g_SRVisualDirty=g_SRActive; g_SetupVisualDirty=true;
   UpdateChartVisualsIfDirty();
}

//-------------------------------------------------------------------------
//  Status determination (header lamp + left STATUS row).
//  Reflects the REAL runtime state only - never hardcoded.
//-------------------------------------------------------------------------
void PnHeaderStatus(string &txt,color &clr)
{
   if(!g_InitComplete)                            { txt="ERROR";      clr=clrPnBad;  return; }
   if(g_HaltedFloat && CloseAllOnEmergencyLoss)   { txt="EMERGENCY";  clr=clrPnBad;  return; }
   if(g_HaltedFloat)                              { txt="BLOCKED";    clr=clrPnBad;  return; }
   if(g_HaltedDaily || g_HaltedConsec)            { txt="BLOCKED";    clr=clrPnBad;  return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
                                                  { txt="DISABLED";   clr=clrPnDim;  return; }
   if(!UseM1)                                     { txt="DISABLED";   clr=clrPnDim;  return; }
   if(g_PanelOpenTradeCount>0)                    { txt="TRADING";    clr=clrPnGood; return; }
   if(!g_PanelInSession || !g_PanelSpreadOK || !g_PanelVolOK)
                                                  { txt="WAITING";    clr=clrPnWarn; return; }
   if(g_PanelAlignedBias==ALIGN_CONFLICT)         { txt="WAITING";    clr=clrPnWarn; return; }
   if(g_ConsLoss>0)                               { txt="RECOVERING"; clr=clrPnWarn; return; }
   txt="TRADING"; clr=clrPnGood;
}


//-------------------------------------------------------------------------
//  Detailed EA status line (same wording/priority as the previous panel).
//-------------------------------------------------------------------------
void DetermineStatus(string &status,color &clr)
{
   if(!g_InitComplete)   { status="INITIALIZING";                  clr=clrPnDim;  return; }
   if(g_HaltedDaily)     { status="BLOCKED (daily loss halt)";     clr=clrPnBad;  return; }
   if(g_HaltedConsec)    { status="BLOCKED (loss streak halt)";    clr=clrPnBad;  return; }
   if(g_HaltedFloat)     { status="BLOCKED (floating loss halt)";  clr=clrPnBad;  return; }

   if(g_SRActive && g_PanelSRBlocked)
   { status="TRADE BLOCKED - "+g_PanelSRReason; clr=clrPnBad; return; }

   int open=g_PanelOpenTradeCount;
   if(open>0)            { status=StringFormat("ACTIVE (managing %d/%d trades)",open,g_MaxOpenTrades);
                           clr=clrPnGood; return; }
   if(!UseM1)            { status="M1 DISABLED (no new setups; managing only)"; clr=clrPnWarn; return; }

   ENUM_ALIGN_RESULT aligned=g_PanelAlignedBias;
   if(aligned!=ALIGN_CONFLICT)
                         { status="ACTIVE (scanning "+AlignResultToStr(aligned)+")"; clr=clrPnGood; return; }
   status="NO NEW SETUPS (HTF conflict)"; clr=clrPnWarn;
}

// Reuses the existing DetermineStatus() wording for the detailed line.
string PnDetailStatus(color &clr)
{
   string s; color c;
   DetermineStatus(s,c);
   clr=c;
   return s;
}

//-------------------------------------------------------------------------
//  Cleanup - removes EVERY object this panel created.
//-------------------------------------------------------------------------
void ClearPanelObjects()
{
   ObjectsDeleteAll(0,PN_PREFIX);
   g_PnLeftUsed=0;  g_PnLeftPrev=0;
   g_PnRightUsed=0; g_PnRightPrev=0;
}

//-------------------------------------------------------------------------
//  Latest ACTIVE setup (used by the SETUP STATUS block).
//-------------------------------------------------------------------------
int LatestSetupIndex()
{
   int best=-1; datetime bestT=0;
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active && (best<0 || g_Setups[i].createdTime>bestT))
      { best=i; bestT=g_Setups[i].createdTime; }
   return best;
}

//=========================================================================
//                          THE DASHBOARD RENDERER
//=========================================================================
void RefreshPanel()
{
   if(!DebugMode) { ClearPanelObjects(); return; }

   // ---- geometry from the configurable inputs ----
   g_PnX   =MathMax(0,PanelX);
   g_PnY   =MathMax(0,PanelY);
   g_PnFont=MathMax(6,MathMin(PanelFontSize,14));
   g_PnRowH=MathMax(g_PnFont+3,PanelRowHeight);
   g_PnW   =MathMax(560,PanelWidth);

   int pad=12;
   g_PnColW  =(g_PnW-pad*3)/2;
   g_PnLeftX =g_PnX+pad;
   g_PnSepX  =g_PnX+pad+g_PnColW+pad/2;
   g_PnRightX=g_PnSepX+pad;

   //---------------------------------------------------------------------
   //  COMPUTED FIELD ZONES (replaces the old hard-coded PnTextW(17/29/47)
   //  offsets). Everything below is derived from the column width and the
   //  current font, so the layout stays correct when PanelWidth or
   //  PanelFontSize change.
   //
   //     |<-- Z1 label -->|<-- Z2 value -->|<-- Z3 label -->|<-- Z4 value -->|
   //---------------------------------------------------------------------
   int colChars=(int)MathFloor((double)(g_PnColW-pad)/PnCharW());
   if(colChars<40) colChars=40;
   g_PnLeftCols=colChars;

   // REAL PIXEL GAPS - not merely estimated character widths. Each zone has
   // a pixel origin plus a character budget used only for truncation.
   double cw=PnCharW();
   int labelValueGap=10;    // px between a label and its own value
   int pairGap      =18;    // px between the first and the second pair
   int usable =g_PnColW-pad;
   int pairPx =(usable-pairGap)/2;
   int labelPx=(int)MathRound(pairPx*0.52);
   int valuePx=pairPx-labelPx;

   g_PnZ1=0;
   g_PnZ2=labelPx+labelValueGap;
   g_PnZ3=pairPx+pairGap;
   g_PnZ4=g_PnZ3+labelPx+labelValueGap;

   g_PnZ1W=(int)MathMax(6,MathFloor((labelPx-labelValueGap)/cw));
   g_PnZ2W=(int)MathMax(6,MathFloor((valuePx-4)/cw));
   g_PnZ3W=g_PnZ1W;
   g_PnZ4W=(int)MathMax(6,MathFloor((double)(usable-g_PnZ4-4)/cw));

   //---------------------------------------------------------------------
   //  RIGHT COLUMN - bounded by a HARD pixel edge, not by a character
   //  guess. Everything on the right is measured backwards from
   //  g_PnRightEdge so no value can ever cross the cyan border.
   //---------------------------------------------------------------------
   g_PnRightEdge = g_PnX + g_PnW - PN_RPAD;          // absolute px
   int rUsable   = g_PnRightEdge - g_PnRightX;       // real drawable width
   if(rUsable<80) rUsable=80;

   g_PnRightCols=(int)MathMax(20,MathFloor((double)rUsable/cw));

   int rLabelPx=(int)MathRound(rUsable*0.44);
   g_PnRZ1=0;
   g_PnRZ2=rLabelPx+labelValueGap;
   g_PnRZ1W=(int)MathMax(8,MathFloor((double)(rLabelPx-labelValueGap)/cw));
   // value budget measured to the hard edge
   g_PnRZ2W=(int)MathMax(6,MathFloor((double)(rUsable-g_PnRZ2)/cw));

   //---- RECENT TRADES: four independent, non-overlapping columns -------
   int colGap=10;
   g_PnTrWTime=11;                                   // "03/09 15:42"
   g_PnTrWType=4;                                    // "Sell"
   g_PnTrWRes =4;                                    // "LOSS"
   g_PnTrXTime=g_PnRightX;
   g_PnTrXType=g_PnTrXTime+PnTextW(g_PnTrWTime)+colGap;
   g_PnTrXRes =g_PnTrXType+PnTextW(g_PnTrWType)+colGap;
   g_PnTrXPL  =g_PnTrXRes +PnTextW(g_PnTrWRes )+colGap;
   g_PnTrWPL  =(int)MathMax(5,MathFloor((double)(g_PnRightEdge-g_PnTrXPL)/cw));

   int headerH=g_PnRowH+12;
   g_PnBodyTop=g_PnY+headerH+6;

   // >>> CHROME FIRST: the background pane and the rules must exist before
   //     a single label object is created, otherwise MT5's creation-order
   //     painting hides the text behind the pane. <<<
   PnEnsureChrome();

   PnMaybeRebuildHistory();

   g_PnLeftUsed=0; g_PnRightUsed=0;

   //=====================  LIVE DATA SNAPSHOT  ==========================
   double bal   =AccountInfoDouble(ACCOUNT_BALANCE);
   double eq    =AccountInfoDouble(ACCOUNT_EQUITY);
   double freeM =AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usedM =AccountInfoDouble(ACCOUNT_MARGIN);
   double mlevel=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   long   lev   =AccountInfoInteger(ACCOUNT_LEVERAGE);

   // Cached snapshot published by ManageOpenPositions() - the panel does
   // NOT walk the position list itself.
   int    oTotal =g_PanelOpenTradeCount;
   int    oBuys  =g_PanelBuyCount;
   int    oSells =g_PanelSellCount;
   double oVol   =g_PanelOpenVolume;
   double oFloat =g_PanelFloatPL;
   double oAvgBuy =g_PanelAvgBuy;
   double oAvgSell=g_PanelAvgSell;

   int spreadPts=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   //=========================  HEADER  ==================================
   string stTxt; color stClr; PnHeaderStatus(stTxt,stClr);

   int totalRows=0;   // computed after the columns are built
   // (the background is sized at the end - create it first at z-order 0)

   // Three clearly separated header regions: name (left), symbol+TF
   // (centred), status lamp (right-aligned inside the pane).
   //  Three independent header regions. The status is aligned from the
   //  RIGHT EDGE inward with a guaranteed PN_RPAD gap, and is truncated if
   //  a very long status would ever reach the centre block - so TRADING /
   //  WAITING / BLOCKED / RECOVERING / EMERGENCY / DISABLED / ERROR all
   //  sit safely inside the border.
   int hdrFont=g_PnFont+2;
   double hdrCharW=hdrFont*0.62+0.85;
   // vertically centre the header text inside the header band
   int hdrTextH=(int)MathRound(hdrFont*1.35);
   int hdrY=g_PnY+(headerH-hdrTextH)/2;
   if(hdrY<g_PnY+3) hdrY=g_PnY+3;

   string hdrName="XAUUSD_TrendContinuation_V13 | v13.4";
   string hdrSym =_Symbol+"   "+PnTFName(_Period);
   string hdrStat=stTxt+"  "+ShortToString(0x25CF);

   int statW=(int)MathRound(StringLen(hdrStat)*hdrCharW);
   int statX=g_PnX+g_PnW-PN_RPAD-statW;
   // never let the status run back into the centred symbol block
   int nameEnd=g_PnLeftX+(int)MathRound(StringLen(hdrName)*hdrCharW);
   if(statX<nameEnd+20)
   {
      int avail=(int)MathFloor((double)(g_PnX+g_PnW-PN_RPAD-(nameEnd+20))/hdrCharW);
      hdrStat=PnFit(hdrStat,MathMax(4,avail));
      statW=(int)MathRound(StringLen(hdrStat)*hdrCharW);
      statX=g_PnX+g_PnW-PN_RPAD-statW;
   }

   int symX=g_PnX+(g_PnW-(int)MathRound(StringLen(hdrSym)*hdrCharW))/2;
   if(symX<nameEnd+16) symX=nameEnd+16;
   if(symX+(int)MathRound(StringLen(hdrSym)*hdrCharW)>statX-16)
      symX=statX-16-(int)MathRound(StringLen(hdrSym)*hdrCharW);

   PnLabel("HdrName",g_PnLeftX,hdrY,hdrName,clrPnTitle,hdrFont);
   PnLabel("HdrSym", symX,    hdrY,hdrSym, clrPnValue,hdrFont);
   // Status lamp is a foreground label -> always above the opaque pane.
   PnLabel("HdrStat",statX,   hdrY,hdrStat,stClr,hdrFont);

   //=======================  LEFT COLUMN  ===============================
   int r=0;

   // ---- A. ACCOUNT & RISK ----
   PnLeftSection(r++,"ACCOUNT & RISK");
   PnLeftKV2(r++,"Balance",   StringFormat("%.2f USD",bal), clrPnValue,
                 "Profit Target", StringFormat("%.2f USD",g_ProfitTargetUSD), clrPnGood);
   PnLeftKV2(r++,"Equity",    StringFormat("%.2f USD",eq),  clrPnValue,
                 "Max Trades",StringFormat("%d",g_MaxOpenTrades), clrPnValue);
   PnLeftKV2(r++,"Floating P/L", StringFormat("%+.2f USD",oFloat), PnPLColor(oFloat),
                 "Lot Size",  StringFormat("%.2f",g_LotSize), clrPnValue);
   PnLeftKV2(r++,"Free Margin",  StringFormat("%.2f USD",freeM), clrPnValue,
                 "Spread",    StringFormat("%d / %d pts",spreadPts,g_MaxSpreadPoints),
                 (g_PanelSpreadOK?clrPnGood:clrPnBad));
   PnLeftKV2(r++,"Margin Level", (usedM>0?StringFormat("%.1f %%",mlevel):"--"),
                 (usedM>0 && mlevel<200 ? clrPnWarn : clrPnValue),
                 "Leverage",  StringFormat("1:%d",(int)lev), clrPnValue);
   PnLeftBlankRow(r++);

   // ---- B. TRADE SAFETY ----
   PnLeftSection(r++,"TRADE SAFETY");
   double curLoss=(oFloat<0)?-oFloat:0.0;
   PnLeftKV2(r++,"Max Float Loss", StringFormat("%.2f USD",g_MaxFloatingLossUSD), clrPnValue,
                 "Current Loss",   StringFormat("%.2f USD",curLoss),
                 (curLoss>0?clrPnBad:clrPnGood));
   PnLeftKV2(r++,"Close All Emerg",(CloseAllOnEmergencyLoss?"YES":"NO"),
                 (CloseAllOnEmergencyLoss?clrPnGood:clrPnWarn),
                 "Daily Loss Lim", (g_DailyLossLimitPercent>0?
                     StringFormat("%.2f %%",g_DailyLossLimitPercent):"OFF"), clrPnValue);
   PnLeftKV2(r++,"Consec Loss Lim",(g_ConsecutiveLossLimit>0?
                     StringFormat("%d",g_ConsecutiveLossLimit):"OFF"), clrPnValue,
                 "Consec Losses",  StringFormat("%d",g_ConsLoss),
                 (g_ConsLoss>0?clrPnWarn:clrPnGood));
   string permTxt; color permClr;
   if(g_PanelEntryPermission) { permTxt="ALLOWED"; permClr=clrPnGood; }
   else                       { permTxt=g_PanelBlockReason; permClr=clrPnBad; }
   PnLeftKV2(r++,"Daily Status", (g_HaltedDaily?"HALTED":"NORMAL"),
                 (g_HaltedDaily?clrPnBad:clrPnGood),"","",clrPnDim);
   PnLeftKV2(r++,"Trade Permit", permTxt, permClr, "","",clrPnDim);   // wide row
   PnLeftBlankRow(r++);

   // ---- C. MULTI-TIMEFRAME BIAS ----
   PnLeftSection(r++,"MULTI-TIMEFRAME BIAS");
   {
      color h1C =(!UseH1) ?clrPnDim:((g_H1.bias==BIAS_BULLISH)?clrPnGood:(g_H1.bias==BIAS_BEARISH?clrPnBad:clrPnDim));
      color m15C=(!UseM15)?clrPnDim:((g_M15.bias==BIAS_BULLISH)?clrPnGood:(g_M15.bias==BIAS_BEARISH?clrPnBad:clrPnDim));
      color m5C =(!UseM5) ?clrPnDim:((g_M5.bias==BIAS_BULLISH)?clrPnGood:(g_M5.bias==BIAS_BEARISH?clrPnBad:clrPnDim));

      string h1V =UseH1 ?(g_H1.bias==BIAS_BULLISH?"BULLISH":(g_H1.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL")):"OFF";
      string m15V=UseM15?(g_M15.bias==BIAS_BULLISH?"BULLISH":(g_M15.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL")):"OFF";
      string m5V =UseM5 ?(g_M5.bias==BIAS_BULLISH?"BULLISH":(g_M5.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL")):"OFF";

      ENUM_ALIGN_RESULT al=g_PanelAlignedBias;
      string alV=(al==ALIGN_BULLISH)?"BULLISH":
                 (al==ALIGN_BEARISH)?"BEARISH":
                 (al==ALIGN_NOFILTER)?"NO FILTER":"CONFLICT";
      color  alC=(al==ALIGN_BULLISH)?clrPnGood:(al==ALIGN_BEARISH)?clrPnBad:
                 (al==ALIGN_NOFILTER)?clrPnValue:clrPnWarn;

      string m1V =UseM1?alV:"OFF";
      color  m1C =UseM1?alC:clrPnDim;

      PnLeftKV2(r++,"H1  Big Direct", h1V, h1C,  "", "", clrPnDim);
      PnLeftKV2(r++,"M15 Structure",  m15V,m15C, "", "", clrPnDim);
      PnLeftKV2(r++,"M5  Regime",     m5V, m5C,  "", "", clrPnDim);
      PnLeftKV2(r++,"M1  Entry",      m1V, m1C,  "", "", clrPnDim);
      PnLeftKV2(r++,"Aligned Bias",   alV, alC,  "", "", clrPnDim);
   }
   PnLeftBlankRow(r++);

   // ---- D. M30 SUPPORT/RESISTANCE FILTER ----
   PnLeftSection(r++,"M30 S/R FILTER");
   if(!g_SRActive)
   {
      // Module genuinely off: no S/R computation is performed for display.
      PnLeftKV2(r++,"Status","DISABLED",clrPnDim,"","",clrPnDim);
      PnLeftKV2(r++,"Entry Filter","N/A",clrPnDim,"","",clrPnDim);
      PnLeftKV2(r++,"Nearest Zone","--",clrPnDim,"","",clrPnDim);
      PnLeftKV2(r++,"Confirmation","--",clrPnDim,"","",clrPnDim);
   }
   else
   {
      MqlTick tkp; bool haveTick=SymbolInfoTick(_Symbol,tkp);
      double pt=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      string zoneTxt="--", dirTxt="--";
      color  dirClr=clrPnDim;

      double nearestPrice=0; bool nearestIsRes=false; double bestDist=DBL_MAX;
      for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
      {
         if(!g_SRZones[i].valid) continue;
         double p=haveTick?(g_SRZones[i].isResistance?tkp.ask:tkp.bid):0;
         if(p<=0) continue;
         double d;
         if(p>g_SRZones[i].upper)      d=p-g_SRZones[i].upper;
         else if(p<g_SRZones[i].lower) d=g_SRZones[i].lower-p;
         else                          d=0;
         if(d<bestDist)
         { bestDist=d; nearestPrice=(g_SRZones[i].upper+g_SRZones[i].lower)/2.0;
           nearestIsRes=g_SRZones[i].isResistance; }
      }
      if(nearestPrice>0 && pt>0)
      {
         zoneTxt=StringFormat("%.1f pts",bestDist/pt);
         dirTxt =nearestIsRes?"RESISTANCE":"SUPPORT";
         dirClr =nearestIsRes?clrPnBad:clrPnGood;
      }

      // Highest live confirmation progress among the valid zones.
      int confNow=0;
      for(int i=0;i<g_SRZoneCount && i<SR_MAX_ZONES;i++)
         if(g_SRZones[i].valid && g_SRZones[i].breakCount>confNow) confNow=g_SRZones[i].breakCount;

      // Entry-filter verdict from the cache, which was produced by THE SAME
      // functions the entry logic uses (see PanelRefreshStateCache).
      string srWhy=g_PanelSRReason;
      bool   srBlocked=g_PanelSRBlocked;

      // Long state strings ("Breaking Resistance") get the wide row form.
      PnLeftKV2(r++,"Status",SRStateToStr(g_SRState),
                    (g_SRState==SR_NO_VALID?clrPnDim:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Entry Filter",(srBlocked?"BLOCKED":"ALLOWED"),
                    (srBlocked?clrPnBad:clrPnGood),"","",clrPnDim);
      PnLeftKV2(r++,"Nearest Zone",zoneTxt,clrPnValue,"","",clrPnDim);
      PnLeftKV2(r++,"Direction",dirTxt,dirClr,"","",clrPnDim);
      PnLeftKV2(r++,"Confirmation",StringFormat("%d / %d",confNow,g_SRBreakConfirmBars),
                    (confNow>0?clrPnWarn:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Zones",StringFormat("%d / %d",g_SRZoneCount,SR_MAX_ZONES),
                    clrPnValue,"","",clrPnDim);
      if(srBlocked && srWhy!="")
         PnLeftKV2(r++,"Block Reason",srWhy,clrPnBad,"","",clrPnDim);   // wide row
   }
   PnLeftBlankRow(r++);

   // ---- E. OPEN TRADES ----
   PnLeftSection(r++,"OPEN TRADES");
   PnLeftKV2(r++,"Total Trades",StringFormat("%d / %d",oTotal,g_MaxOpenTrades),
                 (oTotal>0?clrPnGood:clrPnValue),
                 "Total Volume",StringFormat("%.2f",oVol),clrPnValue);
   PnLeftKV2(r++,"Buy Trades",StringFormat("%d",oBuys),(oBuys>0?clrPnGood:clrPnValue),
                 "Avg Buy",(oAvgBuy>0?DoubleToString(oAvgBuy,_Digits):"--"),clrPnValue);
   PnLeftKV2(r++,"Sell Trades",StringFormat("%d",oSells),(oSells>0?clrPnBad:clrPnValue),
                 "Avg Sell",(oAvgSell>0?DoubleToString(oAvgSell,_Digits):"--"),clrPnValue);
   PnLeftKV2(r++,"Floating P/L",StringFormat("%+.2f USD",oFloat),PnPLColor(oFloat),
                 "Target/Pos",StringFormat("+%.2f USD",g_ProfitTargetUSD),clrPnGood);
   PnLeftBlankRow(r++);

   // ---- F. SETUP STATUS ----
   PnLeftSection(r++,"SETUP STATUS");
   {
      int li=LatestSetupIndex();
      if(li<0)
      {
         PnLeftKV2(r++,"Current Setup",(UseM1?"NONE":"M1 DISABLED"),
                       (UseM1?clrPnDim:clrPnWarn),
                       "Active / Ready",StringFormat("%d / %d",g_PanelActiveSetups,g_PanelReadySetups),
                       clrPnValue);
         PnLeftKV2(r++,"Breakout","--",clrPnDim,"","",clrPnDim);
         PnLeftKV2(r++,"Permission","--",clrPnDim,"","",clrPnDim);
      }
      else
      {
         M1Setup s=g_Setups[li];
         string stage=(s.state==MS_WAIT_B)?"A":(s.state==MS_WAIT_C)?"B":
                      (s.state==MS_WAIT_TRIGGER)?"C":"TRIGGER";
         string dirS =(s.direction==BIAS_BULLISH)?"BUY":"SELL";
         color  dirC =(s.direction==BIAS_BULLISH)?clrPnGood:clrPnBad;

         string boTxt=(s.state==MS_WAIT_BREAK)
                      ? ((s.entryStatus==""||s.entryStatus=="WAITING")?"ARMED":s.entryStatus)
                      : "PENDING";
         color  boClr=(s.state==MS_WAIT_BREAK)?clrPnWarn:clrPnDim;
         if(s.entryStatus=="EXECUTED") boClr=clrPnGood;
         if(s.entryStatus=="BLOCKED" || s.entryStatus=="FAILED") boClr=clrPnBad;

         // Entry window = whole bars left before the age expiry retires it.
         string winTxt="--";
         if(g_SetupExpiryMinutes>0)
         {
            long leftSec=(long)g_SetupExpiryMinutes*60-((long)TimeCurrent()-(long)s.createdTime);
            if(leftSec<0) leftSec=0;
            winTxt=StringFormat("%d bars",(int)(leftSec/60));
         }

         // Cached verdict (computed once per refresh in PanelRefreshStateCache).
         string permTxt2; color permClr2;
         if(g_PanelEntryPermission) { permTxt2="ALLOWED"; permClr2=clrPnGood; }
         else                       { permTxt2=g_PanelBlockReason; permClr2=clrPnBad; }

         string aTxt=(s.A>0)?DoubleToString(s.A,_Digits):"--";
         string bTxt=(s.B>0)?DoubleToString(s.B,_Digits):"--";
         string cTxt=(s.C>0)?DoubleToString(s.C,_Digits):"--";
         string tTxt=(s.trigger>0)?DoubleToString(s.trigger,_Digits):"--";

         PnLeftKV2(r++,"ID / Direction",StringFormat("#%d  %s",(int)s.id,dirS),dirC,
                       "Active / Ready",StringFormat("%d / %d",g_PanelActiveSetups,g_PanelReadySetups),
                       clrPnValue);
         PnLeftKV2(r++,"Stage",stage,dirC,"","",clrPnDim);
         PnLeftKV2(r++,"Validity",(s.active?"VALID":"RETIRED"),
                       (s.active?clrPnGood:clrPnDim),"","",clrPnDim);
         PnLeftKV2(r++,"Active / Ready",
                       StringFormat("%d / %d",g_PanelActiveSetups,g_PanelReadySetups),
                       clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"A",aTxt,clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"B",bTxt,clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"C",cTxt,clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"Trigger",tTxt,(s.trigger>0?clrPnWarn:clrPnDim),"","",clrPnDim);
         PnLeftKV2(r++,"Breakout",boTxt,boClr,"","",clrPnDim);
         PnLeftKV2(r++,"Quality",s.breakoutQuality,
                       (s.breakoutQuality=="PASS"?clrPnGood:
                        s.breakoutQuality=="WEAK"?clrPnWarn:clrPnDim),"","",clrPnDim);
         PnLeftKV2(r++,"Pullback",
                       (s.pullbackDistance>0?DoubleToString(s.pullbackDistance,2):"--"),
                       clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"Entry Window",winTxt,clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"Permission",permTxt2,permClr2,"","",clrPnDim);   // wide row
         if(s.entryStatus=="BLOCKED" && s.blockReason!="")
            PnLeftKV2(r++,"Block Reason",s.blockReason,clrPnBad,"","",clrPnDim);
      }
   }
   PnLeftBlankRow(r++);

   // ---- H. TODAY'S REPORT ----
   PnLeftSection(r++,"TODAY'S REPORT");
   {
      double todayNet=g_PnTodayWinSum+g_PnTodayLossSum;
      double wr=(g_PnTodayWins+g_PnTodayLosses>0)
                ? 100.0*g_PnTodayWins/(g_PnTodayWins+g_PnTodayLosses) : 0.0;

      // Intraday equity drawdown (display-only tracking, see OnTick hook).
      string ddTxt=(g_PnDayPeakEquity>0)?StringFormat("%.2f %%",g_PnDayDDPct):"--";

      PnLeftKV2(r++,"Trades",StringFormat("%d",g_PnTodayTrades),clrPnValue,"","",clrPnDim);
      PnLeftKV2(r++,"Win Rate",
                    (g_PnTodayWins+g_PnTodayLosses>0?StringFormat("%.2f %%",wr):"--"),
                    (wr>=50?clrPnGood:clrPnWarn),"","",clrPnDim);
      PnLeftKV2(r++,"Daily P/L",StringFormat("%+.2f USD",todayNet),
                    PnPLColor(todayNet),"","",clrPnDim);
      PnLeftKV2(r++,"Total Profit",StringFormat("%.2f USD",g_PnTodayWinSum),
                    clrPnGood,"","",clrPnDim);
      PnLeftKV2(r++,"Total Loss",StringFormat("%.2f USD",g_PnTodayLossSum),
                    (g_PnTodayLossSum<0?clrPnBad:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Consec Wins",StringFormat("%d",g_PnConsWins),
                    (g_PnConsWins>0?clrPnGood:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Consec Losses",StringFormat("%d",g_ConsLoss),
                    (g_ConsLoss>0?clrPnBad:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Max Drawdown",ddTxt,
                    (g_PnDayDDPct>0?clrPnWarn:clrPnValue),"","",clrPnDim);
      color dsClr; string dsTxt=PnDetailStatus(dsClr);
      color mapped=(dsClr==clrPnBad)?clrPnBad:dsClr;
      PnLeftKV2(r++,"EA Status",dsTxt,mapped,"","",clrPnDim);   // wide row
   }

   //=======================  RIGHT COLUMN  ==============================
   int rr=0;

   // ---- A. MAX FLOATING LOSS ----
   PnRightSection(rr++,"MAX FLOATING LOSS");
   {
      double lim=g_MaxFloatingLossUSD;
      double cur=(oFloat<0)?-oFloat:0.0;
      string curTxt,limTxt; color curClr;
      if(oFloat>=0)
      {
         curTxt=StringFormat("%.2f USD  (0.00%%)",0.0);
         curClr=clrPnGood;
      }
      else
      {
         curTxt=StringFormat("%.2f USD  %s",cur,PnPct(cur,lim));
         double ratio=(lim>0)?cur/lim:0;
         curClr=(ratio>=0.75)?clrPnBad:(ratio>=0.4)?clrPnWarn:clrPnValue;
      }
      limTxt=(lim>0)?StringFormat("%.2f USD  (100.00%%)",lim):"DISABLED";

      string emTxt; color emClr;
      if(g_HaltedFloat)                   { emTxt="TRIGGERED"; emClr=clrPnBad; }
      else if(lim<=0)                     { emTxt="OFF";       emClr=clrPnDim; }
      else if(cur>=lim*0.75)              { emTxt="WARNING";   emClr=clrPnWarn; }
      else                                { emTxt="NORMAL";    emClr=clrPnGood; }

      PnRightKV(rr++,"Current",curTxt,curClr);
      PnRightKV(rr++,"Limit",limTxt,clrPnValue);
      PnRightKV(rr++,"Float P/L",StringFormat("%+.2f USD",oFloat),PnPLColor(oFloat));
      PnRightKV(rr++,"Status",emTxt,emClr);
      PnRightKV(rr++,"Close All",(CloseAllOnEmergencyLoss?"ENABLED":"DISABLED"),
                (CloseAllOnEmergencyLoss?clrPnGood:clrPnWarn));
   }
   PnRightBlankRow(rr++);

   // ---- B. DAILY PROFIT HISTORY ----
   PnRightSection(rr++,"DAILY PROFIT");
   {
      // Always render all PN_DAYS slots. A day with no EA trades shows a
      // real zero; a day with no data at all shows "--" (never fabricated).
      for(int d=0;d<PN_DAYS;d++)
      {
         string lbl=(g_PnDayLabel[d]!="")?g_PnDayLabel[d]:"--";
         PnSlotR("RL",rr,g_PnRZ1,PnFit(lbl,g_PnRZ1W),clrPnLabel);
         PnHideExisting("RS_"+IntegerToString(rr));
         PnHideExisting("RV_"+IntegerToString(rr));
         string vTxt; color vClr;
         if(!g_PnDayUsed[d])
         {
            vTxt=PnPadLeft("--",g_PnRZ2W); vClr=clrPnDim;
         }
         else
         {
            double v=g_PnDayPL[d];
            double refBal=bal-v;
            string pctTxt=(refBal>0.0)?StringFormat(" (%.2f%%)",100.0*v/refBal):"";
            vTxt=PnPadLeft(StringFormat("%+.2f USD%s",v,pctTxt),g_PnRZ2W);
            vClr=PnPLColor(v);
         }
         int dMax=(int)MathFloor((double)(g_PnRightEdge-(g_PnRightX+g_PnRZ2))/PnCharW());
         PnSlotR("RD",rr,g_PnRZ2,PnFit(vTxt,dMax),vClr);
         PnHideExisting("RV_"+IntegerToString(rr));
         rr++;
      }
   }
   PnRightBlankRow(rr++);

   // ---- C. RECENT TRADES ----
   //  FOUR independent, individually positioned labels per row. Nothing is
   //  concatenated into a padded string any more, so "SellWIN" /
   //  "TypeResult" collisions are structurally impossible. The P/L column
   //  is right-aligned against the hard right edge.
   PnRightSection(rr++,"RECENT TRADES");
   {
      // header - one label per column, same origins as the data rows
      PnSlotR("RL",rr,g_PnTrXTime-g_PnRightX,"Time",clrPnDim);
      PnSlotR("RT_TYPE",rr,g_PnTrXType-g_PnRightX,"Type",clrPnDim);
      PnSlotR("RT_RES", rr,g_PnTrXRes -g_PnRightX,"Res",clrPnDim);
      PnSlotR("RT_PL",  rr,g_PnTrXPL  -g_PnRightX,PnPadLeft("P/L",g_PnTrWPL),clrPnDim);
      PnHideExisting("RS_"+IntegerToString(rr));
      PnHideExisting("RV_"+IntegerToString(rr));
      PnHideExisting("RD_"+IntegerToString(rr));
      rr++;

      if(g_PnTrCount<=0)
      {
         PnSlotR("RL",rr,g_PnRZ1,"No closed trades yet",clrPnDim);
         PnRightBlankRowExcept(rr,"RL");
         rr++;
      }
      else
      {
         for(int t=0;t<g_PnTrCount;t++)
         {
            bool win=(g_PnTrPL[t]>=0);
            PnSlotR("RL",     rr,g_PnTrXTime-g_PnRightX,
                    PnFit(g_PnTrTime[t],g_PnTrWTime),clrPnValue);
            PnSlotR("RT_TYPE",rr,g_PnTrXType-g_PnRightX,
                    PnFit(g_PnTrType[t],g_PnTrWType),clrPnValue);
            PnSlotR("RT_RES", rr,g_PnTrXRes -g_PnRightX,
                    (win?"WIN":"LOSS"),(win?clrPnGood:clrPnBad));
            PnSlotR("RT_PL",  rr,g_PnTrXPL  -g_PnRightX,
                    PnPadLeft(PnFit(StringFormat("%+.2f",g_PnTrPL[t]),g_PnTrWPL),g_PnTrWPL),
                    (win?clrPnGood:clrPnBad));
            PnHideExisting("RS_"+IntegerToString(rr));
            PnHideExisting("RV_"+IntegerToString(rr));
            PnHideExisting("RD_"+IntegerToString(rr));
            rr++;
         }
      }
   }
   PnRightBlankRow(rr++);

   // ---- RIGHT D. SYSTEM STATS (moved here to balance the two columns) ----
   //      Uses ONLY the existing g_Cnt_* / g_Sum* counters - no invented data.
   PnRightSection(rr++,"SYSTEM STATS");
   {
      PnRightKV(rr++,"Pivots H / L",
                StringFormat("%d / %d",g_Cnt_M1PivotHigh,g_Cnt_M1PivotLow),clrPnValue);
      PnRightKV(rr++,"Setups Created",StringFormat("%d",g_Cnt_SetupsCreated),clrPnValue);
      PnRightKV(rr++,"Active Now",StringFormat("%d",g_PanelActiveSetups),clrPnValue);
      PnRightKV(rr++,"Invalid / Exp",
                StringFormat("%d / %d",g_Cnt_SetupsInvalidated,g_Cnt_SetupsExpired),clrPnValue);
      PnRightKV(rr++,"Cap Skipped",StringFormat("%d",g_Cnt_SetupsSkippedCap),
                (g_Cnt_SetupsSkippedCap>0?clrPnWarn:clrPnValue));

      PnRightKV(rr++,"Triggers",StringFormat("%d",g_Cnt_Triggers),clrPnValue);
      PnRightKV(rr++,"Breakouts",StringFormat("%d",g_Cnt_Breakouts),clrPnValue);
      PnRightKV(rr++,"Quality P / W",
                StringFormat("%d / %d",g_Cnt_BOQualityPass,g_Cnt_BOQualityWeak),clrPnValue);

      PnRightKV(rr++,"Entries",StringFormat("%d",g_Cnt_EntryExecuted),
                (g_Cnt_EntryExecuted>0?clrPnGood:clrPnValue));
      PnRightKV(rr++,"Attempts",StringFormat("%d",g_Cnt_EntryAttempts),clrPnValue);
      PnRightKV(rr++,"Blocked",StringFormat("%d",g_Cnt_EntryBlocked),
                (g_Cnt_EntryBlocked>0?clrPnWarn:clrPnValue));
      PnRightKV(rr++,"Failed",StringFormat("%d",g_Cnt_EntryFailed),
                (g_Cnt_EntryFailed>0?clrPnBad:clrPnValue));

      int rejTotal=g_Cnt_RejectLot+g_Cnt_RejectStops+g_Cnt_RejectMargin+
                   g_Cnt_RejectFilling+g_Cnt_RejectBroker+g_Cnt_RejectOther;
      PnRightKV(rr++,"Rejected",StringFormat("%d",rejTotal),
                (rejTotal>0?clrPnBad:clrPnGood));
      if(rejTotal>0)
      {
         PnRightKV(rr++,"Rej L/S/M",
                   StringFormat("%d / %d / %d",g_Cnt_RejectLot,g_Cnt_RejectStops,g_Cnt_RejectMargin),
                   clrPnBad);
         PnRightKV(rr++,"Rej F/B/O",
                   StringFormat("%d / %d / %d",g_Cnt_RejectFilling,g_Cnt_RejectBroker,g_Cnt_RejectOther),
                   clrPnBad);
      }
      PnRightKV(rr++,"Long / Short",
                StringFormat("%d / %d",g_LongTrades,g_ShortTrades),clrPnValue);

      double avgHold=(g_Cnt_TargetCloses>0)?g_SumTargetHoldSec/g_Cnt_TargetCloses:0.0;
      double avgMae =(g_Cnt_TargetCloses>0)?g_SumMAE/g_Cnt_TargetCloses:0.0;
      PnRightKV(rr++,"Target Closes",StringFormat("%d",g_Cnt_TargetCloses),
                (g_Cnt_TargetCloses>0?clrPnGood:clrPnValue));
      PnRightKV(rr++,"Target Profit",StringFormat("%.2f USD",g_SumTargetProfit),
                (g_SumTargetProfit>0?clrPnGood:clrPnValue));
      PnRightKV(rr++,"Avg Hold",
                (g_Cnt_TargetCloses>0?StringFormat("%.0f sec",avgHold):"--"),clrPnValue);
      PnRightKV(rr++,"Avg MAE",
                (g_Cnt_TargetCloses>0?StringFormat("%.2f USD",avgMae):"--"),
                (avgMae>0?clrPnWarn:clrPnValue));
   }

   //=====================  FINAL SIZING OF THE CHROME  ==================
   //  The height is derived from the ACTUAL number of rendered rows, so
   //  the pane tightly frames the content - never a large empty rectangle.
   totalRows=MathMax(g_PnLeftUsed,g_PnRightUsed);
   int bodyH  =totalRows*g_PnRowH;
   int footerH=g_PnRowH+8;
   g_PnH=(g_PnBodyTop-g_PnY)+bodyH+6+footerH;
   if(PanelMinHeight>0 && g_PnH<PanelMinHeight) g_PnH=PanelMinHeight;
   g_PnFooterY=g_PnY+g_PnH-footerH;

   // Re-apply the real geometry to the persistent chrome objects (they
   // already exist - this only updates position/size, never recreates).
   PnRect("BG",     g_PnX,    g_PnY,          g_PnW,   g_PnH,
          clrPnBorder, clrPnBG, 0, false);        // opaque FOREGROUND pane
   PnRect("HdrLine",g_PnX+4,  g_PnY+headerH,  g_PnW-8, 1,
          clrPnBorder, clrPnBorder, 2, false);
   // divider runs from just under the header rule to just above the footer
   PnRect("Sep",    g_PnSepX, g_PnY+headerH+2, 1,
          MathMax(1,g_PnFooterY-(g_PnY+headerH+4)),
          clrPnSep,    clrPnSep,    2, false);
   PnRect("FtLine", g_PnX+4,  g_PnFooterY,    g_PnW-8, 1,
          clrPnBorder, clrPnBorder, 2, false);

   //============================  FOOTER  ===============================
   {
      datetime lt=TimeLocal(), st=TimeCurrent();
      string nextAction;
      // M1 setup-check progress = seconds elapsed inside the current M1 bar.
      datetime m1open=iTime(_Symbol,PERIOD_M1,0);
      int secIn=(m1open>0)?(int)((long)st-(long)m1open):0;
      if(secIn<0) secIn=0; if(secIn>59) secIn=59;
      nextAction=StringFormat("Next: M1 Setup Check (%d/60s)",secIn);

      bool connected=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
      string conn=connected?"CONNECTED":"NO CONNECTION";
      color  connClr=connected?clrPnGood:clrPnBad;

      // Sequential cursor: each segment is placed after the measured width
      // of the previous one, so footer fields can never collide whatever
      // the broker name length or font size.
      int fy=g_PnFooterY+6;
      string f1=TimeToString(lt,TIME_DATE|TIME_SECONDS);
      string f2="|  "+nextAction;
      string f3="|  Server: "+TimeToString(st,TIME_SECONDS);
      string f4="|  "+AccountInfoString(ACCOUNT_SERVER);
      string f5="|  "+conn;

      int fx=g_PnLeftX;
      // (each segment below is additionally clamped to g_PnRightEdge)
      PnLabel("Ft1",fx,fy,f1,clrPnValue,g_PnFont); fx+=PnTextW(StringLen(f1)+3);
      PnLabel("Ft2",fx,fy,f2,clrPnWarn, g_PnFont); fx+=PnTextW(StringLen(f2)+3);
      PnLabel("Ft3",fx,fy,f3,clrPnValue,g_PnFont); fx+=PnTextW(StringLen(f3)+3);
      PnLabel("Ft4",fx,fy,f4,clrPnLabel,g_PnFont); fx+=PnTextW(StringLen(f4)+3);
      // Last segment is clamped so it always stays inside the pane.
      int f5x=MathMin(fx,g_PnRightEdge-PnTextW(StringLen(f5)));
      PnLabel("Ft5",f5x,fy,f5,connClr,g_PnFont);
   }

   PnHideSurplus();
   // NOTE: no DrawHTFVisuals()/DrawAllSetupVisuals()/ChartRedraw() here.
   // Chart annotations are event-driven (UpdateChartVisualsIfDirty) and the
   // single redraw is issued by PanelTick().
}
//+------------------------------------------------------------------+
