"""H2 chain (PHYSICS §2.8, numbers PARAMETERS §1.6/§1.13/§1.14).

Stores are pure energy tanks with rate limits: electrolyzers inject
`ṁ = 1000·P/η_spec(P)` kg/h (η_spec linear 48 kWh/kg @ 20 % → 52 @ 100 %),
the compressor charges 2.5 kWh_el/kg as an auxiliary electric load on the
store's island; H2-fired plants draw `ṁ = 1000·y/(η(y)·33.33)` kg/h.
A store at its 5 % cushion floor derates its plants to the withdrawal limit
and — when even that is gone — starves them: forced ramp-out, unavailable
until the level recovers above floor + 2 % (the engine owns this because it
gates primary-reserve availability mid-event).
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from ..snapshot import parse_floats, repr_floats

LHV_KWH_PER_KG = 33.33
ETA_SPEC_LOW = 48.0  # kWh/kg at 20 % load
ETA_SPEC_HIGH = 52.0  # kWh/kg at 100 %
COMPRESSOR_KWH_PER_KG = 2.5
FLOOR_FRAC = 0.05
RECOVER_FRAC = 0.07  # floor + 2 %


@dataclass
class H2Stores:
    ids: list[str] = field(default_factory=list)
    island: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))
    capacity_kg: np.ndarray = field(default_factory=lambda: np.zeros(0))
    level_kg: np.ndarray = field(default_factory=lambda: np.zeros(0))
    inject_max_kgph: np.ndarray = field(default_factory=lambda: np.zeros(0))
    withdraw_max_kgph: np.ndarray = field(default_factory=lambda: np.zeros(0))
    # meters
    injected_kg: np.ndarray = field(default_factory=lambda: np.zeros(0))
    withdrawn_kg: np.ndarray = field(default_factory=lambda: np.zeros(0))
    compressor_mwh: np.ndarray = field(default_factory=lambda: np.zeros(0))

    @property
    def n(self) -> int:
        return len(self.ids)

    def row(self, store_id: str) -> int:
        return self.ids.index(store_id)

    def floor_kg(self) -> np.ndarray:
        return FLOOR_FRAC * self.capacity_kg

    @staticmethod
    def eta_spec_kwh_per_kg(p_frac: np.ndarray) -> np.ndarray:
        frac = np.clip((p_frac - 0.2) / 0.8, 0.0, 1.0)
        return ETA_SPEC_LOW + (ETA_SPEC_HIGH - ETA_SPEC_LOW) * frac

    def inject_from_electrolyzers(self, store_rows: np.ndarray, p_mw: np.ndarray,
                                  p_max_mw: np.ndarray, dt_s: float,
                                  n_islands: int) -> np.ndarray:
        """Produce H2 from electrolyzer power; returns per-island compressor
        auxiliary load [MW] (an extra electric demand)."""
        aux = np.zeros(n_islands)
        if self.n == 0 or len(store_rows) == 0:
            return aux
        p_frac = np.divide(p_mw, np.maximum(p_max_mw, 1e-9))
        spec = self.eta_spec_kwh_per_kg(p_frac)
        prod_kgph = 1000.0 * p_mw / spec
        dt_h = dt_s / 3600.0
        for i, row in enumerate(store_rows):
            if row < 0:
                continue
            space = max(self.capacity_kg[row] - self.level_kg[row], 0.0)
            take_kg = min(prod_kgph[i] * dt_h,
                          self.inject_max_kgph[row] * dt_h, space)
            self.level_kg[row] += take_kg
            self.injected_kg[row] += take_kg
            comp_mwh = take_kg * COMPRESSOR_KWH_PER_KG / 1000.0
            self.compressor_mwh[row] += comp_mwh
            if dt_h > 0:
                aux[self.island[row]] += comp_mwh / dt_h
        return aux

    def draw_for_plants(self, store_rows: np.ndarray, y_mw: np.ndarray,
                        eta: np.ndarray, dt_s: float) -> np.ndarray:
        """Withdraw fuel for H2-fired plants. Returns the ALLOWED power per
        plant [MW] (== y where the store can feed it; derated at the
        withdrawal limit; 0.0 when starved)."""
        allowed = y_mw.copy()
        if self.n == 0 or len(store_rows) == 0:
            return allowed
        dt_h = dt_s / 3600.0
        floor = self.floor_kg()
        # withdrawal budget per store this tick (kg), shared by its plants
        budget = np.minimum(self.withdraw_max_kgph * dt_h,
                            np.maximum(self.level_kg - floor, 0.0))
        for i, row in enumerate(store_rows):
            if row < 0:
                continue
            need_kg = 1000.0 * y_mw[i] / (max(eta[i], 1e-9) * LHV_KWH_PER_KG) * dt_h
            take_kg = min(need_kg, budget[row])
            if need_kg > 1e-12:
                allowed[i] = y_mw[i] * take_kg / need_kg
            budget[row] -= take_kg
            self.level_kg[row] -= take_kg
            self.withdrawn_kg[row] += take_kg
        return allowed

    def state_dict(self) -> dict:
        rf = repr_floats
        return {"level_kg": rf(self.level_kg), "injected_kg": rf(self.injected_kg),
                "withdrawn_kg": rf(self.withdrawn_kg),
                "compressor_mwh": rf(self.compressor_mwh)}

    def restore_state(self, state: dict) -> None:
        for name in ("level_kg", "injected_kg", "withdrawn_kg", "compressor_mwh"):
            getattr(self, name)[:] = parse_floats(state[name])


def make_stores(specs: list[dict]) -> H2Stores:
    """specs: {id, island, capacity_kg, [level_kg, inject_max_kgph,
    withdraw_max_kgph]} — defaults per PARAMETERS §1.14 scaled by capacity
    (reference cavern: 4 000 t, 12 t/h in, 45 t/h out)."""
    n = len(specs)
    return H2Stores(
        ids=[s["id"] for s in specs],
        island=np.array([int(s.get("island", 0)) for s in specs], dtype=np.int64)
        if n else np.zeros(0, dtype=np.int64),
        capacity_kg=np.array([float(s["capacity_kg"]) for s in specs]) if n else np.zeros(0),
        level_kg=np.array([float(s.get("level_kg", 0.5 * float(s["capacity_kg"])))
                           for s in specs]) if n else np.zeros(0),
        inject_max_kgph=np.array(
            [float(s.get("inject_max_kgph", 12_000.0 * float(s["capacity_kg"]) / 4_000_000.0))
             for s in specs]) if n else np.zeros(0),
        withdraw_max_kgph=np.array(
            [float(s.get("withdraw_max_kgph", 45_000.0 * float(s["capacity_kg"]) / 4_000_000.0))
             for s in specs]) if n else np.zeros(0),
        injected_kg=np.zeros(n),
        withdrawn_kg=np.zeros(n),
        compressor_mwh=np.zeros(n),
    )
