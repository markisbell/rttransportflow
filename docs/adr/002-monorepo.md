# ADR-002 — One monorepo: backend + game

Status: accepted · Phase: P0 · Date: 2026-08-10

## Context

infrastruct coordinates three pre-existing, independently versioned backends —
submodules were the right call there. rttransportflow has exactly one backend,
born for this game, with a co-evolving wire contract (v2 freezes only at P4).

## Decision

One repository: backend under `src/rttransportflow/` (Python, src-layout,
own pyproject/console script/Docker stack), game under `game/` (Godot 4).
Contract schema + backend + game client + golden fixtures change atomically
in one commit.

The backend stays standalone-runnable **by convention, not repo boundary**:
internal accelerated-tick clock, REST+WS surface, Grafana visualization; it
imports nothing from `game/`. If it is ever needed as an infrastruct sidecar,
`git subtree split` extracts it.

## Consequences

- One roadmap, one CI, one agent workflow; no submodule-pin dance while the
  contract moves.
- Discipline required: no `game/` imports in `src/` (reviewed at phase gates).
