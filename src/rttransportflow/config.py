"""Settings via pydantic-settings, env prefix RTTRANSPORTFLOW_ (family pattern)."""

from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="RTTRANSPORTFLOW_",
        env_file=".env",
        extra="ignore",
    )

    # --- service ---
    data_dir: str = "data/grids/europe_mini"
    catalog_path: str = "data/catalogs/plant_types.json"
    simulator: Literal["dyn", "pf", "null"] = "dyn"
    host: str = "127.0.0.1"  # loopback by default: the API has no auth
    port: int = 8003
    log_level: str = "info"
    cors_origins: list[str] = []
    record: bool = False
    record_dir: str = ".run/recordings"

    # --- clock (standalone accelerated tick; puppet mode disables the loop) ---
    step_interval_seconds: float = 1.0
    steps_per_day: int = 96
    autostart: bool = True
    external_clock: bool = False
    history_size: int = 512

    # --- solver ---
    warm_start: bool = True

    # --- dynamics (ModeConfig.from_settings; authority: docs/PHYSICS.md §4).
    # These reach the engine via ModeConfig — the ledger-5 mode-hysteresis
    # revisit surface. WARNING: changing any of them moves the tick/PF grid,
    # so the bit-exact-pinned smokes stop comparing to their recorded numbers
    # on that machine. Defaults are bit-equal to ModeConfig()'s.
    # (An earlier version of this block also declared embedded_dg_frac,
    # max_dt_s, trajectory_max_samples and snapshot_ring_interval_s — those
    # were knobs wired to NOTHING and are gone: the DG fraction is a
    # PARAMETERS §2.2 constant in dynamics/protection.py, the dt_s bounds are
    # CONTRACT numbers in api/gamebridge.py, the trajectory cap is
    # contract-adjacent (schema maxItems), and the ring cadence is
    # dynamics.SNAP_MARK_US paired with the replay retention.)
    dt_alert: float = 0.010
    dt_calm: float = 0.250
    pf_interval_alert: float = 1.0
    pf_interval_calm: float = 30.0
    alert_df_mhz: float = 50.0
    alert_rocof_mhz_s: float = 25.0
    calm_df_mhz: float = 30.0
    calm_rocof_mhz_s: float = 10.0
    calm_hold_s: float = 30.0
    d_load_pct_per_hz: float = 1.0
