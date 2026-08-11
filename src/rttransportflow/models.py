"""Pydantic schemas for the scenario bundle (SPEC §4.1, P1 subset).

P1 consumes grid/lines/plants/load_centers/scenario. storage.json,
links.json and weather.json join in their phases (P7/P6) — the loader
tolerates their absence, never their invalidity.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


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


PlantKind = Literal[
    "nuclear",
    "coal",
    "lignite",
    "gas_ccgt",
    "gas_ocgt",
    "hydro_ps",
    "wind_onshore",
    "wind_offshore",
    "solar_pv",
]

SYNC_KINDS: frozenset[str] = frozenset(
    {"nuclear", "coal", "lignite", "gas_ccgt", "gas_ocgt", "hydro_ps"}
)
CONVERTER_KINDS: frozenset[str] = frozenset(
    {"wind_onshore", "wind_offshore", "solar_pv"}
)


class PlantSpec(_Doc):
    id: str
    name: str
    bus: str
    kind: PlantKind
    p_max_mw: float
    p_min_mw: float = 0.0
    vm_pu: float = 1.02  # voltage setpoint (synchronous kinds, PV node)
    profile_p_mw: list[float]  # standalone dispatch profile, one value per step
    # H2 fuel chain (P7): converted gas plants burn from a named store.
    # v1 supports full conversion only (x_h2 = 1.0) — PHYSICS §2.8 gating.
    fuel: Literal["ng", "h2", "coal", "lignite", "uranium"] | None = None
    h2_store_id: str | None = None


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
