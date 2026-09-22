# V14 - Simple M5+M1 Scalper - Change Summary

## Old strategy removed
- Removed entire M1 `A/B/C/Trigger` state machine (`WAIT_B/WAIT_C/WAIT_TRIGGER/WAIT_BREAK`) and all HTF-parent anchoring (`parentAnchored`, `GetBullishParentLeg()`, `ReplayM1PivotsIntoParentSetup()` etc).
- Removed obsolete counters/state that only served the old HTF-parent model.
- Removed `H1+M15+M5` unanimous `AlignedBias()` hard filter - H1/M15 remain calculated/displayed but never block scalps.
- Completely removed M30 Support/Resistance module: no zone building, no break counters, no `SRBlocking`, no giant `V13_SR_` rectangles. `OnInit`/`OnDeinit` now sweep `V13_SR_*` to clean orphan objects.
- Removed fixed USD profit-target close (`ProfitTargetUSD` / `+0.50` money target) and associated money-target statistics.
- Removed dead inputs: `UseH1/UseM15/UseM5/UseM1`, `UseSRFilter`, `SRLookbackHours`, `SRPivotWidth`, `SRZoneATRMult` etc, `ProfitTargetUSD`, `MaxActiveSetups`, `SetupExpiryMinutes`, `MaxEntryMarkers` (old).

## New M5+M1 scalper entry
**M5 is boss.** Causal price-action pivot engine (`UpdateTFStructure` with `PivotSize`/`ATRPeriod`/`StructureExpansion`) determines regime: `BULLISH` allows BUY scalps, `BEARISH` allows SELL, `NEUTRAL` creates nothing. M5 flip instantly invalidates a waiting opposite-direction scalp.

**M1 state machine simplified to 2 states:**
`SCALP_WAIT_PULLBACK` -> `SCALP_WAIT_RECLAIM`

- Event-driven on `new M1 bar` only (not every tick).
- Single fresh setup = one entry episode, consumed after one reclaim attempt (executed / blocked / rejected) - never machine-guns same pullback.

## Pullback calculation
Inputs: `M1PullbackATR=0.40`, `PullbackLookbackBars=10`
- `required = AtrVal(M1,1) * M1PullbackATR` (closed M1 ATR, causal).
- `recentHigh = max High[1..PullbackLookbackBars]` (BUY) / `recentLow = min Low[1..]` (SELL) - bounded scan.
- `pullbackLow = min Low[1..hiIdx+1]` since the high (temporal order ensured); `pullbackHigh = max High[1..loIdx+1]` for SELL.
- `distance = recentHigh - pullbackLow` (or `pullbackHigh - recentLow`).
- If `distance >= required` -> qualify, store `pullbackLow`/`pullbackHigh` as **structural invalidation point**, transition to `WAIT_RECLAIM`.

## Reclaim calculation
Input: `ReclaimLookbackBars=2`
- `reclaim BUY = max High[1..ReclaimLookbackBars]` of **completed** M1 candles.
- `reclaim SELL = min Low[1..ReclaimLookbackBars]`.
- Level re-computed each new M1 bar while waiting, never uses forming candle (shift 0).
- Armed logic: BUY requires `Ask <= level` first (armed), then `Ask > level` fresh cross; SELL mirrored with `Bid`. When level moves, armed resets to `price on correct side` to prevent retro entries.

## Other entry rules
- `ScalpSetupExpiryMin=15` - stale setups reset, no 6-hour reuse.
- No hedging: `HasOpenPositionInDirection` blocks opposite entry while a directional position is open.
- Permissions: init complete, daily loss, consecutive loss, floating loss, `MaxOpenTrades`, session, spread (`MaxSpreadPoints`), volatility (`VolatilityLookback`/`VolatilitySpikeLimit`). Removed HTF unanimous + SR permissions.

## Initial invalidation SL
Inputs: `InitialSLBufferATR=0.15`
- `BUY SL = pullbackLow - entryATR*buffer`, `SELL SL = pullbackHigh + entryATR*buffer` (entryATR = `AtrVal(M1,1)` at entry, closed).
- Normalized to `_Digits`, adjusted for `SYMBOL_TRADE_STOPS_LEVEL` minimum distance, validated `SL` on correct side of entry. No `SL=0` anymore; `TP=0`, `SL` sent with the deal and logged.
- If broker rejects stops, logs reason and aborts.

## Break-even
Inputs: `BreakEvenTriggerATR=0.60`, `BreakEvenOffsetATR=0.00`
- Snapshot `entryATR` stored in `PosTrack`.
- BUY: when `Bid - entry >= entryATR*Trigger` move `SL -> entry + entryATR*Offset`; SELL mirrored.
- Never moves backward (`ModifyPositionSL` enforces monotonic protective direction, stops-level, and `SL` not crossing current price).

## ATR trailing
Inputs: `TrailStartATR=0.80`, `TrailDistanceATR=1.00`, `TrailStepATR=0.10`
- Activates when `price - entry >= entryATR*TrailStartATR`.
- Uses **current closed** `AtrVal(M1,1)` for distance: `BUY desired = Bid - curATR*TrailDistance`, `SELL = Ask + curATR*TrailDistance`.
- Only moves if `|desired - curSL| >= curATR*TrailStepATR` (plus `point*10` floor and stops-level) and is strictly more protective (BUY only up, SELL only down). Never loosens.
- Break-even runs first; trail may later move beyond break-even.

## What was removed
M30 SR, HTF-parent A/B logic, fixed `$` target, money-target stats, obsolete chart rectangles (`V13_SR_*`) and `A/B/C/Trigger` visuals/panel rows.

## Confirmation account safety remains
- `DailyLossLimitPercent`, `ConsecutiveLossLimit`, `MaxFloatingLossUSD` + `CloseAllOnEmergencyLoss` unchanged.
- `MaxSpreadPoints`, `VolatilitySpikeLimit`, `TradingStartHour/EndHour` unchanged.
- Management (`ManageOpenPositions` with BE/trail/emergency) runs **every tick**, even outside session; entry setup stays new-bar driven for performance.
- Execution retains lot normalization, volume step, margin check, filling-mode fallback (FOK->IOC->RETURN), retcode handling, `MagicNumber`, trade comments `V14#id`, slippage, broker stops-level validation.
- Dashboard performance architecture preserved (dark opaque panel, throttled timer, dirty flags, event-driven visuals, single `ChartRedraw` per refresh, `HistorySelect` cached). Panel fields replaced: `M5 Regime` (H1/M15 info only), `Scalp Setup` (pullback distance/required/reclaim/age/armed), `Open Trade` (entry/SL/BE/Trail/cur ATR), `System Stats` (pullbacks/reclaims/BE/trails/rejects).

## No violations
- Only ATR used, no EMA/RSI/MACD etc.
- No lookahead: all regime/pullback/reclaim use completed bars (`shift>=1`), live `Ask/Bid` only for cross + SL management.
- Bounded scans (`<=50` bars), no per-tick full history scans.
- No hedging/grid/martingale/averaging/pyramiding.
- EA restart reconstructs `PosTrack` from live positions (`entryATR` fallback to current ATR) and continues BE/trail.

