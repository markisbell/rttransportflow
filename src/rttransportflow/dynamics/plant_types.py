"""Catalog loader: data/catalogs/plant_types.json → fleet spec fragments.

The catalog is the single source of truth for per-kind constants
(PARAMETERS §1); every entry carries a rationale string. This module maps a
catalog kind + device sizing into the spec dicts `make_fleet` consumes.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

DEFAULT_CATALOG = "data/catalogs/plant_types.json"

_REQUIRED_BY_MODEL = {
    "steam": {"h_s", "r_pu", "deadband_hz", "fcr_band_frac_pn", "t_servo_s",
              "t_chest_s", "t_reheat_s", "f_hp", "p_min_pct", "ramp_pct_min",
              "eta_full", "eta_min"},
    "ccgt": {"h_s", "r_pu", "deadband_hz", "fcr_band_frac_pn", "t_fuel_s",
             "t_gt_s", "t_st_s", "p_min_pct", "ramp_pct_min", "eta_full", "eta_min"},
    "ocgt": {"h_s", "r_pu", "deadband_hz", "fcr_band_frac_pn", "t_fuel_s",
             "t_gt_s", "p_min_pct", "ramp_pct_min", "eta_full", "eta_min"},
    "hydro": {"h_s", "r_pu", "deadband_hz", "fcr_band_frac_pn", "t_r_s", "r_t",
              "t_servo_s", "gate_rate_pu_s", "t_w_s", "p_min_pct", "ramp_pct_min"},
    "inverter": {"t_up_s", "t_down_s", "lfsm_o_from_hz", "lfsm_o_droop_pu"},
    "battery": {"t_b_s", "ffr_full_hz", "deadband_hz", "eta_ch", "eta_dis",
                "soc_min_frac", "soc_max_frac", "soc_target_frac",
                "recharge_frac_pn", "recharge_quiet_hz", "h_v_s"},
    "electrolyzer": {"t_e_s", "shed_full_hz", "deadband_hz"},
}


class CatalogError(ValueError):
    pass


def load_catalog(path: str | Path = DEFAULT_CATALOG) -> dict[str, Any]:
    doc = json.loads(Path(path).read_text())
    if doc.get("version") != 1:
        raise CatalogError(f"unsupported catalog version {doc.get('version')!r}")
    kinds = doc["kinds"]
    for kind, params in kinds.items():
        model = params.get("model")
        required = _REQUIRED_BY_MODEL.get(model)
        if required is None:
            raise CatalogError(f"{kind}: unknown model {model!r}")
        missing = required - set(params)
        if missing:
            raise CatalogError(f"{kind}: missing {sorted(missing)}")
        if "rationale" not in params:
            raise CatalogError(f"{kind}: every constant set carries a rationale (family rule)")
    return doc


def sync_spec(kind: str, params: dict, *, device_id: str, island: int,
              p_max_mw: float, p_min_mw: float, p_set_mw: float,
              offline: bool = False) -> dict:
    """Fleet sync-spec from a catalog entry. Envelope p_min is DEVICE-level
    (game/scenario-set); the catalog p_min_pct informs the dispatcher, not
    the engine clamp."""
    model = params["model"]
    spec = {
        "id": device_id, "island": island, "model": model,
        "s_n": p_max_mw / 0.9, "p_max": p_max_mw, "p_min": p_min_mw,
        "p_set": p_set_mw,
        "h": params["h_s"], "r": params["r_pu"], "db": params["deadband_hz"],
        "fcr_band": params["fcr_band_frac_pn"] * p_max_mw,
        "afrr_band": params.get("afrr_band_frac_pn", 0.0) * p_max_mw,
        "ramp_mw_s": params["ramp_pct_min"] / 100.0 * p_max_mw / 60.0,
        "start_hot_s": params.get("start_hot_s", 900),
        "start_warm_s": params.get("start_warm_s", 900),
        "start_cold_s": params.get("start_cold_s", 900),
        "warm_after_s": params.get("warm_after_s", 28800),
        "cold_after_s": params.get("cold_after_s", 172800),
        "trip_lockout_s": params.get("trip_lockout_s", 0),
        "eta_full": params.get("eta_full", 0.0),
        "eta_min": params.get("eta_min", 0.0),
        "offline": offline,
    }
    if model == "steam":
        spec.update(t_g=params["t_servo_s"], t_ch=params["t_chest_s"],
                    t_rh=params["t_reheat_s"], f_hp=params["f_hp"])
    elif model in ("ccgt", "ocgt"):
        spec.update(t_fuel=params["t_fuel_s"], t_gt=params["t_gt_s"])
        if model == "ccgt":
            spec.update(t_st=params["t_st_s"])
    elif model == "hydro":
        spec.update(e_mwh=params.get("e_hours", 8.0) * p_max_mw,
                    eta_pump=params.get("eta_pump", 0.88),
                    eta_turbine=params.get("eta_turbine", 0.90),
                    soc_frac=params.get("soc_frac", 0.5))
        spec.update(t_r=params["t_r_s"], r_t=params["r_t"],
                    t_servo=params["t_servo_s"],
                    gate_rate_pu_s=params["gate_rate_pu_s"], t_w=params["t_w_s"])
    else:
        raise CatalogError(f"{kind}: {model!r} is not a synchronous model")
    return spec


def inverter_spec(kind: str, params: dict, *, device_id: str, island: int,
                  p_rated_mw: float, avail_mw: float) -> dict:
    spec = {
        "id": device_id, "island": island, "p_rated": p_rated_mw,
        "avail": avail_mw,
        "t_up": params["t_up_s"], "t_down": params["t_down_s"],
        "lfsm_from": params["lfsm_o_from_hz"], "lfsm_droop": params["lfsm_o_droop_pu"],
    }
    if "avail_slew_pct_pn_min" in params:
        spec["avail_slew_mw_s"] = (
            params["avail_slew_pct_pn_min"] / 100.0 * p_rated_mw / 60.0)
    return spec


def battery_spec(kind: str, params: dict, *, device_id: str, island: int,
                 p_max_mw: float, e_mwh: float, soc_frac: float = 0.55) -> dict:
    return {
        "id": device_id, "island": island, "p_max": p_max_mw, "e_mwh": e_mwh,
        "soc_frac": soc_frac,
        "ffr_full_hz": params["ffr_full_hz"], "db": params["deadband_hz"],
        "t_b": params["t_b_s"], "eta_ch": params["eta_ch"], "eta_dis": params["eta_dis"],
        "soc_min_frac": params["soc_min_frac"], "soc_max_frac": params["soc_max_frac"],
        "soc_target_frac": params["soc_target_frac"],
        "recharge_frac": params["recharge_frac_pn"],
        "quiet_hz": params["recharge_quiet_hz"], "h_v": params["h_v_s"],
    }


def electrolyzer_spec(kind: str, params: dict, *, device_id: str, island: int,
                      p_max_mw: float, p_set_mw: float) -> dict:
    return {
        "id": device_id, "island": island, "p_max": p_max_mw, "p_set": p_set_mw,
        "t_e": params["t_e_s"], "db": params["deadband_hz"],
        "shed_full_hz": params["shed_full_hz"],
    }
