//+------------------------------------------------------------------+
//|        XAUUSD_M5_M1_Scalper.mq5  (V14 - SIMPLE SCALPER)         |
//|  M5 = direction / regime  (causal price-action structure)        |
//|  M1 = pullback + reclaim / micro breakout                        |
//|  ATR = movement / risk (pullback size, SL buffer, BE, trail)     |
//|  NO fixed USD target - managed by structural SL -> BE -> trail   |
//|  NO hedging / grid / martingale / averaging / pyramiding         |
//|  Built from V13.31 - simplified per V14 spec                     |
//+------------------------------------------------------------------+
#property copyright "Research EA - use at your own risk"
#property version   "14.00"
#property strict
//=========================================================================
//                                INPUTS
//=========================================================================
input group "M5 REGIME (PRICE ACTION STRUCTURE)"
input int    PivotSize           = 2;
input int    ATRPeriod           = 14;
input double StructureExpansion  = 0.0;
input int    HTFWarmupBars       = 200;

input group "M1 SCALP ENTRY"
input double M1PullbackATR       = 0.40;
input int    PullbackLookbackBars= 10;
input int    ReclaimLookbackBars = 2;
input int    ScalpSetupExpiryMin = 15;

input group "SCALP RISK / EXIT"
input double InitialSLBufferATR  = 0.15;
input double BreakEvenTriggerATR = 0.60;
input double BreakEvenOffsetATR  = 0.00;
input double TrailStartATR       = 0.80;
input double TrailDistanceATR    = 1.00;
input double TrailStepATR        = 0.10;

input group "MONEY & TRADING"
input double LotSize             = 0.01;
input int    MaxOpenTrades       = 5;

input group "SAFETY"
input double MaxFloatingLossUSD       = 10.0;
input bool   CloseAllOnEmergencyLoss = true;
input double DailyLossLimitPercent   = 1.5;
input int    ConsecutiveLossLimit    = 3;
input int    MaxSpreadPoints         = 350;

input group "TRADING HOURS"
input int    TradingStartHour = 7;
input int    TradingEndHour   = 20;

input group "VOLATILITY"
input int    VolatilityLookback   = 50;
input double VolatilitySpikeLimit = 1.50;

input group "SYSTEM"
input long   MagicNumber       = 20260915;
input int    MaxSlippagePoints = 30;
input int    M1WarmupBars      = 300;

input group "PANEL (DISPLAY ONLY)"
input int    PanelX                 = 10;
input int    PanelY                 = 18;
input int    PanelWidth             = 1000;
input int    PanelMinHeight         = 0;
input int    PanelRowHeight         = 15;
input int    PanelFontSize          = 8;
input int    PanelRefreshMs         = 300;
input int    PanelHistoryRefreshSec = 60;

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
enum ENUM_SCALP_STATE { SCALP_WAIT_PULLBACK, SCALP_WAIT_RECLAIM };
enum ENUM_REJECT_CAT { REJ_NONE, REJ_LOT, REJ_STOPS, REJ_MARGIN, REJ_FILLING, REJ_BROKER, REJ_OTHER };

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
struct ScalpSetup
{
   bool              active;
   long              id;
   ENUM_BIAS         direction;
   ENUM_SCALP_STATE  state;
   double            recentHigh;      // for BUY : highest high in lookback
   double            recentLow;       // for SELL: lowest low
   double            pullbackLow;     // BUY invalidation low
   double            pullbackHigh;    // SELL invalidation high
   double            pullbackDistance;
   double            requiredPullback;
   double            reclaimLevel;
   datetime          createdTime;
   datetime          pullbackTime;
   datetime          reclaimUpdateTime;
   bool              crossActive;     // armed ?
   string            statusText;
};
struct PosTrack
{
   bool     used;
   ulong    posId;
   long     setupId;
   double   entryPrice;
   double   entryATR;
   double   initialSL;
   bool     breakEvenApplied;
   bool     trailActive;
   double   lastSL;
   double   minFloat;
   datetime openTime;
};

//=========================================================================
//                            GLOBAL STATE
//=========================================================================
int g_ATR_H1=INVALID_HANDLE, g_ATR_M15=INVALID_HANDLE, g_ATR_M5=INVALID_HANDLE, g_ATR_M1=INVALID_HANDLE;
datetime g_LastH1Bar=0, g_LastM15Bar=0, g_LastM5Bar=0, g_LastM1Bar=0;
TFStruct g_H1;
TFStruct g_M15;
TFStruct g_M5;

// ---- Effective (validated) parameters ----
int    g_PivotSize=2;
int    g_ATRPeriod=14;
double g_StructureExpansion=0.0;
double g_M1PullbackATR=0.40;
int    g_PullbackLookbackBars=10;
int    g_ReclaimLookbackBars=2;
int    g_ScalpSetupExpiryMin=15;
double g_InitialSLBufferATR=0.15;
double g_BreakEvenTriggerATR=0.60;
double g_BreakEvenOffsetATR=0.00;
double g_TrailStartATR=0.80;
double g_TrailDistanceATR=1.00;
double g_TrailStepATR=0.10;
int    g_VolatilityLookback=50;
double g_VolatilitySpikeLimit=1.5;
int    g_MaxOpenTrades=5;
int    g_MaxSpreadPoints=350;
int    g_HTFWarmupBars=200;
int    g_M1WarmupBars=300;
int    g_MaxSlippagePoints=30;
double g_LotSize=0.01;
double g_MaxFloatingLossUSD=10.0;
double g_DailyLossLimitPercent=1.5;
int    g_ConsecutiveLossLimit=3;
int    g_TradingStartHour=0;
int    g_TradingEndHour=0;
bool   g_InitComplete=false;

// ---- Scalp single setup ----
ScalpSetup g_Scalp;
long       g_NextSetupId=0;

// ---- Per-position tracking ----
PosTrack g_Tracks[];

// ---- Daily risk ----
int    g_Day=-1;
double g_DayBal=0, g_DayPL=0;
int    g_ConsLoss=0;
bool   g_HaltedDaily=false;
bool   g_HaltedConsec=false;
bool   g_HaltedFloat=false;

// ---- Live caches ----
double g_TotalFloat=0;

// ---- Performance ----
int    g_TotalTrades=0, g_Wins=0, g_Losses=0;
double g_SumWinProfit=0, g_SumLossProfit=0;
double g_TotalRealizedPL=0;
double g_LargestWin=0, g_LargestLoss=0;
int    g_LongTrades=0, g_ShortTrades=0;
int    g_MaxConsecLossPeak=0;
double g_PeakEquity=0, g_MaxDrawdownPct=0;

// ---- Scalp counters ----
int g_Cnt_PullbackDetected=0;
int g_Cnt_ReclaimArmed=0;
int g_Cnt_Breakouts=0;
int g_Cnt_EntryAttempts=0, g_Cnt_EntryExecuted=0, g_Cnt_EntryBlocked=0, g_Cnt_EntryFailed=0;
int g_Cnt_SetupsExpired=0;
int g_Cnt_SetupsInvalidatedM5=0;
int g_Cnt_BreakEven=0;
int g_Cnt_TrailingMods=0;
// rejection breakdown
int g_Cnt_RejectLot=0, g_Cnt_RejectStops=0, g_Cnt_RejectMargin=0;
int g_Cnt_RejectFilling=0, g_Cnt_RejectBroker=0, g_Cnt_RejectOther=0;

//=========================================================================
//  DASHBOARD PANEL SHARED STATE  (DISPLAY ONLY)
//=========================================================================
bool   g_PnHistoryDirty=true;
double g_PnDayPeakEquity=0;
double g_PnDayDDPct=0;
bool   g_PanelVisible=false;
uint   g_PanelLastDrawMs=0;
bool   g_PanelDirty=true;
bool   g_TimerActive=false;
bool   g_HTFVisualDirty=true;
bool   g_SetupVisualDirty=true;
int    g_PanelOpenTradeCount=0;
int    g_PanelBuyCount=0;
int    g_PanelSellCount=0;
double g_PanelOpenVolume=0;
double g_PanelAvgBuy=0, g_PanelAvgSell=0;
double g_PanelFloatPL=0;
bool              g_PanelEntryPermission=false;
string            g_PanelBlockReason="";
ENUM_BIAS         g_PanelM5Bias=BIAS_NEUTRAL;
ENUM_SCALP_STATE  g_PanelScalpState=SCALP_WAIT_PULLBACK;
double            g_PanelPullbackDist=0;
double            g_PanelRequiredPullback=0;
double            g_PanelReclaimLevel=0;
int               g_PanelSetupAgeSec=0;
bool              g_PanelScalpActive=false;
string            g_PanelScalpStatus="";
bool              g_PanelSpreadOK=true;
bool              g_PanelVolOK=true;
bool              g_PanelInSession=true;
string g_LastAction = "Initialized - scanning";
string g_EntryMarkerQueue[];

//=========================================================================
//                       FORWARD DECLARATIONS
//=========================================================================
void   OnM5BiasChanged();
void   InvalidateScalp(string reason);
void   DrawScalpVisuals();
void   DeleteScalpVisuals();
void   DrawEntryMarker(ENUM_ORDER_TYPE ot,double price,datetime time,int setupId);
bool   CheckEntryPermissions(ENUM_BIAS dir,string &reason);
bool   ExecuteScalpTrade(double reclaimLevel,double pullbackInvalidation);
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
bool   ModifyPositionSL(ulong ticket,double newSL);

//=========================================================================
//                     SMALL HELPERS
//=========================================================================
string BiasToStr(ENUM_BIAS b)
{
   if(b==BIAS_BULLISH) return "BUY";
   if(b==BIAS_BEARISH) return "SELL";
   return "NEUTRAL";
}
string ScalpStateToStr(ENUM_SCALP_STATE s)
{
   return (s==SCALP_WAIT_PULLBACK)?"WAIT_PULLBACK":"WAIT_RECLAIM";
}
string TFVoteStr(bool enabled,ENUM_BIAS bias)
{
   return enabled ? BiasToStr(bias) : "OFF";
}
void SetLastAction(string s) { g_LastAction = s; }
void LogHTF(string msg)   { if(DebugHTF)   Print("[HTF] ",msg); }
void LogM1(string msg)    { if(DebugM1)    Print("[M1] ",msg); }
void LogTrade(string msg) { if(DebugTrade) Print(msg); }
void LogScalp(string msg) { if(DebugM1) Print("[SCALP] ",msg); }

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
bool HasOpenPositionInDirection(ENUM_BIAS dir)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(dir==BIAS_BULLISH && pt==POSITION_TYPE_BUY) return true;
      if(dir==BIAS_BEARISH && pt==POSITION_TYPE_SELL) return true;
   }
   return false;
}
bool HasAnyOpenPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionIsMine()) return true;
   }
   return false;
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
int TrackIndexFor(ulong posId,datetime openTime,long setupId,double entryPrice,double entryATR,double initialSL)
{
   int idx=FindTrack(posId);
   if(idx<0)
   {
      idx=ArraySize(g_Tracks);
      if(ArrayResize(g_Tracks,idx+1)<=idx) return -1;
      g_Tracks[idx].used=true;
      g_Tracks[idx].posId=posId;
      g_Tracks[idx].setupId=setupId;
      g_Tracks[idx].entryPrice=entryPrice;
      g_Tracks[idx].entryATR=entryATR;
      g_Tracks[idx].initialSL=initialSL;
      g_Tracks[idx].breakEvenApplied=false;
      g_Tracks[idx].trailActive=false;
      g_Tracks[idx].lastSL=initialSL;
      g_Tracks[idx].minFloat=0;
      g_Tracks[idx].openTime=openTime;
      // if SL already moved beyond initial, mark BE as done
      double curSL=0;
      if(PositionSelectByTicket(posId)) curSL=PositionGetDouble(POSITION_SL);
      if(curSL>0)
      {
         g_Tracks[idx].lastSL=curSL;
         // if position is BUY and SL >= entry => BE already
         ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(pt==POSITION_TYPE_BUY && curSL>=entryPrice) g_Tracks[idx].breakEvenApplied=true;
         if(pt==POSITION_TYPE_SELL && curSL<=entryPrice && curSL>0) g_Tracks[idx].breakEvenApplied=true;
         if(curSL!=initialSL) g_Tracks[idx].trailActive=true;
      }
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
   g_PnDayPeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_PnDayDDPct=0;
   g_PnHistoryDirty=true;
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
   if(eq>g_PnDayPeakEquity || g_PnDayPeakEquity<=0) g_PnDayPeakEquity=eq;
   if(g_PnDayPeakEquity>0)
   {
      double ddd=(g_PnDayPeakEquity-eq)/g_PnDayPeakEquity*100.0;
      if(ddd>g_PnDayDDPct) g_PnDayDDPct=ddd;
   }
}

//=========================================================================
//     GENERIC CAUSAL STRUCTURE ENGINE (H1, M15, M5)
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
   if(idx+g_PivotSize>=need || idx-g_PivotSize<0) return;
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
   if(!newHighPivot && !newLowPivot) return;
   if(live) g_HTFVisualDirty=true;
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
            Print(StringFormat("[%s] BIAS -> BULLISH (SH=%.2f PSH=%.2f SL=%.2f PSL=%.2f)", EnumToString(tf),st.SH,st.PSH,st.SL,st.PSL));
            if(tf==PERIOD_M5) OnM5BiasChanged();
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
            Print(StringFormat("[%s] BIAS -> BEARISH (SH=%.2f PSH=%.2f SL=%.2f PSL=%.2f)", EnumToString(tf),st.SH,st.PSH,st.SL,st.PSL));
            if(tf==PERIOD_M5) OnM5BiasChanged();
         }
      }
      else st.reason="Bearish shape present, expansion insufficient - holding prior bias";
   }
   else if(candidate==BIAS_NEUTRAL)
   {
      if(st.bias==BIAS_BULLISH)
         st.reason = (st.LH||st.LL) ? "Bullish regime weakening (contrary pivot) - holding BUY" : "Bullish regime intact";
      else if(st.bias==BIAS_BEARISH)
         st.reason = (st.HH||st.HL) ? "Bearish regime weakening (contrary pivot) - holding SELL" : "Bearish regime intact";
      else
         st.reason = "Insufficient structure";
   }
   else
      st.reason = (st.bias==BIAS_BULLISH) ? "Bullish regime persists (HH+HL maintained)" : "Bearish regime persists (LH+LL maintained)";
   if(live && oldBias!=st.bias)
      SetLastAction(EnumToString(tf)+string(" bias -> ")+BiasToStr(st.bias));
}

void OnM5BiasChanged()
{
   Print(StringFormat("[M5] Regime -> %s  H1=%s M15=%s", BiasToStr(g_M5.bias), BiasToStr(g_H1.bias), BiasToStr(g_M15.bias)));
   if(g_M5.bias==BIAS_NEUTRAL) return;
   if(!g_Scalp.active) return;
   if(g_Scalp.direction!=g_M5.bias)
   {
      LogScalp(StringFormat("M5 flipped to %s - invalidating %s scalp #%d", BiasToStr(g_M5.bias), BiasToStr(g_Scalp.direction), (int)g_Scalp.id));
      InvalidateScalp("M5 direction changed to "+BiasToStr(g_M5.bias));
      g_Cnt_SetupsInvalidatedM5++;
   }
}

//=========================================================================
//                    SCALP SETUP MANAGEMENT
//=========================================================================
void ResetScalp()
{
   DeleteScalpVisuals();
   g_Scalp.active=false;
   g_Scalp.id=0;
   g_Scalp.direction=BIAS_NEUTRAL;
   g_Scalp.state=SCALP_WAIT_PULLBACK;
   g_Scalp.recentHigh=0; g_Scalp.recentLow=0;
   g_Scalp.pullbackLow=0; g_Scalp.pullbackHigh=0;
   g_Scalp.pullbackDistance=0; g_Scalp.requiredPullback=0;
   g_Scalp.reclaimLevel=0;
   g_Scalp.createdTime=0; g_Scalp.pullbackTime=0; g_Scalp.reclaimUpdateTime=0;
   g_Scalp.crossActive=false;
   g_Scalp.statusText="";
   g_SetupVisualDirty=true; g_PanelDirty=true;
}
void InvalidateScalp(string reason)
{
   if(!g_Scalp.active) return;
   LogScalp(StringFormat("Scalp #%d INVALIDATED: %s", (int)g_Scalp.id, reason));
   SetLastAction(BiasToStr(g_Scalp.direction)+" #"+IntegerToString((int)g_Scalp.id)+" invalidated: "+reason);
   ResetScalp();
}

// Bounded helpers using COMPLETED bars only (shift>=1)
double HighestHighM1(int lookback, int &outIdx)
{
   outIdx=-1;
   if(lookback<1) return 0;
   double hi[]; ArraySetAsSeries(hi,true);
   int got=CopyHigh(_Symbol,PERIOD_M1,1,lookback,hi);
   if(got<lookback) lookback=got;
   if(lookback<1) return 0;
   double mx=hi[0]; int idx=0;
   for(int i=1;i<lookback;i++) if(hi[i]>mx) { mx=hi[i]; idx=i; }
   outIdx=idx;
   return mx;
}
double LowestLowM1(int lookback, int &outIdx)
{
   outIdx=-1;
   if(lookback<1) return 0;
   double lo[]; ArraySetAsSeries(lo,true);
   int got=CopyLow(_Symbol,PERIOD_M1,1,lookback,lo);
   if(got<lookback) lookback=got;
   if(lookback<1) return 0;
   double mn=lo[0]; int idx=0;
   for(int i=1;i<lookback;i++) if(lo[i]<mn) { mn=lo[i]; idx=i; }
   outIdx=idx;
   return mn;
}
double LowestLowRangeM1(int fromShift,int count)
{
   if(count<1 || fromShift<1) return 0;
   double lo[]; ArraySetAsSeries(lo,true);
   int got=CopyLow(_Symbol,PERIOD_M1,fromShift,count,lo);
   if(got<1) return 0;
   double mn=lo[0];
   for(int i=1;i<got;i++) if(lo[i]<mn) mn=lo[i];
   return mn;
}
double HighestHighRangeM1(int fromShift,int count)
{
   if(count<1 || fromShift<1) return 0;
   double hi[]; ArraySetAsSeries(hi,true);
   int got=CopyHigh(_Symbol,PERIOD_M1,fromShift,count,hi);
   if(got<1) return 0;
   double mx=hi[0];
   for(int i=1;i<got;i++) if(hi[i]>mx) mx=hi[i];
   return mx;
}

// Reclaim level from completed bars only
double CalcReclaimLevel(ENUM_BIAS dir)
{
   if(g_ReclaimLookbackBars<1) return 0;
   if(dir==BIAS_BULLISH)
   {
      double hi[]; ArraySetAsSeries(hi,true);
      int got=CopyHigh(_Symbol,PERIOD_M1,1,g_ReclaimLookbackBars,hi);
      if(got<1) return 0;
      double mx=hi[0];
      for(int i=1;i<got;i++) if(hi[i]>mx) mx=hi[i];
      return mx;
   }
   else
   {
      double lo[]; ArraySetAsSeries(lo,true);
      int got=CopyLow(_Symbol,PERIOD_M1,1,g_ReclaimLookbackBars,lo);
      if(got<1) return 0;
      double mn=lo[0];
      for(int i=1;i<got;i++) if(lo[i]<mn) mn=lo[i];
      return mn;
   }
}

void UpdateReclaimLevel()
{
   if(!g_Scalp.active || g_Scalp.state!=SCALP_WAIT_RECLAIM) return;
   double newLevel=CalcReclaimLevel(g_Scalp.direction);
   if(newLevel<=0) return;
   if(MathAbs(newLevel-g_Scalp.reclaimLevel) < _Point*0.5) return; // no change
   g_Scalp.reclaimLevel=newLevel;
   g_Scalp.reclaimUpdateTime=TimeCurrent();
   // re-arm logic: price must be on correct side first
   MqlTick tk; if(SymbolInfoTick(_Symbol,tk))
   {
      if(g_Scalp.direction==BIAS_BULLISH) g_Scalp.crossActive = (tk.ask <= newLevel);
      else g_Scalp.crossActive = (tk.bid >= newLevel);
   }
   else g_Scalp.crossActive=false;
   LogScalp(StringFormat("%s reclaim updated to %.2f armed=%s", BiasToStr(g_Scalp.direction), newLevel, g_Scalp.crossActive?"true":"false"));
   g_SetupVisualDirty=true; g_PanelDirty=true;
}

// Called on new M1 bar - pullback detection + reclaim update + expiry
void ProcessM1ScalpOnNewBar()
{
   // expiry check first
   if(g_Scalp.active && g_ScalpSetupExpiryMin>0)
   {
      long age=(long)TimeCurrent()-(long)g_Scalp.createdTime;
      if(age > (long)g_ScalpSetupExpiryMin*60)
      {
         LogScalp(StringFormat("Scalp #%d expired after %ds - reset", (int)g_Scalp.id, (int)age));
         g_Cnt_SetupsExpired++;
         SetLastAction("Scalp #"+IntegerToString((int)g_Scalp.id)+" expired - reset");
         ResetScalp();
         // fall through to possibly create new pullback same bar
      }
   }

   // M5 regime must be non-neutral to create/keep
   ENUM_BIAS m5bias=g_M5.bias;
   if(m5bias==BIAS_NEUTRAL)
   {
      // No new setup while neutral, but existing reclaim may still be waiting until expiry/M5 flip
      if(g_Scalp.active && g_Scalp.state==SCALP_WAIT_RECLAIM)
         UpdateReclaimLevel();
      return;
   }

   double atr=AtrVal(g_ATR_M1,1);
   if(atr<=0) return;

   // If no active setup, try to detect fresh pullback
   if(!g_Scalp.active)
   {
      // Need at least PullbackLookbackBars completed bars available
      if(Bars(_Symbol,PERIOD_M1) < g_PullbackLookbackBars+2) return;
      double required=atr * g_M1PullbackATR;
      if(required<=0) return;

      if(m5bias==BIAS_BULLISH)
      {
         int hiIdx=-1;
         double recentHigh=HighestHighM1(g_PullbackLookbackBars, hiIdx);
         if(recentHigh<=0 || hiIdx<0) return;
         // lowest low since that high (inclusive) -> shift 1 .. hiIdx+1 bars
         int count=hiIdx+1;
         if(count<1) count=1;
         double pullbackLow=LowestLowRangeM1(1,count);
         if(pullbackLow<=0) return;
         double dist=recentHigh - pullbackLow;
         g_PanelPullbackDist=dist; g_PanelRequiredPullback=required;
         if(dist >= required)
         {
            g_Scalp.active=true;
            g_Scalp.id=++g_NextSetupId;
            g_Scalp.direction=BIAS_BULLISH;
            g_Scalp.state=SCALP_WAIT_RECLAIM;
            g_Scalp.recentHigh=recentHigh;
            g_Scalp.pullbackLow=pullbackLow;
            g_Scalp.pullbackDistance=dist;
            g_Scalp.requiredPullback=required;
            g_Scalp.createdTime=TimeCurrent();
            g_Scalp.pullbackTime=iTime(_Symbol,PERIOD_M1,1);
            g_Scalp.crossActive=false;
            g_Scalp.statusText="WAIT_RECLAIM";
            // initial reclaim level
            g_Scalp.reclaimLevel=CalcReclaimLevel(BIAS_BULLISH);
            // arm check
            MqlTick tk; if(SymbolInfoTick(_Symbol,tk)) g_Scalp.crossActive=(tk.ask <= g_Scalp.reclaimLevel);
            g_Cnt_PullbackDetected++;
            g_Cnt_ReclaimArmed++;
            LogScalp(StringFormat("BUY pullback detected: recentHigh=%.2f pullbackLow=%.2f distance=%.2f required=%.2f ATR=%.2f reclaim=%.2f", recentHigh, pullbackLow, dist, required, atr, g_Scalp.reclaimLevel));
            SetLastAction(StringFormat("BUY pullback qualified (%.2f/%.2f) reclaim %.2f", dist, required, g_Scalp.reclaimLevel));
            g_SetupVisualDirty=true; g_PanelDirty=true;
         }
      }
      else if(m5bias==BIAS_BEARISH)
      {
         int loIdx=-1;
         double recentLow=LowestLowM1(g_PullbackLookbackBars, loIdx);
         if(recentLow<=0 || loIdx<0) return;
         int count=loIdx+1;
         if(count<1) count=1;
         double pullbackHigh=HighestHighRangeM1(1,count);
         if(pullbackHigh<=0) return;
         double dist=pullbackHigh - recentLow;
         g_PanelPullbackDist=dist; g_PanelRequiredPullback=required;
         if(dist >= required)
         {
            g_Scalp.active=true;
            g_Scalp.id=++g_NextSetupId;
            g_Scalp.direction=BIAS_BEARISH;
            g_Scalp.state=SCALP_WAIT_RECLAIM;
            g_Scalp.recentLow=recentLow;
            g_Scalp.pullbackHigh=pullbackHigh;
            g_Scalp.pullbackDistance=dist;
            g_Scalp.requiredPullback=required;
            g_Scalp.createdTime=TimeCurrent();
            g_Scalp.pullbackTime=iTime(_Symbol,PERIOD_M1,1);
            g_Scalp.crossActive=false;
            g_Scalp.statusText="WAIT_RECLAIM";
            g_Scalp.reclaimLevel=CalcReclaimLevel(BIAS_BEARISH);
            MqlTick tk; if(SymbolInfoTick(_Symbol,tk)) g_Scalp.crossActive=(tk.bid >= g_Scalp.reclaimLevel);
            g_Cnt_PullbackDetected++;
            g_Cnt_ReclaimArmed++;
            LogScalp(StringFormat("SELL pullback detected: recentLow=%.2f pullbackHigh=%.2f distance=%.2f required=%.2f ATR=%.2f reclaim=%.2f", recentLow, pullbackHigh, dist, required, atr, g_Scalp.reclaimLevel));
            SetLastAction(StringFormat("SELL pullback qualified (%.2f/%.2f) reclaim %.2f", dist, required, g_Scalp.reclaimLevel));
            g_SetupVisualDirty=true; g_PanelDirty=true;
         }
      }
   }
   else
   {
      // active setup exists
      if(g_Scalp.state==SCALP_WAIT_RECLAIM)
      {
         // direction must still match M5, already checked flip elsewhere but also check here
         if(g_Scalp.direction!=m5bias)
         {
            InvalidateScalp("M5 flipped");
            g_Cnt_SetupsInvalidatedM5++;
            return;
         }
         UpdateReclaimLevel();
      }
   }
}

// Live tick reclaim cross check - requires fresh cross
void CheckReclaimCrossOnTick()
{
   if(!g_Scalp.active || g_Scalp.state!=SCALP_WAIT_RECLAIM) return;
   if(g_Scalp.reclaimLevel<=0) return;
   // Also ensure M5 still allows direction (no entry if M5 neutralized)
   if(g_M5.bias!=g_Scalp.direction) { InvalidateScalp("M5 no longer supports direction"); return; }

   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return;
   double price = (g_Scalp.direction==BIAS_BULLISH)?tk.ask:tk.bid;
   if(price<=0) return;

   bool beyond = (g_Scalp.direction==BIAS_BULLISH) ? (price > g_Scalp.reclaimLevel) : (price < g_Scalp.reclaimLevel);

   if(!beyond)
   {
      // price back to/on correct side -> arm
      g_Scalp.crossActive=true;
      return;
   }
   // beyond level
   if(!g_Scalp.crossActive) return; // was already beyond at setup time, need to first go back
   // fresh cross!
   // consume setup before attempt (one-shot)
   long id=g_Scalp.id;
   ENUM_BIAS dir=g_Scalp.direction;
   double reclaim=g_Scalp.reclaimLevel;
   double inval = (dir==BIAS_BULLISH)?g_Scalp.pullbackLow:g_Scalp.pullbackHigh;
   // copy for log before reset
   LogScalp(StringFormat("%s fresh cross -> reclaim %.2f price %.2f armed cross - entry attempt #%d", BiasToStr(dir), reclaim, price, (int)id));
   SetLastAction(BiasToStr(dir)+" #"+IntegerToString((int)id)+" reclaim cross - attempting entry");
   g_Cnt_Breakouts++;

   string blockReason="";
   if(CheckEntryPermissions(dir,blockReason))
   {
      g_Cnt_EntryAttempts++;
      if(ExecuteScalpTrade(reclaim,inval))
      {
         g_Cnt_EntryExecuted++;
      }
      else
      {
         g_Cnt_EntryFailed++;
      }
   }
   else
   {
      g_Cnt_EntryBlocked++;
      LogTrade(BiasToStr(dir)+" #"+IntegerToString((int)id)+" entry blocked: "+blockReason);
      SetLastAction(BiasToStr(dir)+" #"+IntegerToString((int)id)+" blocked: "+blockReason);
   }
   // consume regardless
   DeleteScalpVisuals();
   ResetScalp();
}

//=========================================================================
//             ENTRY PERMISSIONS (no HTF unanimous, no SR)
//=========================================================================
bool CheckEntryPermissions(ENUM_BIAS dir,string &reason)
{
   reason="";
   if(!g_InitComplete)                 { reason="initialization incomplete";   return false; }
   if(g_HaltedDaily)                   { reason="daily loss halt";             return false; }
   if(g_HaltedConsec)                  { reason="consecutive loss halt";       return false; }
   if(g_HaltedFloat)                   { reason="floating loss halt";          return false; }
   // Direction permission is M5 only
   if(dir==BIAS_BULLISH && g_M5.bias!=BIAS_BULLISH) { reason="M5 not bullish"; return false; }
   if(dir==BIAS_BEARISH && g_M5.bias!=BIAS_BEARISH) { reason="M5 not bearish"; return false; }
   if(CountPositions()>=g_MaxOpenTrades){ reason="position limit";             return false; }
   // No hedging: don't open opposite while existing directional position open
   if(dir==BIAS_BULLISH && HasOpenPositionInDirection(BIAS_BEARISH)) { reason="no hedge - SELL open"; return false; }
   if(dir==BIAS_BEARISH && HasOpenPositionInDirection(BIAS_BULLISH)) { reason="no hedge - BUY open"; return false; }
   if(!InSession())                    { reason="outside session";             return false; }
   if(!SpreadOK())                     { reason="spread too high";             return false; }
   if(!VolOK())                        { reason="volatility spike";            return false; }
   return true;
}

//=========================================================================
//      FIXED-LOT VOLUME MODEL
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
   return "V14#"+IntegerToString((int)setupId);
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
bool SubmitOrder(MqlTradeRequest &req,MqlTradeResult &res,string &fillingUsed, int &lastRetcode,string &lastErrorText)
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
//                    ENTRY EXECUTION WITH STRUCTURAL SL
//=========================================================================
bool ExecuteScalpTrade(double reclaimLevel,double pullbackInvalidation)
{
   // active setup info already consumed but we have id/dir
   // Need to re-derive direction from last scalp? Use stored before reset? We'll use g_M5 bias? Actually we passed dir via global before reset, but after reset we lost. Better capture before reset.
   // This function is called BEFORE reset, so g_Scalp still holds dir/id. We will call it with those values.
   // To avoid confusion, caller should pass dir explicitly. Let's use g_Scalp inside.
   if(!g_Scalp.active) return false;
   ENUM_BIAS dir=g_Scalp.direction;
   long sid=g_Scalp.id;
   string dirS=(dir==BIAS_BULLISH)?"BUY":"SELL";
   string cmt=TradeComment(sid);
   string permReason;
   if(!PreTradePermissionCheck(permReason))
   {
      RegisterRejectionCategory(REJ_BROKER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: %s",dirS,(int)sid,permReason);
      SetLastAction(dirS+" rejected: "+permReason);
      return false;
   }
   double minL,maxL,step;
   double lot=NormalizeLot(g_LotSize,minL,maxL,step);
   if(lot<minL || lot<=0)
   {
      RegisterRejectionCategory(REJ_LOT);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: fixed lot %.4f below broker minimum %.2f (step %.2f)", dirS,(int)sid,g_LotSize,minL,step);
      SetLastAction(dirS+" rejected: lot below min");
      return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
   {
      RegisterRejectionCategory(REJ_OTHER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: no tick data",dirS,(int)sid);
      return false;
   }
   ENUM_ORDER_TYPE ot=(dir==BIAS_BULLISH) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry=(ot==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   if(entry<=0)
   {
      RegisterRejectionCategory(REJ_OTHER);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: invalid price",dirS,(int)sid);
      return false;
   }
   // ATR snapshot for this entry
   double entryATR=AtrVal(g_ATR_M1,1);
   if(entryATR<=0) entryATR=AtrVal(g_ATR_M1,1); // fallback
   if(entryATR<=0) entryATR= SymbolInfoDouble(_Symbol,SYMBOL_POINT)*100;
   // calculate structural SL
   double sl=0;
   double buffer=entryATR * g_InitialSLBufferATR;
   if(dir==BIAS_BULLISH)
      sl = pullbackInvalidation - buffer;
   else
      sl = pullbackInvalidation + buffer;
   sl=NormalizeDouble(sl,_Digits);
   // Validate SL distance vs broker stops level
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int stopsLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stopsLevel*point;
   // also freeze? Use stops level only
   double priceForDist = entry;
   double dist = MathAbs(entry - sl);
   if(minDist>0 && dist < minDist)
   {
      // adjust SL outward to satisfy minimum
      if(dir==BIAS_BULLISH) sl = entry - minDist - point;
      else sl = entry + minDist + point;
      sl=NormalizeDouble(sl,_Digits);
      PrintFormat("[TRADE] %s #%d SL adjusted for stops level: new SL=%.5f",dirS,(int)sid,sl);
   }
   // Validate SL side
   if(dir==BIAS_BULLISH && sl>=entry)
   {
      RegisterRejectionCategory(REJ_STOPS);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: SL %.5f >= entry %.5f",dirS,(int)sid,sl,entry);
      return false;
   }
   if(dir==BIAS_BEARISH && sl<=entry)
   {
      RegisterRejectionCategory(REJ_STOPS);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: SL %.5f <= entry %.5f",dirS,(int)sid,sl,entry);
      return false;
   }
   // Also check SL not too far? No limit

   // OrderCheck
   MqlTradeRequest chk; MqlTradeCheckResult chkRes;
   ZeroMemory(chk); ZeroMemory(chkRes);
   chk.action =TRADE_ACTION_DEAL;
   chk.symbol =_Symbol;
   chk.volume =lot;
   chk.type   =ot;
   chk.price  =entry;
   chk.sl     =sl;
   chk.tp     =0;
   if(!OrderCheck(chk,chkRes))
   {
      ENUM_REJECT_CAT cat=REJ_BROKER;
      if(chkRes.retcode==TRADE_RETCODE_NO_MONEY)            cat=REJ_MARGIN;
      else if(chkRes.retcode==TRADE_RETCODE_INVALID_VOLUME) cat=REJ_LOT;
      else if(chkRes.retcode==TRADE_RETCODE_INVALID_STOPS)  cat=REJ_STOPS;
      RegisterRejectionCategory(cat);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: ORDER_CHECK_FAILED %s | %s  Entry=%.5f SL=%.5f Lot=%.2f", dirS,(int)sid,RetcodeToString((int)chkRes.retcode),chkRes.comment, entry,sl,lot);
      SetLastAction(dirS+" rejected: "+RetcodeToString((int)chkRes.retcode));
      return false;
   }

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = lot;
   req.type      = ot;
   req.price     = entry;
   req.sl        = sl;
   req.tp        = 0;
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
      else if(lastRet==TRADE_RETCODE_INVALID_STOPS)  cat=REJ_STOPS;
      RegisterRejectionCategory(cat);
      PrintFormat("[TRADE] %s #%d REJECTED  Reason: %s  Entry=%.5f SL=%.5f Lot=%.2f",dirS,(int)sid,errText,entry,sl,lot);
      SetLastAction(dirS+" rejected: "+RetcodeToString(lastRet));
      return false;
   }
   // success
   if(ot==ORDER_TYPE_BUY) g_LongTrades++; else g_ShortTrades++;
   PrintFormat("[TRADE] %s #%d ACCEPTED  lot=%.2f entry=%.5f SL=%.5f TP=none filling=%s comment=%s entryATR=%.2f reclaim=%.5f inval=%.5f", dirS,(int)sid,lot,entry,sl,fillingUsed,cmt,entryATR,reclaimLevel,pullbackInvalidation);
   PrintFormat("Scalp: dist=%.2f req=%.2f BE trigger=%.2f trailStart=%.2f", g_Scalp.pullbackDistance, g_Scalp.requiredPullback, entryATR*g_BreakEvenTriggerATR, entryATR*g_TrailStartATR);
   DrawEntryMarker(ot,entry,TimeCurrent(),(int)sid);
   SetLastAction(StringFormat("%s #%d opened %.2f lots SL %.5f ATR %.2f",dirS,(int)sid,lot,sl,entryATR));
   // create / update track immediately so BE/trail can work next tick even before position scan
   // Find position ticket by magic? We'll let ManageOpenPositions create it via scan, but we can attempt to find latest position
   // Instead, we will not create here; ManageOpenPositions will reconstruct with correct entryATR/sl
   // We store pending ATR for next scan via global? We need to ensure track gets correct entryATR.
   // We'll attempt to locate position now
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      if(PositionGetString(POSITION_COMMENT)!=cmt) continue;
      // found
      double posEntry=PositionGetDouble(POSITION_PRICE_OPEN);
      datetime otm=(datetime)PositionGetInteger(POSITION_TIME);
      TrackIndexFor(t,otm,sid,posEntry,entryATR,sl);
      break;
   }
   return true;
}

//=========================================================================
//                     POSITION CLOSING / MODIFY
//=========================================================================
bool CloseOnePosition(ulong ticket,string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double vol=PositionGetDouble(POSITION_VOLUME);
   if(vol<=0) return false;
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req);
   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = vol;
   req.type      = (pt==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price     = (req.type==ORDER_TYPE_SELL) ? tick.bid : tick.ask;
   req.deviation = (ulong)g_MaxSlippagePoints;
   req.magic     = (ulong)MagicNumber;
   req.comment   = "V14-close";
   ENUM_ACCOUNT_MARGIN_MODE mm=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) req.position=ticket;
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
bool ModifyPositionSL(ulong ticket,double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double curSL=PositionGetDouble(POSITION_SL);
   double curTP=PositionGetDouble(POSITION_TP);
   // normalize
   newSL=NormalizeDouble(newSL,_Digits);
   if(MathAbs(newSL-curSL) < _Point*0.5) return false;
   // Validate direction: must be protective
   ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pt==POSITION_TYPE_BUY && newSL <= curSL) return false;
   if(pt==POSITION_TYPE_SELL && newSL >= curSL) return false;
   // Check stops level distance to current price
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int stopsLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=stopsLevel*point;
   MqlTick tk; if(!SymbolInfoTick(_Symbol,tk)) return false;
   double price=(pt==POSITION_TYPE_BUY)?tk.bid:tk.ask;
   double dist=MathAbs(price - newSL);
   if(minDist>0 && dist < minDist) return false;
   // Also SL must be on correct side of price
   if(pt==POSITION_TYPE_BUY && newSL >= price) return false;
   if(pt==POSITION_TYPE_SELL && newSL <= price) return false;

   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP;
   req.symbol=_Symbol;
   req.position=ticket;
   req.sl=newSL;
   req.tp=curTP;
   // sltp does not use filling
   if(!OrderSend(req,res))
   {
      PrintFormat("[MODIFY] ticket=%I64u SL %.5f -> %.5f failed: %s GetLastError=%d", ticket,curSL,newSL, RetcodeToString((int)res.retcode), GetLastError());
      return false;
   }
   if(res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("[MODIFY] ticket=%I64u SL %.5f -> %.5f rejected: %s", ticket,curSL,newSL, RetcodeToString((int)res.retcode));
      return false;
   }
   PrintFormat("[MODIFY] ticket=%I64u SL %.5f -> %.5f success", ticket,curSL,newSL);
   return true;
}

//=========================================================================
//          PER-TICK POSITION MANAGEMENT (BE + TRAIL)
//=========================================================================
void ManageOpenPositions()
{
   double totalFloat=0;
   int    pnTotal=0, pnBuys=0, pnSells=0;
   double pnVol=0, pnBuyVP=0, pnBuyV=0, pnSellVP=0, pnSellV=0;

   // First pass: ensure every open position has a track (handles restart)
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      double profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      long   setupId=ParseSetupIdFromComment(PositionGetString(POSITION_COMMENT));
      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      int ti=FindTrack(t);
      double entryATR=0;
      if(ti>=0) entryATR=g_Tracks[ti].entryATR;
      else
      {
         // reconstruct: use current M1 ATR as fallback
         entryATR=AtrVal(g_ATR_M1,1);
         if(entryATR<=0) entryATR=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*200;
         ti=TrackIndexFor(t,opened,setupId,entry,entryATR,curSL);
         if(ti>=0) PrintFormat("[RECOVER] Recovered track for ticket=%I64u entry=%.5f ATR=%.2f SL=%.5f", t, entry, entryATR, curSL);
      }
      if(ti<0) continue;
      if(profit<g_Tracks[ti].minFloat) g_Tracks[ti].minFloat=profit;
      totalFloat+=profit;
      {
         double pvol=PositionGetDouble(POSITION_VOLUME);
         double popen=entry;
         pnTotal++; pnVol+=pvol;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
         { pnBuys++;  pnBuyV+=pvol;  pnBuyVP+=popen*pvol; }
         else
         { pnSells++; pnSellV+=pvol; pnSellVP+=popen*pvol; }
      }
   }

   // Second pass: BE + TRAIL per position
   MqlTick tk; bool haveTick=SymbolInfoTick(_Symbol,tk);
   double curM1ATR=AtrVal(g_ATR_M1,1);
   if(curM1ATR<=0) curM1ATR=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*100;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      int ti=FindTrack(t);
      if(ti<0) continue;
      if(!haveTick) continue;

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry=g_Tracks[ti].entryPrice;
      if(entry<=0) entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      double entryATR=g_Tracks[ti].entryATR;
      if(entryATR<=0) entryATR=curM1ATR;

      // --- BREAK EVEN ---
      if(!g_Tracks[ti].breakEvenApplied)
      {
         double trigger=entryATR * g_BreakEvenTriggerATR;
         bool hit=false;
         double newSL=0;
         if(pt==POSITION_TYPE_BUY)
         {
            if(tk.bid - entry >= trigger) { hit=true; newSL=entry + entryATR * g_BreakEvenOffsetATR; }
         }
         else
         {
            if(entry - tk.ask >= trigger) { hit=true; newSL=entry - entryATR * g_BreakEvenOffsetATR; }
         }
         if(hit)
         {
            newSL=NormalizeDouble(newSL,_Digits);
            // never move backward
            bool canMove=false;
            if(pt==POSITION_TYPE_BUY) canMove=(newSL > curSL);
            else canMove=(newSL < curSL && (curSL==0 || newSL < curSL));
            // for sell, curSL may be 0 initially? but we have initial SL, so not 0
            if(canMove)
            {
               if(ModifyPositionSL(t,newSL))
               {
                  g_Tracks[ti].breakEvenApplied=true;
                  g_Tracks[ti].lastSL=newSL;
                  g_Tracks[ti].trailActive=false; // trail will activate later
                  g_Cnt_BreakEven++;
                  PrintFormat("[BE] %s ticket=%I64u entry=%.5f ATR=%.2f trigger=%.2f newSL=%.5f", (pt==POSITION_TYPE_BUY?"BUY":"SELL"), t, entry, entryATR, trigger, newSL);
                  SetLastAction(StringFormat("BE %s #%d SL->%.2f", (pt==POSITION_TYPE_BUY?"BUY":"SELL"), (int)g_Tracks[ti].setupId, newSL));
               }
            }
            else
            {
               // still mark as applied to avoid repeated checks if SL already beyond BE
               if(pt==POSITION_TYPE_BUY && curSL>=newSL) g_Tracks[ti].breakEvenApplied=true;
               if(pt==POSITION_TYPE_SELL && curSL<=newSL && curSL>0) g_Tracks[ti].breakEvenApplied=true;
            }
         }
      }

      // --- TRAILING ---
      // Update curSL after potential BE
      if(PositionSelectByTicket(t)) curSL=PositionGetDouble(POSITION_SL);
      else continue;

      double trailStartDist=entryATR * g_TrailStartATR;
      bool inTrailZone=false;
      if(pt==POSITION_TYPE_BUY) inTrailZone = (tk.bid - entry >= trailStartDist);
      else inTrailZone = (entry - tk.ask >= trailStartDist);

      if(inTrailZone) g_Tracks[ti].trailActive=true;

      if(g_Tracks[ti].trailActive)
      {
         double desired=0;
         if(pt==POSITION_TYPE_BUY) desired = tk.bid - curM1ATR * g_TrailDistanceATR;
         else desired = tk.ask + curM1ATR * g_TrailDistanceATR;
         desired=NormalizeDouble(desired,_Digits);
         double step=curM1ATR * g_TrailStepATR;
         if(step < _Point*10) step=_Point*10;
         bool canTrail=false;
         double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
         int stopsLevel=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
         double minDist=stopsLevel*point;

         if(pt==POSITION_TYPE_BUY)
         {
            if(desired > curSL + step - 1e-9 && desired < tk.bid - minDist && desired > entry)
               canTrail=true;
         }
         else
         {
            if(desired < curSL - step + 1e-9 && desired > tk.ask + minDist)
               canTrail=true;
         }
         if(canTrail)
         {
            if(ModifyPositionSL(t,desired))
            {
               g_Tracks[ti].lastSL=desired;
               g_Cnt_TrailingMods++;
               PrintFormat("[TRAIL] %s ticket=%I64u SL %.5f -> %.5f (bid=%.5f ask=%.5f atr=%.2f)", (pt==POSITION_TYPE_BUY?"BUY":"SELL"), t, curSL, desired, tk.bid, tk.ask, curM1ATR);
            }
         }
      }
   }

   g_TotalFloat=totalFloat;
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
      PrintFormat("[EMERGENCY] Combined floating loss $%.2f <= -$%.2f -> new entries HALTED", totalFloat,g_MaxFloatingLossUSD);
      if(CloseAllOnEmergencyLoss) CloseAllEAPositions("max floating loss breached");
      else SetLastAction("EMERGENCY: floating loss halt (close-all disabled)");
   }
   CompactTracks();
}

//=========================================================================
//                     COMPLETED-TRADE ACCOUNTING
//=========================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=MagicNumber) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   double profit = HistoryDealGetDouble(trans.deal,DEAL_PROFIT) + HistoryDealGetDouble(trans.deal,DEAL_SWAP) + HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   long posId=(long)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   TombstoneTrack((ulong)posId);
   g_DayPL += profit;
   g_ConsLoss = (profit<0) ? g_ConsLoss+1 : 0;
   if(g_ConsLoss>g_MaxConsecLossPeak) g_MaxConsecLossPeak=g_ConsLoss;
   if(g_DayBal>0 && g_DailyLossLimitPercent>0 && g_DayPL<=-(g_DayBal*g_DailyLossLimitPercent/100.0)) g_HaltedDaily=true;
   if(g_ConsecutiveLossLimit>0 && g_ConsLoss>=g_ConsecutiveLossLimit) g_HaltedConsec=true;
   g_TotalTrades++;
   g_TotalRealizedPL += profit;
   if(profit>0)      { g_Wins++;   g_SumWinProfit+=profit;  if(profit>g_LargestWin)  g_LargestWin=profit; }
   else if(profit<0) { g_Losses++; g_SumLossProfit+=profit; if(profit<g_LargestLoss) g_LargestLoss=profit; }
   {
      long dtype=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
      datetime dtime=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
      PnPushClosedTrade(dtime,(dtype==DEAL_TYPE_SELL),profit);
   }
   g_PanelDirty=true;
   g_LastAction=StringFormat("Trade closed  P/L $%.2f  (Total $%.2f)",profit,g_TotalRealizedPL);
   PrintFormat("[TRADE] Closed positionId=%I64d profit=%.2f | Total=%.2f Wins=%d Losses=%d Streak=%d", posId,profit,g_TotalRealizedPL,g_Wins,g_Losses,g_ConsLoss);
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
   for(int s=maxShift;s>=0;s--) UpdateTFStructure(st,tf,atrHandle,s,false);
}
bool ValidateGeneralInputs()
{
   if(PivotSize<1)         { Print("[INIT] PivotSize must be >=1"); return false; }
   if(ATRPeriod<1)         { Print("[INIT] ATRPeriod must be >=1"); return false; }
   if(LotSize<=0)          { Print("[INIT] LotSize must be >0"); return false; }
   if(MaxOpenTrades<1)     { Print("[INIT] MaxOpenTrades must be >=1"); return false; }
   if(MaxFloatingLossUSD<=0){Print("[INIT] MaxFloatingLossUSD must be >0"); return false; }
   // clamp scalper inputs
   g_PivotSize=MathMin(MathMax(PivotSize,1),20);
   g_ATRPeriod=MathMin(MathMax(ATRPeriod,1),500);
   g_StructureExpansion=MathMax(0.0,MathMin(StructureExpansion,10.0));
   g_M1PullbackATR=MathMax(0.1,MathMin(M1PullbackATR,5.0));
   if(MathAbs(g_M1PullbackATR - M1PullbackATR)>1e-9) Print("[INIT] M1PullbackATR clamped to ",DoubleToString(g_M1PullbackATR,2));
   g_PullbackLookbackBars=MathMax(2,MathMin(PullbackLookbackBars,50));
   g_ReclaimLookbackBars=MathMax(1,MathMin(ReclaimLookbackBars,20));
   g_ScalpSetupExpiryMin=MathMax(1,MathMin(ScalpSetupExpiryMin,120));
   g_InitialSLBufferATR=MathMax(0.0,MathMin(InitialSLBufferATR,2.0));
   g_BreakEvenTriggerATR=MathMax(0.1,MathMin(BreakEvenTriggerATR,5.0));
   g_BreakEvenOffsetATR=MathMax(-1.0,MathMin(BreakEvenOffsetATR,2.0));
   g_TrailStartATR=MathMax(0.1,MathMin(TrailStartATR,5.0));
   g_TrailDistanceATR=MathMax(0.1,MathMin(TrailDistanceATR,5.0));
   g_TrailStepATR=MathMax(0.01,MathMin(TrailStepATR,1.0));
   g_LotSize=LotSize;
   g_MaxOpenTrades=MathMin(MaxOpenTrades,200);
   g_MaxFloatingLossUSD=MaxFloatingLossUSD;
   g_VolatilityLookback=MathMax(2,MathMin(VolatilityLookback,1000));
   g_VolatilitySpikeLimit=(VolatilitySpikeLimit<=0)?1.5:MathMin(VolatilitySpikeLimit,100.0);
   g_MaxSpreadPoints=MathMax(1,MathMin(MaxSpreadPoints,100000));
   g_DailyLossLimitPercent=MathMax(0.0,MathMin(DailyLossLimitPercent,100.0));
   g_ConsecutiveLossLimit=MathMax(0,MathMin(ConsecutiveLossLimit,1000));
   g_HTFWarmupBars=MathMax(0,MathMin(HTFWarmupBars,5000));
   g_M1WarmupBars=MathMax(0,MathMin(M1WarmupBars,10000));
   g_MaxSlippagePoints=MathMax(0,MathMin(MaxSlippagePoints,10000));
   g_TradingStartHour=TradingStartHour;
   g_TradingEndHour=TradingEndHour;
   if(g_TradingStartHour<0 || g_TradingStartHour>23 || g_TradingEndHour<0 || g_TradingEndHour>23)
   {
      Print("[INIT] Trading hours out of range (0..23) - session filter disabled (24h).");
      g_TradingStartHour=0; g_TradingEndHour=0;
   }
   return true;
}
int OnInit()
{
   g_InitComplete=false;
   if(!ValidateGeneralInputs()) return INIT_PARAMETERS_INCORRECT;
   g_ATR_H1  = iATR(_Symbol, PERIOD_H1,  g_ATRPeriod);
   g_ATR_M15 = iATR(_Symbol, PERIOD_M15, g_ATRPeriod);
   g_ATR_M5  = iATR(_Symbol, PERIOD_M5,  g_ATRPeriod);
   g_ATR_M1  = iATR(_Symbol, PERIOD_M1,  g_ATRPeriod);
   if(g_ATR_H1==INVALID_HANDLE || g_ATR_M15==INVALID_HANDLE || g_ATR_M5==INVALID_HANDLE || g_ATR_M1==INVALID_HANDLE)
      return INIT_FAILED;

   ObjectsDeleteAll(0,"V13_");
   ObjectsDeleteAll(0,"V14_");
   ObjectsDeleteAll(0,"V13_SR_");
   ObjectsDeleteAll(0,"V13_S");
   ObjectsDeleteAll(0,"V13_H1_");
   ObjectsDeleteAll(0,"V13_M15_");
   ObjectsDeleteAll(0,"V13_M5_");
   ObjectsDeleteAll(0,"V13_Entry_");

   ResetTFStruct(g_H1);
   ResetTFStruct(g_M15);
   ResetTFStruct(g_M5);
   ResetScalp();
   ArrayResize(g_Tracks,0);
   ArrayResize(g_EntryMarkerQueue,0);
   g_Day=-1;
   g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_MaxDrawdownPct=0;

   WarmupTF(g_H1, PERIOD_H1,  g_ATR_H1,  g_HTFWarmupBars);
   WarmupTF(g_M15,PERIOD_M15, g_ATR_M15, g_HTFWarmupBars);
   WarmupTF(g_M5, PERIOD_M5,  g_ATR_M5,  g_HTFWarmupBars);
   PrintFormat("[INIT] H1=%s M15=%s M5=%s (M5 is boss)  ATR M1 ready", BiasToStr(g_H1.bias), BiasToStr(g_M15.bias), BiasToStr(g_M5.bias));

   g_LastH1Bar =iTime(_Symbol,PERIOD_H1,0);
   g_LastM15Bar=iTime(_Symbol,PERIOD_M15,0);
   g_LastM5Bar =iTime(_Symbol,PERIOD_M5,0);
   g_LastM1Bar =iTime(_Symbol,PERIOD_M1,0);

   // recover existing positions tracking (restart safety)
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionIsMine()) continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      long sid=ParseSetupIdFromComment(PositionGetString(POSITION_COMMENT));
      datetime ot=(datetime)PositionGetInteger(POSITION_TIME);
      double atr=AtrVal(g_ATR_M1,1);
      if(atr<=0) atr=SymbolInfoDouble(_Symbol,SYMBOL_POINT)*200;
      TrackIndexFor(t,ot,sid,entry,atr,sl);
      PrintFormat("[RECOVER] Position ticket=%I64u entry=%.5f SL=%.5f setup#%d ATR=%.2f", t, entry, sl, (int)sid, atr);
   }

   ClearPanelObjects();
   g_PanelVisible=false;
   g_PanelDirty=true;
   g_PanelLastDrawMs=GetTickCount();
   g_HTFVisualDirty=true; g_SetupVisualDirty=true;
   g_TimerActive=false;
   if(DebugMode && !MQLInfoInteger(MQL_TESTER))
   {
      int ms=MathMax(50,MathMin(PanelRefreshMs,5000));
      if(EventSetMillisecondTimer(ms)) g_TimerActive=true;
   }
   g_InitComplete=true;
   SetLastAction("Initialized - M5 "+BiasToStr(g_M5.bias)+" - scanning M1 pullbacks");
   PrintFormat("[INIT] V14 scalper ready. M5=%s  PullbackATR=%.2f Lookback=%d Reclaim=%d Expiry=%dmin  SLbuf=%.2f BE %.2f Trail %.2f/%.2f step %.2f", BiasToStr(g_M5.bias), g_M1PullbackATR, g_PullbackLookbackBars, g_ReclaimLookbackBars, g_ScalpSetupExpiryMin, g_InitialSLBufferATR, g_BreakEvenTriggerATR, g_TrailStartATR, g_TrailDistanceATR, g_TrailStepATR);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   g_InitComplete=false;
   if(g_ATR_H1 !=INVALID_HANDLE) IndicatorRelease(g_ATR_H1);
   if(g_ATR_M15!=INVALID_HANDLE) IndicatorRelease(g_ATR_M15);
   if(g_ATR_M5 !=INVALID_HANDLE) IndicatorRelease(g_ATR_M5);
   if(g_ATR_M1 !=INVALID_HANDLE) IndicatorRelease(g_ATR_M1);
   g_ATR_H1=g_ATR_M15=g_ATR_M5=g_ATR_M1=INVALID_HANDLE;
   if(g_TimerActive) { EventKillTimer(); g_TimerActive=false; }
   ObjectsDeleteAll(0,"V13_SR_");
   DeleteScalpVisuals();
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

   if(IsNewBar(PERIOD_H1, g_LastH1Bar))  UpdateTFStructure(g_H1, PERIOD_H1, g_ATR_H1, 0,true);
   if(IsNewBar(PERIOD_M15,g_LastM15Bar)) UpdateTFStructure(g_M15,PERIOD_M15,g_ATR_M15,0,true);
   if(IsNewBar(PERIOD_M5, g_LastM5Bar))  UpdateTFStructure(g_M5, PERIOD_M5, g_ATR_M5, 0,true);

   bool newM1=IsNewBar(PERIOD_M1, g_LastM1Bar);
   if(newM1)
   {
      ProcessM1ScalpOnNewBar();
   }

   // live reclaim cross every tick
   CheckReclaimCrossOnTick();

   // open position management must run every tick (even outside session, even when no setup)
   ManageOpenPositions();

   if(!g_TimerActive) PanelTick();
}
void OnTimer()
{
   if(!g_InitComplete) return;
   PanelTick();
}
void PanelTick()
{
   if(!DebugMode)
   {
      if(g_PanelVisible)
      {
         ClearPanelObjects();
         ObjectsDeleteAll(0,"V13_H1_");
         ObjectsDeleteAll(0,"V13_M15_");
         ObjectsDeleteAll(0,"V13_M5_");
         ObjectsDeleteAll(0,"V14_S");
         ObjectsDeleteAll(0,"V13_Entry_");
         ArrayResize(g_EntryMarkerQueue,0);
         g_HTFVisualDirty=true; g_SetupVisualDirty=true;
         g_PanelVisible=false;
         ChartRedraw(0);
      }
      return;
   }
   uint now=GetTickCount();
   uint every=(uint)MathMax(50,MathMin(PanelRefreshMs,5000));
   if(g_PanelVisible && !g_PanelDirty && (now-g_PanelLastDrawMs)<every) return;
   g_PanelLastDrawMs=now;
   g_PanelDirty=false;
   PanelRefreshStateCache();
   bool visualChanged=UpdateChartVisualsIfDirty();
   RefreshPanel();
   g_PanelVisible=true;
   ChartRedraw(0);
   if(visualChanged) {}
}

//=========================================================================
//                          DIAGNOSTIC SUMMARY
//=========================================================================
void PrintBacktestSummary()
{
   Print("===== V14 M5+M1 SCALPER SUMMARY =====");
   PrintFormat("M5 regime engine: H1=%s M15=%s M5=%s", BiasToStr(g_H1.bias), BiasToStr(g_M15.bias), BiasToStr(g_M5.bias));
   double pf=(g_SumLossProfit<0) ? (g_SumWinProfit/MathAbs(g_SumLossProfit)) : 0.0;
   double wr=(g_Wins+g_Losses>0) ? (100.0*g_Wins/(g_Wins+g_Losses)) : 0.0;
   double avgWin =(g_Wins>0)   ? g_SumWinProfit/g_Wins     : 0.0;
   double avgLoss=(g_Losses>0) ? g_SumLossProfit/g_Losses  : 0.0;
   PrintFormat("Trades=%d  Long=%d Short=%d  Wins=%d Losses=%d  WinRate=%.1f%%  PF=%.2f", g_TotalTrades,g_LongTrades,g_ShortTrades,g_Wins,g_Losses,wr,pf);
   PrintFormat("TotalP/L=$%.2f  AvgWin=$%.2f  AvgLoss=$%.2f  LargestWin=$%.2f  LargestLoss=$%.2f  MaxConsecLoss=%d  MaxDD=%.2f%%", g_TotalRealizedPL,avgWin,avgLoss,g_LargestWin,g_LargestLoss,g_MaxConsecLossPeak,g_MaxDrawdownPct);
   Print("---- M5 structure ----");
   PrintFormat("H1: Bull=%d Bear=%d | M15: Bull=%d Bear=%d | M5: Bull=%d Bear=%d", g_H1.cntBull,g_H1.cntBear,g_M15.cntBull,g_M15.cntBear,g_M5.cntBull,g_M5.cntBear);
   Print("---- Scalp pipeline ----");
   PrintFormat("Pullbacks=%d  Reclaims armed=%d  Breakouts=%d  Expired=%d  InvalidM5=%d", g_Cnt_PullbackDetected,g_Cnt_ReclaimArmed,g_Cnt_Breakouts,g_Cnt_SetupsExpired,g_Cnt_SetupsInvalidatedM5);
   PrintFormat("Attempts=%d  Executed=%d  Blocked=%d  Failed=%d", g_Cnt_EntryAttempts,g_Cnt_EntryExecuted,g_Cnt_EntryBlocked,g_Cnt_EntryFailed);
   Print("---- Exit management ----");
   PrintFormat("BreakEvens=%d  TrailingMods=%d", g_Cnt_BreakEven,g_Cnt_TrailingMods);
   Print("---- Execution rejects ----");
   PrintFormat("Lot=%d Stops=%d Margin=%d Filling=%d Broker=%d Other=%d", g_Cnt_RejectLot,g_Cnt_RejectStops,g_Cnt_RejectMargin,g_Cnt_RejectFilling,g_Cnt_RejectBroker,g_Cnt_RejectOther);
   Print("==================================================");
}

//=========================================================================
//                         CHART VISUALIZATION
//=========================================================================
void DrawHTFMarker(string prefix,string tag,double price,datetime time,color clr,int arrowCode,int fontSize)
{
   if(!DebugMode || time<=0) return;
   string name=prefix+tag;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_ARROW,0,time,price);
   else ObjectMove(0,name,0,time,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,arrowCode);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   string label=name+"_txt";
   if(ObjectFind(0,label)<0) ObjectCreate(0,label,OBJ_TEXT,0,time,price);
   else ObjectMove(0,label,0,time,price);
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
string SetupObjName(int id,string tag) { return "V14_S"+IntegerToString(id)+"_"+tag; }
void DrawScalpVisuals()
{
   if(!DebugMode || !g_Scalp.active) return;
   int id=(int)g_Scalp.id;
   if(g_Scalp.pullbackLow>0 && g_Scalp.direction==BIAS_BULLISH)
   {
      string name=SetupObjName(id,"PL");
      datetime t=g_Scalp.pullbackTime;
      if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_ARROW,0,t,g_Scalp.pullbackLow);
      else ObjectMove(0,name,0,t,g_Scalp.pullbackLow);
      ObjectSetInteger(0,name,OBJPROP_ARROWCODE,233);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      string lb=name+"_txt";
      if(ObjectFind(0,lb)<0) ObjectCreate(0,lb,OBJ_TEXT,0,t,g_Scalp.pullbackLow);
      else ObjectMove(0,lb,0,t,g_Scalp.pullbackLow);
      ObjectSetString(0,lb,OBJPROP_TEXT,StringFormat(" #%d PL %.2f",id,g_Scalp.pullbackLow));
      ObjectSetInteger(0,lb,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(0,lb,OBJPROP_FONTSIZE,7);
      ObjectSetInteger(0,lb,OBJPROP_BACK,true);
   }
   if(g_Scalp.pullbackHigh>0 && g_Scalp.direction==BIAS_BEARISH)
   {
      string name=SetupObjName(id,"PH");
      datetime t=g_Scalp.pullbackTime;
      if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_ARROW,0,t,g_Scalp.pullbackHigh);
      else ObjectMove(0,name,0,t,g_Scalp.pullbackHigh);
      ObjectSetInteger(0,name,OBJPROP_ARROWCODE,234);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      string lb=name+"_txt";
      if(ObjectFind(0,lb)<0) ObjectCreate(0,lb,OBJ_TEXT,0,t,g_Scalp.pullbackHigh);
      else ObjectMove(0,lb,0,t,g_Scalp.pullbackHigh);
      ObjectSetString(0,lb,OBJPROP_TEXT,StringFormat(" #%d PH %.2f",id,g_Scalp.pullbackHigh));
      ObjectSetInteger(0,lb,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(0,lb,OBJPROP_FONTSIZE,7);
      ObjectSetInteger(0,lb,OBJPROP_BACK,true);
   }
   if(g_Scalp.reclaimLevel>0 && g_Scalp.state==SCALP_WAIT_RECLAIM)
   {
      string name=SetupObjName(id,"REC");
      datetime from=g_Scalp.pullbackTime;
      datetime to=from+PeriodSeconds(PERIOD_M1)*200;
      if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_TREND,0,from,g_Scalp.reclaimLevel,to,g_Scalp.reclaimLevel);
      else { ObjectMove(0,name,0,from,g_Scalp.reclaimLevel); ObjectMove(0,name,1,to,g_Scalp.reclaimLevel); }
      ObjectSetInteger(0,name,OBJPROP_COLOR,(g_Scalp.direction==BIAS_BULLISH?clrAqua:clrMagenta));
      ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      string lb=name+"_txt";
      if(ObjectFind(0,lb)<0) ObjectCreate(0,lb,OBJ_TEXT,0,from,g_Scalp.reclaimLevel);
      else ObjectMove(0,lb,0,from,g_Scalp.reclaimLevel);
      ObjectSetString(0,lb,OBJPROP_TEXT,StringFormat(" #%d RECLAIM %.2f",id,g_Scalp.reclaimLevel));
      ObjectSetInteger(0,lb,OBJPROP_COLOR,(g_Scalp.direction==BIAS_BULLISH?clrAqua:clrMagenta));
      ObjectSetInteger(0,lb,OBJPROP_FONTSIZE,7);
      ObjectSetInteger(0,lb,OBJPROP_BACK,true);
   }
}
void DeleteScalpVisuals()
{
   if(g_Scalp.id==0) return;
   string tags[3]={"PL","PH","REC"};
   for(int i=0;i<3;i++)
   {
      string n=SetupObjName((int)g_Scalp.id,tags[i]);
      ObjectDelete(0,n); ObjectDelete(0,n+"_txt");
   }
}
void AddEntryMarkerToQueue(string baseName)
{
   int n=ArraySize(g_EntryMarkerQueue);
   if(ArrayResize(g_EntryMarkerQueue,n+1)<=n) return;
   g_EntryMarkerQueue[n]=baseName;
   int cap=MathMax(1,100);
   while(ArraySize(g_EntryMarkerQueue)>cap)
   {
      string oldest=g_EntryMarkerQueue[0];
      ObjectDelete(0,oldest); ObjectDelete(0,oldest+"_txt");
      int cnt=ArraySize(g_EntryMarkerQueue);
      for(int i=0;i<cnt-1;i++) g_EntryMarkerQueue[i]=g_EntryMarkerQueue[i+1];
      ArrayResize(g_EntryMarkerQueue,cnt-1);
   }
}
void DrawEntryMarker(ENUM_ORDER_TYPE ot,double price,datetime time,int setupId)
{
   if(!DebugMode) return;
   string name="V13_Entry_"+TimeToString(time,TIME_DATE|TIME_MINUTES|TIME_SECONDS)+"_"+IntegerToString((int)(GetMicrosecondCount()%100000));
   int code=(ot==ORDER_TYPE_BUY)?233:234;
   color clr=(ot==ORDER_TYPE_BUY)?clrLime:clrRed;
   if(!ObjectCreate(0,name,OBJ_ARROW,0,time,price)) return;
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,code);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,3);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
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
//        DASHBOARD PANEL  (same performance architecture as V13)
//=========================================================================
#define PN_PREFIX "V13_P_"
#define PN_RPAD    14
#define PN_DP_DATE "DP_DATE_"
#define PN_DP_VAL  "DP_VAL_"
#define PN_RT_TIME "RT_TIME_"
#define PN_RT_TYPE "RT_TYPE_"
#define PN_RT_RES  "RT_RES_"
#define PN_RT_PL   "RT_PL_"
double PnCharW();
int    PnTextW(int chars);
void   PnLabel(string id,int x,int y,string text,color clr,int fontSize,string font="Consolas");
void   PnRect(string id,int x,int y,int w,int h,color border,color bg,int zorder,bool back);
void   PnSlotL(string role,int row,int x,string text,color clr);
void   PnSlotR(string role,int row,int x,string text,color clr);
void   PnHideExisting(string id);
int    PnMeasure(string text,int fontSize);
string PnFitPx(string text,int maxPx,int fontSize);
void   PnBoundedLabel(string id,int x,int y,string text,color clr, int maxRight,bool rightAlign,int fontSize);
string PnFit(string s,int maxChars);
void   DetermineStatus(string &status,color &clr);
void   PnRebuildHistory();

int  g_PnX=0, g_PnY=0, g_PnW=0, g_PnH=0;
int  g_PnRowH=0, g_PnFont=0;
int  g_PnLeftX=0, g_PnRightX=0, g_PnSepX=0, g_PnColW=0;
int  g_PnZ1=0, g_PnZ2=0, g_PnZ3=0, g_PnZ4=0;
int  g_PnZ1W=0, g_PnZ2W=0, g_PnZ3W=0, g_PnZ4W=0;
int  g_PnRZ1=0, g_PnRZ2=0;
int  g_PnRZ1W=0, g_PnRZ2W=0;
int  g_PnLeftCols=0, g_PnRightCols=0;
int  g_PnRightEdge=0;
int  g_PnTrXTime=0, g_PnTrXType=0, g_PnTrXRes=0, g_PnTrXPL=0;
int  g_PnDpXDate=0, g_PnDpXValue=0;
int  g_PnBodyTop=0, g_PnFooterY=0;
color clrPnBG      = C'8,12,24';
color clrPnBorder  = C'0,160,200';
color clrPnSection = C'0,200,235';
color clrPnSep     = C'0,80,110';
color clrPnLabel   = C'190,200,215';
color clrPnValue   = C'225,235,245';
color clrPnGood    = C'0,230,118';
color clrPnBad     = C'255,82,82';
color clrPnWarn    = C'255,193,7';
color clrPnDim     = C'110,125,145';
color clrPnTitle   = C'64,196,255';
color clrPanelBG     = C'8,12,24';
color clrPanelBorder = C'0,160,200';
color clrTitle       = C'64,196,255';
color clrNormal      = C'225,235,245';
color clrGood        = C'0,230,118';
color clrBad         = C'255,82,82';
color clrWarn        = C'255,193,7';
color clrDim         = C'110,125,145';
#define PN_MAX_ROWS 80
int    g_PnLeftUsed=0,  g_PnLeftPrev=0;
int    g_PnRightUsed=0, g_PnRightPrev=0;
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

string PnMoney(double v,bool sign) { if(sign) return StringFormat("%+.2f USD",v); return StringFormat("%.2f USD",v); }
string PnPct(double num,double den) { if(den==0.0) return "--"; return StringFormat("(%.2f%%)",100.0*num/den); }
color PnPLColor(double v) { if(v>0) return clrPnGood; if(v<0) return clrPnBad; return clrPnValue; }
string PnFit(string s,int maxChars) { if(maxChars<=0) return ""; if(StringLen(s)<=maxChars) return s; if(maxChars<=3) return StringSubstr(s,0,maxChars); return StringSubstr(s,0,maxChars-3)+"..."; }
string PnTFName(ENUM_TIMEFRAMES tf) { string s=EnumToString(tf); int p=StringFind(s,"PERIOD_"); if(p==0) s=StringSubstr(s,7); return s; }

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
   ObjectSetInteger(0,name,OBJPROP_BACK,back);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,zorder);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_COLOR,border);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
}
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
void PnEnsureChrome()
{
   PnRect("BG",     g_PnX,   g_PnY,   g_PnW, MathMax(40,g_PnH), clrPnBorder, clrPnBG,  0, false);
   PnRect("HdrLine",g_PnX+4, g_PnY+1, g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
   PnRect("Sep",    g_PnSepX,g_PnY+1, 1,       1, clrPnSep,    clrPnSep,    2, false);
   PnRect("FtLine", g_PnX+4, g_PnY+1, g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
}
int PnRowY(int row) { return g_PnBodyTop + row*g_PnRowH; }
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
void PnHideExisting(string id)
{
   string name=PN_PREFIX+id;
   if(ObjectFind(0,name)>=0) ObjectSetString(0,name,OBJPROP_TEXT," ");
}
void PnLeftBlankRow(int row)
{
   string sr=IntegerToString(row);
   PnHideExisting("LS_"+sr);
   PnHideExisting("L1_"+sr); PnHideExisting("V1_"+sr);
   PnHideExisting("L2_"+sr); PnHideExisting("V2_"+sr);
}
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
   PnHideExisting("DP_DATE_"+sr);
   PnHideExisting("DP_VAL_"+sr);
}
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
   if(keep!="DP_DATE") PnHideExisting("DP_DATE_"+sr);
   if(keep!="DP_VAL")  PnHideExisting("DP_VAL_"+sr);
}
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
   PnHideExisting("DP_DATE_"+sr); PnHideExisting("DP_VAL_"+sr);
}
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
      PnSlotL("V1",row,g_PnZ2,PnFit(v1,g_PnZ2W+g_PnZ3W+g_PnZ4W),c1);
      PnHideExisting("L2_"+IntegerToString(row));
      PnHideExisting("V2_"+IntegerToString(row));
   }
   PnHideExisting("LS_"+IntegerToString(row));
}
void PnRightKV(int row,string label,string value,color vClr)
{
   PnSlotR("RL",row,g_PnRZ1,PnFit(label,g_PnRZ1W),clrPnLabel);
   int maxChars=(int)MathFloor((double)(g_PnRightEdge-(g_PnRightX+g_PnRZ2))/PnCharW());
   PnSlotR("RV",row,g_PnRZ2,PnFit(value,MathMin(g_PnRZ2W,maxChars)),vClr);
   PnHideExisting("RS_"+IntegerToString(row));
   PnHideExisting("RT_TIME_"+IntegerToString(row));
   PnHideExisting("RT_TYPE_"+IntegerToString(row));
   PnHideExisting("RT_RES_" +IntegerToString(row));
   PnHideExisting("RT_PL_"  +IntegerToString(row));
   PnHideExisting("DP_DATE_"+IntegerToString(row));
   PnHideExisting("DP_VAL_" +IntegerToString(row));
}
double PnCharW() { return g_PnFont*0.62+0.85; }
int PnMeasure(string text,int fontSize) { if(text=="") return 0; uint w=0,h=0; TextSetFont("Consolas",-fontSize*10,FW_NORMAL,0); if(!TextGetSize(text,w,h)) return (int)MathRound(StringLen(text)*(fontSize*0.62+0.85)); return (int)w; }
string PnFitPx(string text,int maxPx,int fontSize) { if(maxPx<=0) return ""; if(PnMeasure(text,fontSize)<=maxPx) return text; string t=text; while(StringLen(t)>1){ t=StringSubstr(t,0,StringLen(t)-1); if(PnMeasure(t+"...",fontSize)<=maxPx) return t+"..."; } return ""; }
void PnBoundedLabel(string id,int x,int y,string text,color clr, int maxRight,bool rightAlign,int fontSize)
{
   string t=text;
   int w=PnMeasure(t,fontSize);
   if(rightAlign)
   {
      int avail=maxRight-x;
      if(w>avail) { t=PnFitPx(t,avail,fontSize); w=PnMeasure(t,fontSize); }
      int px=maxRight-w;
      if(px<x) px=x;
      PnLabel(id,px,y,t,clr,fontSize);
      return;
   }
   if(x+w>maxRight) t=PnFitPx(t,maxRight-x,fontSize);
   PnLabel(id,x,y,t,clr,fontSize);
}
int PnTextW(int chars) { return (int)MathRound(chars*PnCharW()); }
void PnHideSurplus()
{
   for(int r=g_PnLeftUsed;r<g_PnLeftPrev && r<PN_MAX_ROWS;r++) PnLeftBlankRow(r);
   for(int r=g_PnRightUsed;r<g_PnRightPrev && r<PN_MAX_ROWS;r++) PnRightBlankRow(r);
   g_PnLeftPrev =g_PnLeftUsed;
   g_PnRightPrev=g_PnRightUsed;
}
void PnRebuildHistory()
{
   for(int i=0;i<PN_DAYS;i++)  { g_PnDayUsed[i]=false; g_PnDayPL[i]=0; g_PnDayLabel[i]="--"; }
   g_PnDayCount=0; g_PnTrCount=0;
   g_PnTodayWinSum=0; g_PnTodayLossSum=0;
   g_PnTodayTrades=0; g_PnTodayWins=0; g_PnTodayLosses=0;
   g_PnConsWins=0;
   datetime now=TimeCurrent();
   MqlDateTime dt; TimeToStruct(now,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   datetime todayStart=StructToTime(dt);
   datetime from=todayStart-(datetime)((PN_DAYS-1)*86400);
   if(!HistorySelect(from,now+60)) return;
   int deals=HistoryDealsTotal();
   for(int d=0;d<PN_DAYS;d++)
   {
      datetime ds=todayStart-(datetime)(d*86400);
      MqlDateTime dd; TimeToStruct(ds,dd);
      g_PnDayLabel[d]=(d==0)?"Today":StringFormat("%02d/%02d",dd.mon,dd.day);
   }
   bool streakOpen=true;
   for(int i=deals-1;i>=0;i--)
   {
      ulong ticket=HistoryDealGetTicket(i); if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double pl = HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      datetime tt=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
      long dtype=HistoryDealGetInteger(ticket,DEAL_TYPE);
      string side=(dtype==DEAL_TYPE_SELL)?"Buy":"Sell";
      int dayIdx=(int)((long)(todayStart+86400-1-tt)/86400);
      if(tt>=todayStart) dayIdx=0;
      if(dayIdx>=0 && dayIdx<PN_DAYS) { g_PnDayPL[dayIdx]+=pl; g_PnDayUsed[dayIdx]=true; }
      if(tt>=todayStart){ g_PnTodayTrades++; if(pl>0){ g_PnTodayWins++; g_PnTodayWinSum+=pl; } else if(pl<0){ g_PnTodayLosses++; g_PnTodayLossSum+=pl; } }
      if(g_PnTrCount<PN_TRADES){ MqlDateTime td; TimeToStruct(tt,td); g_PnTrTime[g_PnTrCount]=StringFormat("%02d/%02d %02d:%02d",td.mon,td.day,td.hour,td.min); g_PnTrType[g_PnTrCount]=side; g_PnTrPL[g_PnTrCount]=pl; g_PnTrCount++; }
      if(streakOpen){ if(pl>0) g_PnConsWins++; else streakOpen=false; }
   }
   for(int d=0;d<PN_DAYS;d++) if(g_PnDayUsed[d]) g_PnDayCount++;
   g_PnHistoryLast=now; g_PnHistoryDirty=false;
}
void PnPushClosedTrade(datetime dtime,bool wasBuy,double profit)
{
   for(int i=PN_TRADES-1;i>0;i--){ g_PnTrTime[i]=g_PnTrTime[i-1]; g_PnTrType[i]=g_PnTrType[i-1]; g_PnTrPL[i]=g_PnTrPL[i-1]; }
   MqlDateTime td; TimeToStruct(dtime,td);
   g_PnTrTime[0]=StringFormat("%02d/%02d %02d:%02d",td.mon,td.day,td.hour,td.min);
   g_PnTrType[0]=(wasBuy?"Buy":"Sell");
   g_PnTrPL[0]=profit;
   if(g_PnTrCount<PN_TRADES) g_PnTrCount++;
   if(g_PnDayCount>0) g_PnDayPL[0]+=profit; else { g_PnDayPL[0]=profit; g_PnDayCount=1; }
   g_PnDayUsed[0]=true;
   g_PnTodayTrades++;
   if(profit>0){ g_PnTodayWins++; g_PnTodayWinSum+=profit; g_PnConsWins++; }
   else if(profit<0){ g_PnTodayLosses++; g_PnTodayLossSum+=profit; g_PnConsWins=0; }
}
void PnMaybeRebuildHistory()
{
   int every=MathMax(5,PanelHistoryRefreshSec);
   if(g_PnHistoryDirty || g_PnHistoryLast==0 || (long)TimeCurrent()-(long)g_PnHistoryLast>=every) PnRebuildHistory();
}
void PanelRefreshStateCache()
{
   g_PanelM5Bias=g_M5.bias;
   g_PanelSpreadOK=SpreadOK();
   g_PanelVolOK=VolOK();
   g_PanelInSession=InSession();
   g_PanelScalpActive=g_Scalp.active;
   g_PanelScalpState=g_Scalp.state;
   g_PanelReclaimLevel=g_Scalp.reclaimLevel;
   g_PanelPullbackDist=g_Scalp.pullbackDistance;
   g_PanelRequiredPullback=g_Scalp.requiredPullback;
   if(g_Scalp.active) g_PanelSetupAgeSec=(int)((long)TimeCurrent()-(long)g_Scalp.createdTime);
   else g_PanelSetupAgeSec=0;
   string why="";
   ENUM_BIAS probe=(g_M5.bias==BIAS_BEARISH)?BIAS_BEARISH:BIAS_BULLISH;
   if(g_M5.bias==BIAS_NEUTRAL) probe=BIAS_BULLISH;
   g_PanelEntryPermission=CheckEntryPermissions(probe,why);
   g_PanelBlockReason=why;
   if(g_Scalp.active)
   {
      if(g_Scalp.state==SCALP_WAIT_RECLAIM) g_PanelScalpStatus="WAIT_RECLAIM";
      else g_PanelScalpStatus="WAIT_PULLBACK";
   }
   else
   {
      if(g_M5.bias==BIAS_NEUTRAL) g_PanelScalpStatus="WAIT_PULLBACK (M5 NEUTRAL)";
      else g_PanelScalpStatus="WAIT_PULLBACK";
   }
}
bool UpdateChartVisualsIfDirty()
{
   bool changed=false;
   if(g_HTFVisualDirty){ DrawHTFVisuals(); g_HTFVisualDirty=false; changed=true; }
   if(g_SetupVisualDirty){ DrawScalpVisuals(); g_SetupVisualDirty=false; changed=true; }
   return changed;
}
void UpdateChartVisuals(){ g_HTFVisualDirty=true; g_SetupVisualDirty=true; UpdateChartVisualsIfDirty(); }
void PnHeaderStatus(string &txt,color &clr)
{
   if(!g_InitComplete) { txt="ERROR"; clr=clrPnBad; return; }
   if(g_HaltedFloat && CloseAllOnEmergencyLoss){ txt="EMERGENCY"; clr=clrPnBad; return; }
   if(g_HaltedFloat){ txt="BLOCKED"; clr=clrPnBad; return; }
   if(g_HaltedDaily || g_HaltedConsec){ txt="BLOCKED"; clr=clrPnBad; return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)){ txt="DISABLED"; clr=clrPnDim; return; }
   if(g_PanelOpenTradeCount>0){ txt="TRADING"; clr=clrPnGood; return; }
   if(!g_PanelInSession || !g_PanelSpreadOK || !g_PanelVolOK){ txt="WAITING"; clr=clrPnWarn; return; }
   if(g_M5.bias==BIAS_NEUTRAL){ txt="WAITING"; clr=clrPnWarn; return; }
   if(g_ConsLoss>0){ txt="RECOVERING"; clr=clrPnWarn; return; }
   txt="TRADING"; clr=clrPnGood;
}
void DetermineStatus(string &status,color &clr)
{
   if(!g_InitComplete){ status="INITIALIZING"; clr=clrPnDim; return; }
   if(g_HaltedDaily){ status="BLOCKED (daily loss halt)"; clr=clrPnBad; return; }
   if(g_HaltedConsec){ status="BLOCKED (loss streak halt)"; clr=clrPnBad; return; }
   if(g_HaltedFloat){ status="BLOCKED (floating loss halt)"; clr=clrPnBad; return; }
   int open=g_PanelOpenTradeCount;
   if(open>0){ status=StringFormat("ACTIVE (managing %d/%d trades)",open,g_MaxOpenTrades); clr=clrPnGood; return; }
   if(g_M5.bias==BIAS_NEUTRAL){ status="WAITING (M5 NEUTRAL)"; clr=clrPnWarn; return; }
   status=StringFormat("ACTIVE (scanning %s)", BiasToStr(g_M5.bias)); clr=clrPnGood;
}
string PnDetailStatus(color &clr)
{
   string s; color c; DetermineStatus(s,c); clr=c; return s;
}
void ClearPanelObjects()
{
   ObjectsDeleteAll(0,PN_PREFIX);
   g_PnLeftUsed=0; g_PnLeftPrev=0;
   g_PnRightUsed=0; g_PnRightPrev=0;
}

//=========================================================================
//                          THE DASHBOARD RENDERER
//=========================================================================
void RefreshPanel()
{
   if(!DebugMode){ ClearPanelObjects(); return; }
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
   int colChars=(int)MathFloor((double)(g_PnColW-pad)/PnCharW());
   if(colChars<40) colChars=40;
   g_PnLeftCols=colChars;
   double cw=PnCharW();
   int labelValueGap=10;
   int pairGap      =18;
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
   g_PnRightEdge = g_PnX + g_PnW - PN_RPAD;
   int rUsable   = g_PnRightEdge - g_PnRightX;
   if(rUsable<80) rUsable=80;
   g_PnRightCols=(int)MathMax(20,MathFloor((double)rUsable/cw));
   int rLabelPx=(int)MathRound(rUsable*0.44);
   g_PnRZ1=0;
   g_PnRZ2=rLabelPx+labelValueGap;
   g_PnRZ1W=(int)MathMax(8,MathFloor((double)(rLabelPx-labelValueGap)/cw));
   g_PnRZ2W=(int)MathMax(6,MathFloor((double)(rUsable-g_PnRZ2)/cw));
   int rtLeft =g_PnRightX;
   int rtWidth=g_PnRightEdge-rtLeft;
   g_PnTrXTime=rtLeft;
   g_PnTrXType=rtLeft+(int)MathRound(rtWidth*0.40);
   g_PnTrXRes =rtLeft+(int)MathRound(rtWidth*0.57);
   g_PnTrXPL  =rtLeft+(int)MathRound(rtWidth*0.76);
   g_PnDpXDate =g_PnRightX;
   g_PnDpXValue=g_PnRightX+(int)MathRound(rtWidth*0.30);
   int headerH=g_PnRowH+12;
   g_PnBodyTop=g_PnY+headerH+6;
   PnEnsureChrome();
   PnMaybeRebuildHistory();
   g_PnLeftUsed=0; g_PnRightUsed=0;
   double bal   =AccountInfoDouble(ACCOUNT_BALANCE);
   double eq    =AccountInfoDouble(ACCOUNT_EQUITY);
   double freeM =AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usedM =AccountInfoDouble(ACCOUNT_MARGIN);
   double mlevel=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   long   lev   =AccountInfoInteger(ACCOUNT_LEVERAGE);
   int    oTotal =g_PanelOpenTradeCount;
   int    oBuys  =g_PanelBuyCount;
   int    oSells =g_PanelSellCount;
   double oVol   =g_PanelOpenVolume;
   double oFloat =g_PanelFloatPL;
   double oAvgBuy =g_PanelAvgBuy;
   double oAvgSell=g_PanelAvgSell;
   int spreadPts=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   string stTxt; color stClr; PnHeaderStatus(stTxt,stClr);
   int totalRows=0;
   int hdrFont=g_PnFont+2;
   int hdrTextH=(int)MathRound(hdrFont*1.35);
   int hdrY=g_PnY+(headerH-hdrTextH)/2;
   if(hdrY<g_PnY+3) hdrY=g_PnY+3;
   string hdrName="XAUUSD_M5_M1_Scalper | v14.0";
   string hdrSym =_Symbol+"   "+PnTFName(_Period);
   int lampSize =6;
   int lampGap  =7;
   int lampRight=g_PnX+g_PnW-PN_RPAD;
   int lampX    =lampRight-lampSize;
   int nameEnd=g_PnLeftX+PnMeasure(hdrName,hdrFont);
   int statW  =PnMeasure(stTxt,hdrFont);
   int statX  =lampX-lampGap-statW;
   if(statX<nameEnd+20){ stTxt =PnFitPx(stTxt,lampX-lampGap-(nameEnd+20),hdrFont); statW =PnMeasure(stTxt,hdrFont); statX =lampX-lampGap-statW; }
   int symW=PnMeasure(hdrSym,hdrFont);
   int symX=g_PnX+(g_PnW-symW)/2;
   if(symX<nameEnd+16) symX=nameEnd+16;
   if(symX+symW>statX-16) symX=statX-16-symW;
   PnLabel("HdrName",g_PnLeftX,hdrY,hdrName,clrPnTitle,hdrFont);
   PnLabel("HdrSym", symX,    hdrY,hdrSym, clrPnValue,hdrFont);
   PnLabel("HdrStat",statX,   hdrY,stTxt,  stClr,     hdrFont);
   int lampY=hdrY+(int)MathRound(hdrFont*1.35*0.5)-lampSize/2;
   if(lampY<g_PnY+4) lampY=g_PnY+4;
   PnRect("HdrLamp",lampX,lampY,lampSize,lampSize,stClr,stClr,3,false);
   int r=0;
   // ---- A. ACCOUNT & RISK ----
   PnLeftSection(r++,"ACCOUNT & RISK");
   PnLeftKV2(r++,"Balance",   StringFormat("%.2f USD",bal), clrPnValue, "Lot Size", StringFormat("%.2f",g_LotSize), clrPnValue);
   PnLeftKV2(r++,"Equity",    StringFormat("%.2f USD",eq),  clrPnValue, "Max Trades",StringFormat("%d",g_MaxOpenTrades), clrPnValue);
   PnLeftKV2(r++,"Floating P/L", StringFormat("%+.2f USD",oFloat), PnPLColor(oFloat), "Target/Pos","ATR Trail", clrPnGood);
   PnLeftKV2(r++,"Free Margin",  StringFormat("%.2f USD",freeM), clrPnValue, "Spread", StringFormat("%d / %d pts",spreadPts,g_MaxSpreadPoints), (g_PanelSpreadOK?clrPnGood:clrPnBad));
   PnLeftKV2(r++,"Margin Level", (usedM>0?StringFormat("%.1f %%",mlevel):"--"), (usedM>0 && mlevel<200 ? clrPnWarn : clrPnValue), "Leverage",  StringFormat("1:%d",(int)lev), clrPnValue);
   PnLeftBlankRow(r++);
   // ---- B. TRADE SAFETY ----
   PnLeftSection(r++,"TRADE SAFETY");
   double curLoss=(oFloat<0)?-oFloat:0.0;
   PnLeftKV2(r++,"Max Float Loss", StringFormat("%.2f USD",g_MaxFloatingLossUSD), clrPnValue, "Current Loss", StringFormat("%.2f USD",curLoss), (curLoss>0?clrPnBad:clrPnGood));
   PnLeftKV2(r++,"Close All Emerg",(CloseAllOnEmergencyLoss?"YES":"NO"), (CloseAllOnEmergencyLoss?clrPnGood:clrPnWarn), "Daily Loss Lim", (g_DailyLossLimitPercent>0?StringFormat("%.2f %%",g_DailyLossLimitPercent):"OFF"), clrPnValue);
   PnLeftKV2(r++,"Consec Loss Lim",(g_ConsecutiveLossLimit>0?StringFormat("%d",g_ConsecutiveLossLimit):"OFF"), clrPnValue, "Consec Losses",  StringFormat("%d",g_ConsLoss), (g_ConsLoss>0?clrPnWarn:clrPnGood));
   string permTxt; color permClr;
   if(g_PanelEntryPermission) { permTxt="ALLOWED"; permClr=clrPnGood; } else { permTxt=g_PanelBlockReason; permClr=clrPnBad; }
   PnLeftKV2(r++,"Daily Status", (g_HaltedDaily?"HALTED":"NORMAL"), (g_HaltedDaily?clrPnBad:clrPnGood),"","",clrPnDim);
   PnLeftKV2(r++,"Trade Permit", permTxt, permClr, "","",clrPnDim);
   PnLeftBlankRow(r++);
   // ---- C. M5 REGIME ----
   PnLeftSection(r++,"M5 REGIME (BOSS)");
   {
      color h1C = (g_H1.bias==BIAS_BULLISH)?clrPnGood:(g_H1.bias==BIAS_BEARISH?clrPnBad:clrPnDim);
      color m15C= (g_M15.bias==BIAS_BULLISH)?clrPnGood:(g_M15.bias==BIAS_BEARISH?clrPnBad:clrPnDim);
      color m5C = (g_M5.bias==BIAS_BULLISH)?clrPnGood:(g_M5.bias==BIAS_BEARISH?clrPnBad:clrPnDim);
      string h1V = (g_H1.bias==BIAS_BULLISH?"BULLISH":(g_H1.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL"));
      string m15V=(g_M15.bias==BIAS_BULLISH?"BULLISH":(g_M15.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL"));
      string m5V = (g_M5.bias==BIAS_BULLISH?"BULLISH":(g_M5.bias==BIAS_BEARISH?"BEARISH":"NEUTRAL"));
      PnLeftKV2(r++,"H1  (info)", h1V, h1C, "", "", clrPnDim);
      PnLeftKV2(r++,"M15 (info)", m15V,m15C, "", "", clrPnDim);
      PnLeftKV2(r++,"M5  REGIME", m5V, m5C, "", "", clrPnDim);
      string m5Reason=g_M5.reason;
      if(StringLen(m5Reason)>40) m5Reason=StringSubstr(m5Reason,0,40);
      PnLeftKV2(r++,"M5 Reason", m5Reason, clrPnDim, "","",clrPnDim);
   }
   PnLeftBlankRow(r++);
   // ---- D. OPEN TRADES ----
   PnLeftSection(r++,"OPEN TRADES");
   PnLeftKV2(r++,"Total Trades",StringFormat("%d / %d",oTotal,g_MaxOpenTrades), (oTotal>0?clrPnGood:clrPnValue), "Total Volume",StringFormat("%.2f",oVol),clrPnValue);
   PnLeftKV2(r++,"Buy Trades",StringFormat("%d",oBuys),(oBuys>0?clrPnGood:clrPnValue), "Avg Buy",(oAvgBuy>0?DoubleToString(oAvgBuy,_Digits):"--"),clrPnValue);
   PnLeftKV2(r++,"Sell Trades",StringFormat("%d",oSells),(oSells>0?clrPnBad:clrPnValue), "Avg Sell",(oAvgSell>0?DoubleToString(oAvgSell,_Digits):"--"),clrPnValue);
   PnLeftKV2(r++,"Floating P/L",StringFormat("%+.2f USD",oFloat),PnPLColor(oFloat), "Mgmt","BE + ATR Trail",clrPnValue);
   // Per-position details if any open
   if(oTotal>0)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i); if(t==0) continue;
         if(!PositionIsMine()) continue;
         double e=PositionGetDouble(POSITION_PRICE_OPEN);
         double sl=PositionGetDouble(POSITION_SL);
         double atrCur=AtrVal(g_ATR_M1,1);
         int ti=FindTrack(t);
         string beTxt="--", trailTxt="--";
         if(ti>=0) { beTxt=g_Tracks[ti].breakEvenApplied?"DONE":"ARMED"; trailTxt=g_Tracks[ti].trailActive?"ACTIVE":"WAIT"; }
         string posType=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?"BUY":"SELL";
         PnLeftKV2(r++,posType+" Entry",DoubleToString(e,_Digits),clrPnValue, "SL",DoubleToString(sl,_Digits),clrPnWarn);
         PnLeftKV2(r++,"BE Status",beTxt,(beTxt=="DONE"?clrPnGood:clrPnWarn), "Trail",trailTxt,(trailTxt=="ACTIVE"?clrPnGood:clrPnDim));
         PnLeftKV2(r++,"Cur ATR",StringFormat("%.2f",atrCur),clrPnValue, "","",clrPnDim);
         break; // show only first position to keep panel compact
      }
   }
   PnLeftBlankRow(r++);
   // ---- E. SCALP SETUP STATUS ----
   PnLeftSection(r++,"SCALP SETUP (M1)");
   {
      if(!g_PanelScalpActive)
      {
         PnLeftKV2(r++,"State",g_PanelScalpStatus, (g_M5.bias==BIAS_NEUTRAL?clrPnWarn:clrPnGood), "","",clrPnDim);
         double atr=AtrVal(g_ATR_M1,1);
         double req=(atr>0)?atr*g_M1PullbackATR:0;
         PnLeftKV2(r++,"Required Pullback",StringFormat("%.2f (ATR %.2f x %.2f)",req,atr,g_M1PullbackATR),clrPnValue,"","",clrPnDim);
         PnLeftKV2(r++,"Pullback Dist", StringFormat("%.2f",g_PanelPullbackDist),clrPnDim,"","",clrPnDim);
         PnLeftKV2(r++,"Reclaim Level","--",clrPnDim,"","",clrPnDim);
         PnLeftKV2(r++,"Setup Age","--",clrPnDim,"","",clrPnDim);
      }
      else
      {
         string dirS=BiasToStr(g_Scalp.direction);
         color dirC=(g_Scalp.direction==BIAS_BULLISH)?clrPnGood:clrPnBad;
         PnLeftKV2(r++,"Direction",dirS,dirC, "State",ScalpStateToStr(g_PanelScalpState),clrPnWarn);
         PnLeftKV2(r++,"Pullback Dist",StringFormat("%.2f",g_PanelPullbackDist),clrPnValue, "Required",StringFormat("%.2f",g_PanelRequiredPullback),clrPnValue);
         string invalStr=(g_Scalp.direction==BIAS_BULLISH)?DoubleToString(g_Scalp.pullbackLow,_Digits):DoubleToString(g_Scalp.pullbackHigh,_Digits);
         PnLeftKV2(r++,"Invalidation",invalStr,clrPnWarn, "","",clrPnDim);
         PnLeftKV2(r++,"Reclaim Level",DoubleToString(g_PanelReclaimLevel,_Digits),clrPnWarn, "","",clrPnDim);
         string ageStr=StringFormat("%ds / %dmin",g_PanelSetupAgeSec,g_ScalpSetupExpiryMin);
         PnLeftKV2(r++,"Setup Age",ageStr, (g_PanelSetupAgeSec>g_ScalpSetupExpiryMin*30?clrPnWarn:clrPnValue), "Armed",g_Scalp.crossActive?"YES":"NO", g_Scalp.crossActive?clrPnGood:clrPnDim);
         string expInfo=StringFormat("expires in %ds", g_ScalpSetupExpiryMin*60 - g_PanelSetupAgeSec);
         PnLeftKV2(r++,"Expiry",expInfo,clrPnDim,"","",clrPnDim);
      }
   }
   PnLeftBlankRow(r++);
   // ---- F. TODAY'S REPORT ----
   PnLeftSection(r++,"TODAY'S REPORT");
   {
      double todayNet=g_PnTodayWinSum+g_PnTodayLossSum;
      double wr=(g_PnTodayWins+g_PnTodayLosses>0)?100.0*g_PnTodayWins/(g_PnTodayWins+g_PnTodayLosses):0.0;
      string ddTxt=(g_PnDayPeakEquity>0)?StringFormat("%.2f %%",g_PnDayDDPct):"--";
      PnLeftKV2(r++,"Trades",StringFormat("%d",g_PnTodayTrades),clrPnValue,"","",clrPnDim);
      PnLeftKV2(r++,"Win Rate",(g_PnTodayWins+g_PnTodayLosses>0?StringFormat("%.2f %%",wr):"--"), (wr>=50?clrPnGood:clrPnWarn),"","",clrPnDim);
      PnLeftKV2(r++,"Daily P/L",StringFormat("%+.2f USD",todayNet), PnPLColor(todayNet),"","",clrPnDim);
      PnLeftKV2(r++,"Total Profit",StringFormat("%.2f USD",g_PnTodayWinSum), clrPnGood,"","",clrPnDim);
      PnLeftKV2(r++,"Total Loss",StringFormat("%.2f USD",g_PnTodayLossSum), (g_PnTodayLossSum<0?clrPnBad:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Consec Wins",StringFormat("%d",g_PnConsWins), (g_PnConsWins>0?clrPnGood:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Consec Losses",StringFormat("%d",g_ConsLoss), (g_ConsLoss>0?clrPnBad:clrPnValue),"","",clrPnDim);
      PnLeftKV2(r++,"Max Drawdown",ddTxt, (g_PnDayDDPct>0?clrPnWarn:clrPnValue),"","",clrPnDim);
      color dsClr; string dsTxt=PnDetailStatus(dsClr); color mapped=(dsClr==clrPnBad)?clrPnBad:dsClr;
      PnLeftKV2(r++,"EA Status",dsTxt,mapped,"","",clrPnDim);
   }
   int rr=0;
   PnRightSection(rr++,"MAX FLOATING LOSS");
   {
      double lim=g_MaxFloatingLossUSD;
      double cur=(oFloat<0)?-oFloat:0.0;
      string curTxt,limTxt; color curClr;
      if(oFloat>=0){ curTxt=StringFormat("%.2f USD  (0.00%%)",0.0); curClr=clrPnGood; }
      else{ curTxt=StringFormat("%.2f USD  %s",cur,PnPct(cur,lim)); double ratio=(lim>0)?cur/lim:0; curClr=(ratio>=0.75)?clrPnBad:(ratio>=0.4)?clrPnWarn:clrPnValue; }
      limTxt=(lim>0)?StringFormat("%.2f USD  (100.00%%)",lim):"DISABLED";
      string emTxt; color emClr;
      if(g_HaltedFloat){ emTxt="TRIGGERED"; emClr=clrPnBad; } else if(lim<=0){ emTxt="OFF"; emClr=clrPnDim; } else if(cur>=lim*0.75){ emTxt="WARNING"; emClr=clrPnWarn; } else { emTxt="NORMAL"; emClr=clrPnGood; }
      PnRightKV(rr++,"Current",curTxt,curClr);
      PnRightKV(rr++,"Limit",limTxt,clrPnValue);
      PnRightKV(rr++,"Float P/L",StringFormat("%+.2f USD",oFloat),PnPLColor(oFloat));
      PnRightKV(rr++,"Status",emTxt,emClr);
      PnRightKV(rr++,"Close All",(CloseAllOnEmergencyLoss?"ENABLED":"DISABLED"), (CloseAllOnEmergencyLoss?clrPnGood:clrPnWarn));
   }
   PnRightBlankRow(rr++);
   PnRightSection(rr++,"DAILY PROFIT");
   {
      for(int d=0;d<PN_DAYS;d++)
      {
         string sr=IntegerToString(rr);
         string lbl=(g_PnDayLabel[d]!="")?g_PnDayLabel[d]:"--";
         PnBoundedLabel(PN_DP_DATE+sr,g_PnDpXDate,PnRowY(rr),lbl,clrPnLabel, g_PnDpXValue-6,false,g_PnFont);
         string vTxt; color vClr;
         if(!g_PnDayUsed[d]){ vTxt="--"; vClr=clrPnDim; }
         else{ double v=g_PnDayPL[d]; double refBal=bal-v; string full=StringFormat("%+.2f USD",v); if(refBal>0.0){ string withPct=full+StringFormat("  (%.2f%%)",100.0*v/refBal); if(PnMeasure(withPct,g_PnFont)<=g_PnRightEdge-g_PnDpXValue) full=withPct; } vTxt=full; vClr=PnPLColor(v); }
         PnBoundedLabel(PN_DP_VAL+sr,g_PnDpXValue,PnRowY(rr),vTxt,vClr, g_PnRightEdge,true,g_PnFont);
         if(rr+1>g_PnRightUsed) g_PnRightUsed=rr+1;
         PnHideExisting("RS_"+sr); PnHideExisting("RL_"+sr); PnHideExisting("RV_"+sr);
         PnHideExisting("RT_TIME_"+sr); PnHideExisting("RT_TYPE_"+sr); PnHideExisting("RT_RES_"+sr); PnHideExisting("RT_PL_"+sr);
         rr++;
      }
   }
   PnRightBlankRow(rr++);
   PnRightSection(rr++,"RECENT TRADES");
   {
      string hr=IntegerToString(rr);
      PnBoundedLabel(PN_RT_TIME+hr,g_PnTrXTime,PnRowY(rr),"Time",  clrPnDim,g_PnTrXType-6,false,g_PnFont);
      PnBoundedLabel(PN_RT_TYPE+hr,g_PnTrXType,PnRowY(rr),"Type",  clrPnDim,g_PnTrXRes -6,false,g_PnFont);
      PnBoundedLabel(PN_RT_RES +hr,g_PnTrXRes, PnRowY(rr),"Result",clrPnDim,g_PnTrXPL  -6,false,g_PnFont);
      PnBoundedLabel(PN_RT_PL  +hr,g_PnTrXPL,  PnRowY(rr),"P/L",   clrPnDim,g_PnRightEdge,true,g_PnFont);
      if(rr+1>g_PnRightUsed) g_PnRightUsed=rr+1;
      PnHideExisting("RS_"+hr); PnHideExisting("RL_"+hr); PnHideExisting("RV_"+hr); PnHideExisting("RD_"+hr);
      rr++;
      if(g_PnTrCount<=0){ PnSlotR("RL",rr,g_PnRZ1,"No closed trades yet",clrPnDim); PnRightBlankRowExcept(rr,"RL"); rr++; }
      else{
         for(int t=0;t<g_PnTrCount;t++){ string dr=IntegerToString(rr); bool win=(g_PnTrPL[t]>=0); color wClr=(win?clrPnGood:clrPnBad);
            PnBoundedLabel(PN_RT_TIME+dr,g_PnTrXTime,PnRowY(rr), g_PnTrTime[t],clrPnValue,g_PnTrXType-6,false,g_PnFont);
            PnBoundedLabel(PN_RT_TYPE+dr,g_PnTrXType,PnRowY(rr), g_PnTrType[t],clrPnValue,g_PnTrXRes-6,false,g_PnFont);
            PnBoundedLabel(PN_RT_RES +dr,g_PnTrXRes, PnRowY(rr), (win?"WIN":"LOSS"),wClr,g_PnTrXPL-6,false,g_PnFont);
            PnBoundedLabel(PN_RT_PL  +dr,g_PnTrXPL,  PnRowY(rr), StringFormat("%+.2f",g_PnTrPL[t]),wClr, g_PnRightEdge,true,g_PnFont);
            if(rr+1>g_PnRightUsed) g_PnRightUsed=rr+1;
            PnHideExisting("RS_"+dr); PnHideExisting("RL_"+dr); PnHideExisting("RV_"+dr); PnHideExisting("RD_"+dr);
            rr++;
         }
      }
   }
   PnRightBlankRow(rr++);
   PnRightSection(rr++,"SYSTEM STATS");
   {
      PnRightKV(rr++,"M5 Bull/Bear",StringFormat("%d / %d",g_M5.cntBull,g_M5.cntBear),clrPnValue);
      PnRightKV(rr++,"Pullbacks",StringFormat("%d",g_Cnt_PullbackDetected),clrPnValue);
      PnRightKV(rr++,"Reclaims",StringFormat("%d",g_Cnt_ReclaimArmed),clrPnValue);
      PnRightKV(rr++,"Breakouts",StringFormat("%d",g_Cnt_Breakouts),clrPnValue);
      PnRightKV(rr++,"Expired",StringFormat("%d",g_Cnt_SetupsExpired), (g_Cnt_SetupsExpired>0?clrPnWarn:clrPnValue));
      PnRightKV(rr++,"Invalid M5",StringFormat("%d",g_Cnt_SetupsInvalidatedM5),clrPnValue);
      PnRightKV(rr++,"Attempts",StringFormat("%d",g_Cnt_EntryAttempts),clrPnValue);
      PnRightKV(rr++,"Executed",StringFormat("%d",g_Cnt_EntryExecuted), (g_Cnt_EntryExecuted>0?clrPnGood:clrPnValue));
      PnRightKV(rr++,"Blocked",StringFormat("%d",g_Cnt_EntryBlocked), (g_Cnt_EntryBlocked>0?clrPnWarn:clrPnValue));
      PnRightKV(rr++,"Failed",StringFormat("%d",g_Cnt_EntryFailed), (g_Cnt_EntryFailed>0?clrPnBad:clrPnValue));
      int rejTotal=g_Cnt_RejectLot+g_Cnt_RejectStops+g_Cnt_RejectMargin+g_Cnt_RejectFilling+g_Cnt_RejectBroker+g_Cnt_RejectOther;
      PnRightKV(rr++,"Rejected",StringFormat("%d",rejTotal), (rejTotal>0?clrPnBad:clrPnGood));
      if(rejTotal>0){ PnRightKV(rr++,"Rej L/S/M",StringFormat("%d / %d / %d",g_Cnt_RejectLot,g_Cnt_RejectStops,g_Cnt_RejectMargin),clrPnBad); PnRightKV(rr++,"Rej F/B/O",StringFormat("%d / %d / %d",g_Cnt_RejectFilling,g_Cnt_RejectBroker,g_Cnt_RejectOther),clrPnBad); }
      PnRightKV(rr++,"Long / Short",StringFormat("%d / %d",g_LongTrades,g_ShortTrades),clrPnValue);
      double avgHold=0; // not tracked as money-target hold, keep placeholder
      PnRightKV(rr++,"BreakEvens",StringFormat("%d",g_Cnt_BreakEven),(g_Cnt_BreakEven>0?clrPnGood:clrPnValue));
      PnRightKV(rr++,"Trail Mods",StringFormat("%d",g_Cnt_TrailingMods),(g_Cnt_TrailingMods>0?clrPnGood:clrPnValue));
   }
   totalRows=MathMax(g_PnLeftUsed,g_PnRightUsed);
   int bodyH  =totalRows*g_PnRowH;
   int footerH=g_PnRowH+8;
   g_PnH=(g_PnBodyTop-g_PnY)+bodyH+6+footerH;
   if(PanelMinHeight>0 && g_PnH<PanelMinHeight) g_PnH=PanelMinHeight;
   g_PnFooterY=g_PnY+g_PnH-footerH;
   PnRect("BG",     g_PnX,    g_PnY,          g_PnW,   g_PnH, clrPnBorder, clrPnBG, 0, false);
   PnRect("HdrLine",g_PnX+4,  g_PnY+headerH,  g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
   PnRect("Sep",    g_PnSepX, g_PnY+headerH+2, 1, MathMax(1,g_PnFooterY-(g_PnY+headerH+4)), clrPnSep,    clrPnSep,    2, false);
   PnRect("FtLine", g_PnX+4,  g_PnFooterY,    g_PnW-8, 1, clrPnBorder, clrPnBorder, 2, false);
   {
      datetime lt=TimeLocal(), st=TimeCurrent();
      datetime m1open=iTime(_Symbol,PERIOD_M1,0);
      int secIn=(m1open>0)?(int)((long)st-(long)m1open):0;
      if(secIn<0) secIn=0; if(secIn>59) secIn=59;
      string nextAction=StringFormat("Next: M1 Setup Check (%d/60s)",secIn);
      bool connected=(bool)TerminalInfoInteger(TERMINAL_CONNECTED);
      string conn=connected?"CONNECTED":"NO CONNECTION";
      color  connClr=connected?clrPnGood:clrPnBad;
      int fy=g_PnFooterY+6;
      string f1=TimeToString(lt,TIME_DATE|TIME_SECONDS);
      string f2="|  "+nextAction;
      string f3="|  Server: "+TimeToString(st,TIME_SECONDS);
      string f4="|  "+AccountInfoString(ACCOUNT_SERVER);
      string f5="|  "+conn;
      int fx=g_PnLeftX;
      PnLabel("Ft1",fx,fy,f1,clrPnValue,g_PnFont); fx+=PnTextW(StringLen(f1)+3);
      PnLabel("Ft2",fx,fy,f2,clrPnWarn, g_PnFont); fx+=PnTextW(StringLen(f2)+3);
      PnLabel("Ft3",fx,fy,f3,clrPnValue,g_PnFont); fx+=PnTextW(StringLen(f3)+3);
      PnLabel("Ft4",fx,fy,f4,clrPnLabel,g_PnFont); fx+=PnTextW(StringLen(f4)+3);
      int f5x=MathMin(fx,g_PnRightEdge-PnTextW(StringLen(f5)));
      PnLabel("Ft5",f5x,fy,f5,connClr,g_PnFont);
   }
   PnHideSurplus();
}
//+------------------------------------------------------------------+
