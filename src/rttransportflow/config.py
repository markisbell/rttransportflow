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

    # --- dynamics (consumed from P2 on; authority: docs/PHYSICS.md §4) ---
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
    embedded_dg_frac: float = 0.15
    max_dt_s: float = 900.0
    trajectory_max_samples: int = 512
    snapshot_ring_interval_s: float = 5.0
