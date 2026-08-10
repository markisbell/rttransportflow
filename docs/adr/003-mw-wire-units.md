# ADR-003 — Wire power unit: MW

Status: accepted · Phase: P0 · Date: 2026-08-10

## Context

The distribution-scale siblings (rtpowerflow/rtheatflow/rtwaterflow) speak kW
on the gamebridge wire — household loads and rooftop PV live at kW scale.
This game dispatches 1600 MW units and 15 GW load centers; kW values would
carry 9–10 digits on every frame.

## Decision

Contract v2 (`network_kind: "transmission"`) uses **MW** for every power
value on the wire and in the engine (with MVA/Hz/s/MJ; per-unit only for
droop R and load damping D — PHYSICS §2.2). The handshake advertises it:
`units: {power: "MW"}`.

This is a deliberate, documented deviation from the family; v2 is a breaking
contract generation anyway (variable float `dt_s`, trajectory block).

## Consequences

- Engine, catalogs, scenario files, and game model all share one unit — no
  conversion layer, no multi-base bug farm.
- Any future infrastruct convergence must handle the kW/MW split at the
  CosimBridge (decision ledger, CLAUDE.md §4 entry 11).
