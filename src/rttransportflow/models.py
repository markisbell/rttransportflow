"""Pydantic schemas for the scenario bundle (SPEC §4.1, P1 subset).

P1 consumes grid/lines/plants/load_centers/scenario. storage.json,
links.json and weather.json join in their phases (P7/P6) — the loader
tolerates their absence, never their invalidity.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class _Doc(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Geo(_Doc):
    lat: float
    lon: float


class BusSpec(_Doc):
    name: str
    vn_kv: float = 380.0
    geo: Geo | None = None
    area: str = "CE"


class ZoneSpec(_Doc):
    id: str
    bus: str


class GridDoc(_Doc):
    buses: list[BusSpec]
    reference_bus: str
    zones: list[ZoneSpec] = Field(default_factory=list)


class LineSpec(_Doc):
    id: str
    from_bus: str
    to_bus: str
    length_km: float
    std_type: str | None = "490-AL1/64-ST1A 380.0"
    parallel: int = 1
    # explicit params override std_type when given
    r_ohm_per_km: float | None = None
    x_ohm_per_km: float | None = None
    c_nf_per_km: float | None = None
    max_i_ka: float | None = None


class LinesDoc(_Doc):
    lines: list[LineSpec]


# One mapping owns the kind vocabulary AND its sync/converter partition —
# adding a kind to the Literal but neither set used to pass validation and
# only fail at build time ("schema forbids this").
_KIND_FAMILY: dict[str, str] = {
    "nuclear": "sync",
    "coal": "sync",
    "lignite": "sync",
    "gas_ccgt": "sync",
    "gas_ocgt": "sync",
    "hydro_ps": "sync",
    "syncon": "sync",
    "wind_onshore": "converter",
    "wind_offshore": "converter",
    "solar_pv": "converter",
}

PlantKind = Literal[
    "nuclear",
    "coal",
    "lignite",
    "gas_ccgt",
    "gas_ocgt",
    "hydro_ps",
    "syncon",
    "wind_onshore",
    "wind_offshore",
    "solar_pv",
]

SYNC_KINDS: frozenset[str] = frozenset(
    k for k, family in _KIND_FAMILY.items() if family == "sync"
)
CONVERTER_KINDS: frozenset[str] = frozenset(
    k for k, family in _KIND_FAMILY.items() if family == "converter"
)

# import-time exhaustiveness guard: the Literal and the mapping must agree
from typing import get_args as _get_args  # noqa: E402

assert set(_get_args(PlantKind)) == set(_KIND_FAMILY), \
    "PlantKind and _KIND_FAMILY drifted — add new kinds to BOTH"


class PlantSpec(_Doc):
    id: str
    name: str
    bus: str
    kind: PlantKind
    p_max_mw: float
    p_min_mw: float = 0.0
    vm_pu: float = 1.02  # voltage setpoint (synchronous kinds, PV node)
    # C6: explicit machine rating [MVA]. Default None keeps the historic
    # p_max/0.9 derivation BIT-IDENTICAL for every existing kind (the
    # model hash covers s_n) — required in practice only for "syncon",
    # whose p_max is 0 and would otherwise carry zero inertia and a zero
    # Q band (PARAMETERS §1.15: H on S_n, Q ±0.40·S_n).
    sn_mva: float | None = None
    profile_p_mw: list[float]  # standalone dispatch profile, one value per step
    # H2 fuel chain (P7): converted gas plants burn from a named store.
    # v1 supports full conversion only (x_h2 = 1.0) — PHYSICS §2.8 gating.
    fuel: Literal["ng", "h2", "coal", "lignite", "uranium"] | None = None
    h2_store_id: str | None = None

    @model_validator(mode="after")
    def _syncon_needs_rating(self) -> "PlantSpec":
        # reject loudly at the SCHEMA (a 400 on reset), not deep in the
        # spec build where a raise would 500 — never-crash discipline
        if self.kind == "syncon" and not (self.sn_mva and self.sn_mva > 0.0):
            raise ValueError(f"{self.id}: syncon requires sn_mva > 0")
        return self


class PlantsDoc(_Doc):
    plants: list[PlantSpec]


class LoadItem(_Doc):
    name: str
    zone: str
    p_mw: list[float]
    q_mvar: list[float] | None = None  # default: pf 0.97 inductive


class LoadCentersDoc(_Doc):
    resolution_minutes: int
    steps: int
    items: list[LoadItem]


class ScenarioDoc(_Doc):
    name: str
    steps_per_day: int
    description: str = ""
    # Degree of shunt (reactor) compensation of line charging, 0..1. Long
    # EHV corridors inject enormous capacitive charging (the realistic
    # continental grid measures ~87 GVAr) and real TSOs compensate it with
    # reactors at the stations; 0 keeps every legacy bundle byte-identical.
    shunt_comp: float = 0.0
