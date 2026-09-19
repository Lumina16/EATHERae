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
      DrawSRZones();
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

   DrawSRZones();
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

   LogM1(StringFormat("New %s setup #%d seeded at A=%.2f @ %s",
         BiasToStr(dir),(int)s.id,aPrice,TimeToString(aTime,TIME_MINUTES)));

   DrawSetupAnchor((int)s.id,"A",aPrice,aTime,clrDodgerBlue,159);
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
            DrawSetupAnchor((int)s.id,"B",s.B,s.Bt,clrLime,159);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
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
            DrawSetupAnchor((int)s.id,"B",s.B,s.Bt,clrLime,159);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
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
            DrawSetupTrigger((int)s.id,s.trigger,s.triggerTime,clrAqua);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
               DeleteSetupTrigger((int)s.id);
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
            DrawSetupAnchor((int)s.id,"B",s.B,s.Bt,clrTomato,159);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
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
            DrawSetupAnchor((int)s.id,"B",s.B,s.Bt,clrTomato,159);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
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
            DrawSetupTrigger((int)s.id,s.trigger,s.triggerTime,clrMagenta);
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
               DrawSetupAnchor((int)s.id,"C",s.C,s.Ct,clrOrange,159);
               DeleteSetupTrigger((int)s.id);
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

   if(DebugMode)
      RefreshPanel();
   else
      ClearPanelObjects();
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

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,time,price);
   else
      ObjectMove(0,label,0,time,price);
   ObjectSetString(0,label,OBJPROP_TEXT," "+tag);
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,fontSize);
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

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,time,price);
   else
      ObjectMove(0,label,0,time,price);
   ObjectSetString(0,label,OBJPROP_TEXT,StringFormat(" #%d %s",id,tag));
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,8);
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

   string label=name+"_txt";
   if(ObjectFind(0,label)<0)
      ObjectCreate(0,label,OBJ_TEXT,0,fromTime,price);
   else
      ObjectMove(0,label,0,fromTime,price);
   ObjectSetString(0,label,OBJPROP_TEXT,StringFormat(" #%d TRIGGER",id));
   ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,8);
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

   string label=name+"_txt";
   if(ObjectCreate(0,label,OBJ_TEXT,0,time,price))
   {
      ObjectSetString(0,label,OBJPROP_TEXT,StringFormat("%s #%d",(ot==ORDER_TYPE_BUY?" BUY":" SELL"),setupId));
      ObjectSetInteger(0,label,OBJPROP_COLOR,clr);
      ObjectSetInteger(0,label,OBJPROP_FONTSIZE,9);
   }

   AddEntryMarkerToQueue(name);
}

//=========================================================================
//              COMPACT RECTANGLE DIAGNOSTIC PANEL (V13 layout)
//  Same single expanded panel as V13.3: original left column + the M30
//  S/R column on the right, separated by one thin vertical line. No new
//  headings. When the S/R module is OFF the right column simply reports
//  OFF and never shows blocking text.
//=========================================================================
#define PANEL_X       10
#define PANEL_Y       20
#define PANEL_LEFT_W  330
#define PANEL_GAP     18
#define PANEL_RIGHT_W 210
#define PANEL_WIDTH   (PANEL_LEFT_W+PANEL_GAP+PANEL_RIGHT_W)
#define PANEL_ROWH    14

color clrPanelBG     = C'18,18,18';
color clrPanelBorder = C'80,80,80';
color clrTitle       = clrGold;
color clrNormal      = clrSilver;
color clrGood        = clrLimeGreen;
color clrBad         = clrOrangeRed;
color clrWarn        = clrOrange;
color clrBuyC        = clrLimeGreen;
color clrSellC       = clrTomato;
color clrDim         = clrGray;

string g_PanelLines[64];
color  g_PanelColors[64];
int    g_PanelLineCount=0;
int    g_PanelRowPrevCount=0;

string g_PanelRightLines[16];
color  g_PanelRightColors[16];
int    g_PanelRightLineCount=0;
int    g_PanelRightRowPrevCount=0;

void PanelAdd(string text,color clr)
{
   if(g_PanelLineCount>=64) return;
   g_PanelLines[g_PanelLineCount]=text;
   g_PanelColors[g_PanelLineCount]=clr;
   g_PanelLineCount++;
}

void PanelRightAdd(string text,color clr)
{
   if(g_PanelRightLineCount>=16) return;
   g_PanelRightLines[g_PanelRightLineCount]=text;
   g_PanelRightColors[g_PanelRightLineCount]=clr;
   g_PanelRightLineCount++;
}

void EnsurePanelBackground(int height)
{
   string name="V13_PanelBG";
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrPanelBorder);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,clrPanelBG);
   }
   ObjectSetInteger(0,name,OBJPROP_ZORDER,0);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PANEL_X-6);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PANEL_Y-6);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,PANEL_WIDTH);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height);
}

void EnsureSeparator(int height)
{
   string name="V13_PanelSep";
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_BACK,false);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrPanelBorder);
      ObjectSetInteger(0,name,OBJPROP_BGCOLOR,clrPanelBorder);
   }
   ObjectSetInteger(0,name,OBJPROP_ZORDER,4);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PANEL_X+PANEL_LEFT_W+PANEL_GAP/2);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PANEL_Y-2);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,1);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,height-4);
}

void EnsureTitle()
{
   string name="V13_PanelTitle";
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,name,OBJPROP_ZORDER,5);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PANEL_X);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PANEL_Y);
   ObjectSetString(0,name,OBJPROP_TEXT,"XAUUSD SCALPER  |  V13 MULTI-SETUP");
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrTitle);
}

void PanelRow(int index,int y,string text,color clr)
{
   string name="V13_PanelRow"+IntegerToString(index);
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,name,OBJPROP_ZORDER,5);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PANEL_X);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}

void PanelRowRight(int index,int y,string text,color clr)
{
   string name="V13_PanelRowR"+IntegerToString(index);
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,name,OBJPROP_ZORDER,5);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,PANEL_X+PANEL_LEFT_W+PANEL_GAP);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
}

void ClearPanelObjects()
{
   ObjectDelete(0,"V13_PanelBG");
   ObjectDelete(0,"V13_PanelTitle");
   ObjectDelete(0,"V13_PanelSep");
   for(int i=0;i<g_PanelRowPrevCount;i++)
      ObjectDelete(0,"V13_PanelRow"+IntegerToString(i));
   for(int i=0;i<g_PanelRightRowPrevCount;i++)
      ObjectDelete(0,"V13_PanelRowR"+IntegerToString(i));
   g_PanelRowPrevCount=0;
   g_PanelRightRowPrevCount=0;
}

void DetermineStatus(string &status,color &clr)
{
   if(g_HaltedDaily)     { status="BLOCKED (daily loss halt)";     clr=clrBad;  return; }
   if(g_HaltedConsec)    { status="BLOCKED (loss streak halt)";    clr=clrBad;  return; }
   if(g_HaltedFloat)     { status="BLOCKED (floating loss halt)";  clr=clrBad;  return; }

   // Only when the module is actually active AND the real entry filter
   // would block a ready setup right now.
   if(g_SRActive)
   {
      string srBlockReason;
      if(SRIsBlockingReadySetup(srBlockReason))
      { status="TRADE BLOCKED - "+srBlockReason; clr=clrBad; return; }
   }

   int open=CountPositions();
   if(open>0)            { status=StringFormat("ACTIVE (managing %d/%d trades)",open,g_MaxOpenTrades);
                           clr=clrGood; return; }
   if(!UseM1)            { status="M1 DISABLED (no new setups; managing only)"; clr=clrWarn; return; }

   ENUM_ALIGN_RESULT aligned=AlignedBias();
   if(aligned!=ALIGN_CONFLICT)
                         { status="ACTIVE (scanning "+AlignResultToStr(aligned)+")"; clr=clrGood; return; }
   status="NO NEW SETUPS (HTF conflict)"; clr=clrWarn;
}

int LatestSetupIndex()
{
   int best=-1; datetime bestT=0;
   for(int i=0;i<ArraySize(g_Setups);i++)
      if(g_Setups[i].active && (best<0 || g_Setups[i].createdTime>bestT))
      { best=i; bestT=g_Setups[i].createdTime; }
   return best;
}

void RefreshPanel()
{
   if(!DebugMode) { ClearPanelObjects(); return; }

   g_PanelLineCount=0;

   string status; color statusClr; DetermineStatus(status,statusClr);
   PanelAdd("STATUS: "+status,statusClr);

   ENUM_ALIGN_RESULT aligned=AlignedBias();
   color alClr=(aligned==ALIGN_BULLISH)?clrBuyC:
               (aligned==ALIGN_BEARISH)?clrSellC:
               (aligned==ALIGN_NOFILTER)?clrNormal:clrDim;
   PanelAdd("ALIGN:  "+AlignResultToStr(aligned),alClr);

   color h1C =(!UseH1) ?clrDim:((g_H1.bias==BIAS_BULLISH)?clrBuyC:(g_H1.bias==BIAS_BEARISH?clrSellC:clrDim));
   color m15C=(!UseM15)?clrDim:((g_M15.bias==BIAS_BULLISH)?clrBuyC:(g_M15.bias==BIAS_BEARISH?clrSellC:clrDim));
   color m5C =(!UseM5) ?clrDim:((g_M5.bias==BIAS_BULLISH)?clrBuyC:(g_M5.bias==BIAS_BEARISH?clrSellC:clrDim));

   PanelAdd(StringFormat("H1:   %-3s  %-4s %s%s%s%s",UseH1?"ON":"OFF",UseH1?BiasToStr(g_H1.bias):"-",
             (UseH1&&g_H1.HH)?"HH ":"",(UseH1&&g_H1.HL)?"HL ":"",(UseH1&&g_H1.LH)?"LH ":"",(UseH1&&g_H1.LL)?"LL":""),h1C);
   PanelAdd(StringFormat("M15:  %-3s  %-4s %s%s%s%s",UseM15?"ON":"OFF",UseM15?BiasToStr(g_M15.bias):"-",
             (UseM15&&g_M15.HH)?"HH ":"",(UseM15&&g_M15.HL)?"HL ":"",(UseM15&&g_M15.LH)?"LH ":"",(UseM15&&g_M15.LL)?"LL":""),m15C);
   PanelAdd(StringFormat("M5:   %-3s  %-4s %s%s%s%s",UseM5?"ON":"OFF",UseM5?BiasToStr(g_M5.bias):"-",
             (UseM5&&g_M5.HH)?"HH ":"",(UseM5&&g_M5.HL)?"HL ":"",(UseM5&&g_M5.LH)?"LH ":"",(UseM5&&g_M5.LL)?"LL":""),m5C);
   PanelAdd(StringFormat("M1:   %-3s  %s",UseM1?"ON":"OFF",UseM1?"(setup engine active)":"(setups disabled)"),
            UseM1?clrGood:clrDim);

   PanelAdd("--------------------------------------",clrPanelBorder);

   PanelAdd(StringFormat("M1 SETUPS:  Active %d  Ready %d",CountActiveSetups(),CountReadySetups()),clrNormal);

   int li=LatestSetupIndex();
   if(li>=0)
   {
      M1Setup s=g_Setups[li];
      color sClr=(s.direction==BIAS_BULLISH)?clrBuyC:clrSellC;
      PanelAdd(StringFormat("LATEST SETUP #%d  %s",(int)s.id,BiasToStr(s.direction)),sClr);
      PanelAdd(StringFormat("A:%s  B:%s  C:%s  TRIG:%s   (%s)",
                  (s.At>0?"OK":"-"),(s.Bt>0?"OK":"-"),(s.Ct>0?"OK":"-"),
                  (s.triggerTime>0?"OK":"-"),SetupStateToStr(s.state)),clrNormal);
      if(s.state==MS_WAIT_BREAK)
      {
         string bo=(s.entryStatus==""||s.entryStatus=="WAITING")?"WAITING":s.entryStatus;
         PanelAdd("BREAKOUT: "+bo+"   QUALITY: "+s.breakoutQuality,clrWarn);
         if(s.entryStatus=="BLOCKED" && s.blockReason!="")
            PanelAdd("Reason: "+Trunc(s.blockReason,36),clrBad);
      }
   }
   else
      PanelAdd("LATEST SETUP: none",clrDim);

   PanelAdd("--------------------------------------",clrPanelBorder);

   PanelAdd(StringFormat("OPEN: %d / %d     FLOAT: %+.2f",CountPositions(),g_MaxOpenTrades,g_TotalFloat),
            (g_TotalFloat>=0?clrGood:clrBad));
   PanelAdd(StringFormat("TARGET: +$%.2f/pos   MAXFLOAT: -$%.2f",g_ProfitTargetUSD,g_MaxFloatingLossUSD),clrNormal);
   PanelAdd(StringFormat("TODAY: %+.2f      TOTAL: %+.2f",g_DayPL,g_TotalRealizedPL),
            ((g_DayPL+g_TotalRealizedPL)>=0?clrGood:clrBad));

   double winRate=(g_Wins+g_Losses>0)?(100.0*g_Wins/(g_Wins+g_Losses)):0.0;
   PanelAdd(StringFormat("W/L: %d/%d  WR %.0f%%  StreakL:%d  @$target:%d",
            g_Wins,g_Losses,winRate,g_ConsLoss,g_Cnt_TargetCloses),clrNormal);

   PanelAdd(StringFormat("SPREAD: %d pts   ATR(M1): %.2f   SES:%s VOL:%s",
            (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD),AtrVal(g_ATR_M1,1),
            (InSession()?"OK":"OFF"),(VolOK()?"OK":"SPIKE")),clrNormal);

   PanelAdd("--------------------------------------",clrPanelBorder);

   int shown=0;
   for(int i=PositionsTotal()-1;i>=0 && shown<4;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      long sid=ParseSetupIdFromComment(PositionGetString(POSITION_COMMENT));
      string d=(pt==POSITION_TYPE_BUY)?"BUY":"SELL";
      color dClr=(pt==POSITION_TYPE_BUY)?clrBuyC:clrSellC;
      PanelAdd(StringFormat("TRADE #%d  %s  P/L %+.2f / +$%.2f",(int)sid,d,profit,g_ProfitTargetUSD),
               (profit>=0?dClr:clrBad));
      shown++;
   }
   if(shown==0) PanelAdd("TRADE: NONE",clrDim);

   PanelAdd("--------------------------------------",clrPanelBorder);
   PanelAdd("LAST: "+Trunc(g_LastAction,44),clrWarn);

   // ---- RIGHT column: M30 S/R info (OFF-safe) ----
   g_PanelRightLineCount=0;

   if(!g_SRActive)
   {
      PanelRightAdd("M30: OFF",clrDim);
      PanelRightAdd("Nearest R: -",clrDim);
      PanelRightAdd("Nearest S: -",clrDim);
      PanelRightAdd("Zones: -",clrDim);
      PanelRightAdd("Updated: -",clrDim);
      PanelRightAdd("--------------------",clrPanelBorder);
      PanelRightAdd("M1 Filter: OFF",clrDim);
   }
   else
   {
      color srStateClr=clrNormal;
      switch(g_SRState)
      {
         case SR_NEAR_RESISTANCE:
         case SR_BREAKING_RESISTANCE: srStateClr=clrSellC; break;
         case SR_NEAR_SUPPORT:
         case SR_BREAKING_SUPPORT:    srStateClr=clrBuyC;  break;
         case SR_NO_VALID:
         case SR_DISABLED:            srStateClr=clrDim;   break;
         default:                     srStateClr=clrNormal;
      }

      PanelRightAdd("M30: "+SRStateToStr(g_SRState),srStateClr);
      PanelRightAdd("Nearest R: "+(g_SRNearestResistance>0?DoubleToString(g_SRNearestResistance,2):"-"),clrNormal);
      PanelRightAdd("Nearest S: "+(g_SRNearestSupport>0?DoubleToString(g_SRNearestSupport,2):"-"),clrNormal);
      PanelRightAdd(StringFormat("Zones: %d/%d",g_SRZoneCount,SR_MAX_ZONES),clrNormal);
      PanelRightAdd("Updated: "+(g_SRLastUpdate>0?TimeToString(g_SRLastUpdate,TIME_MINUTES):"-"),clrDim);
      PanelRightAdd("--------------------",clrPanelBorder);

      string srBlockReason2;
      if(SRIsBlockingReadySetup(srBlockReason2))
         PanelRightAdd("M1 Filter: Blocked - "+Trunc(srBlockReason2,18),clrBad);
      else
         PanelRightAdd("M1 Filter: OK",clrGood);
   }

   int totalHeight=20+(MathMax(g_PanelLineCount,g_PanelRightLineCount)*PANEL_ROWH)+10;
   if(totalHeight<180) totalHeight=180;
   EnsurePanelBackground(totalHeight);
   EnsureSeparator(totalHeight);

   EnsureTitle();
   int y=PANEL_Y+20;
   for(int i=0;i<g_PanelLineCount;i++)
   {
      PanelRow(i,y,g_PanelLines[i],g_PanelColors[i]);
      y+=PANEL_ROWH;
   }
   for(int i=g_PanelLineCount;i<g_PanelRowPrevCount;i++)
      ObjectDelete(0,"V13_PanelRow"+IntegerToString(i));
   g_PanelRowPrevCount=g_PanelLineCount;

   int yr=PANEL_Y+20;
   for(int i=0;i<g_PanelRightLineCount;i++)
   {
      PanelRowRight(i,yr,g_PanelRightLines[i],g_PanelRightColors[i]);
      yr+=PANEL_ROWH;
   }
   for(int i=g_PanelRightLineCount;i<g_PanelRightRowPrevCount;i++)
      ObjectDelete(0,"V13_PanelRowR"+IntegerToString(i));
   g_PanelRightRowPrevCount=g_PanelRightLineCount;

   DrawHTFVisuals();
   DrawAllSetupVisuals();
}
//+------------------------------------------------------------------+
