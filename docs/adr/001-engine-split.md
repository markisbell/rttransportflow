# ADR-001 — Engine split: quasi-static AC PF + per-island frequency dynamics

Status: accepted · Phase: P0 · Date: 2026-08-10

## Context

The game needs (a) network truth — flows, voltages, reactive power, losses,
loadings — and (b) frequency dynamics the player can feel (RoCoF, nadir,
governor response) at 10 ms–10 s timescales. Full electromechanical network
simulation (per-machine rotor angles) is neither needed for the pedagogical
target nor affordable in Python.

## Decision

Two coupled layers in one engine (authority: docs/PHYSICS.md):

1. **pandapower AC Newton-Raphson** solves the network quasi-statically at
   scheduled instants (1 s ALERT / 30 s CALM / on every event).
2. A **per-island center-of-inertia swing equation + per-plant
   governor/turbine ODEs** (struct-of-arrays NumPy, exact-exponential lags,
   semi-implicit swing) integrates frequency at fixed internal ticks
   (10 ms ALERT / 250 ms CALM) between PF instants, coupled through the
   power-balance ledger (PHYSICS §2.5).

Uniform frequency per island; no rotor angles, no EMT, no AVR dynamics —
the honesty section (PHYSICS §2.1) is part of the contract.

## Consequences

- PF dominates the compute budget (ADR-004); the dynamics layer is nearly
  free. `pf_interval_calm` is the tuning knob.
- Islanding, cascades, and UFLS emerge from the coupling without special
  code; inter-area oscillations are out of scope by construction.
