"""Catalog-vs-code drift guard.

data/catalogs/plant_types.json is the authority for per-kind constants
(PARAMETERS §1, family rule). Two kinds of mirror exist in code and MUST
stay equal to their catalog counterparts:

- make_fleet's named fallback constants (fleet.py) — used by direct-spec
  callers (the analytic fixtures) that bypass plant_types.py. Before this
  guard, a catalog retune reached only the spec-builder path and the two
  paths forked silently; only whichever path a given test exercised was
  protected.
- FWindowConfig's defaults (protection.py) — the engine now READS the
  catalog frequency_protection block (DynSimulator wires it); the defaults
  exist for direct-Integrator fixtures and must not drift from it.
"""

from __future__ import annotations

from rttransportflow.dynamics import fleet as fl
from rttransportflow.dynamics.plant_types import load_catalog
from rttransportflow.dynamics.protection import FWindowConfig

DOC = load_catalog()
KINDS = DOC["kinds"]

MIRRORS = [
    ("gas_ccgt", "t_fuel_s", fl.CCGT_T_FUEL_S),
    ("gas_ccgt", "t_gt_s", fl.CCGT_T_GT_S),
    ("gas_ccgt", "t_st_s", fl.CCGT_T_ST_S),
    ("gas_ocgt", "t_fuel_s", fl.OCGT_T_FUEL_S),
    ("gas_ocgt", "t_gt_s", fl.OCGT_T_GT_S),
    ("hydro_ps", "t_r_s", fl.HYDRO_T_R_S),
    ("hydro_ps", "r_t", fl.HYDRO_R_T),
    ("hydro_ps", "r_pu", fl.HYDRO_R_PU),
    ("hydro_ps", "t_servo_s", fl.HYDRO_T_SERVO_S),
    ("hydro_ps", "gate_rate_pu_s", fl.HYDRO_GATE_RATE_PU_S),
    ("hydro_ps", "t_w_s", fl.HYDRO_T_W_S),
    ("hydro_ps", "eta_pump", fl.HYDRO_ETA_PUMP),
    ("hydro_ps", "eta_turbine", fl.HYDRO_ETA_TURBINE),
    ("battery", "t_b_s", fl.BAT_T_B_S),
    ("battery", "ffr_full_hz", fl.BAT_FFR_FULL_HZ),
    ("battery", "deadband_hz", fl.BAT_DB_HZ),
    ("battery", "eta_ch", fl.BAT_ETA_CH),
    ("battery", "eta_dis", fl.BAT_ETA_DIS),
    ("battery", "soc_min_frac", fl.BAT_SOC_MIN_FRAC),
    ("battery", "soc_max_frac", fl.BAT_SOC_MAX_FRAC),
    ("battery", "soc_target_frac", fl.BAT_SOC_TARGET_FRAC),
    ("battery", "recharge_frac_pn", fl.BAT_RECHARGE_FRAC),
    ("battery", "recharge_quiet_hz", fl.BAT_QUIET_HZ),
    ("electrolyzer", "t_e_s", fl.ELY_T_E_S),
    ("electrolyzer", "deadband_hz", fl.ELY_DB_HZ),
    ("electrolyzer", "shed_full_hz", fl.ELY_SHED_FULL_HZ),
]


def test_make_fleet_fallbacks_match_catalog() -> None:
    for kind, key, mirror in MIRRORS:
        assert KINDS[kind][key] == mirror, (
            f"{kind}.{key} (catalog {KINDS[kind][key]!r}) drifted from the "
            f"make_fleet fallback ({mirror!r}) — retune BOTH or neither"
        )


def test_lfsm_defaults_match_catalog() -> None:
    # the sync-side LFSM-O pair and the inverter fallback both mirror the
    # converter grid-code numbers every catalog inverter kind carries
    for kind in ("wind_onshore", "wind_offshore", "solar_pv", "offshore_hub"):
        assert KINDS[kind]["lfsm_o_from_hz"] == fl.LFSM_O_FROM_HZ


def test_frequency_protection_block_matches_defaults() -> None:
    fp = DOC["frequency_protection"]
    d = FWindowConfig()
    assert fp["sync_trip_low_hz"] == d.low_hz
    assert fp["sync_trip_high_hz"] == d.high_hz
    assert int(round(fp["sync_trip_delay_s"] * 1e6)) == d.delay_us
