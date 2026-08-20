"""Contract-v2 reset `devices` channel parser.

Kinds: battery | grid_forming | electrolyzer | h2_store | hvdc |
offshore_hub (sync_plant/wind/pv travel in the native bundle — the game's
topology builder owns them). Zero coupling to the simulator: takes the
catalog and bus index as plain arguments and returns fleet spec lists.
"""

from __future__ import annotations


class WireDeviceError(ValueError):
    """Invalid reset `devices` entry — surfaces as HTTP 400, never a crash."""


def parse_wire_devices(devices: list[dict], catalog: dict, bus_index: dict) -> dict:
    """Partition contract-v2 reset devices into fleet spec lists."""
    from .dynamics.hvdc import NO_LOAD_AUX_FRAC, path_loss_frac
    from .dynamics.plant_types import battery_spec, electrolyzer_spec

    out: dict = {"bat": [], "ely": [], "stores": [], "hubs": [], "pairs": [],
                 "ely_store": {}, "nodes": {}}
    hvdc_groups: dict[str, list[dict]] = {}
    seen: set[str] = set()
    for dev in devices:
        did = dev.get("id")
        kind = dev.get("kind")
        node = dev.get("node")
        params = dev.get("params") or {}
        if not did or did in seen:
            raise WireDeviceError(f"device id missing or duplicate: {did!r}")
        seen.add(did)
        try:
            if kind != "h2_store":  # stores are ledger entities, not bus elements
                if node not in bus_index:
                    raise WireDeviceError(f"{did}: unknown node {node!r}")
                out["nodes"][did] = node
            if kind in ("battery", "grid_forming"):
                cat = catalog["battery_gfm" if kind == "grid_forming" else "battery"]
                spec = battery_spec(kind, cat, device_id=did, island=0,
                                    p_max_mw=float(params["p_max_mw"]),
                                    e_mwh=float(params["e_mwh"]),
                                    soc_frac=float(params.get("soc", 0.55)))
                ffr = params.get("ffr") or {}
                if ffr.get("enabled") is False:
                    spec["k_f"] = 0.0
                if "full_at_hz" in ffr:
                    spec["ffr_full_hz"] = float(ffr["full_at_hz"])
                if "deadband_hz" in ffr:
                    spec["db"] = float(ffr["deadband_hz"])
                if kind == "grid_forming":
                    spec["h_v"] = float(params.get("h_v_s", cat["h_v_s"]))
                out["bat"].append(spec)
            elif kind == "electrolyzer":
                store_id = params.get("h2_store_id")
                if not store_id:
                    raise WireDeviceError(f"{did}: electrolyzer needs h2_store_id")
                out["ely"].append(electrolyzer_spec(
                    kind, catalog["electrolyzer"], device_id=did, island=0,
                    p_max_mw=float(params["p_max_mw"]), p_set_mw=0.0))
                out["ely_store"][did] = str(store_id)
            elif kind == "h2_store":
                spec = {"id": did, "island": 0,
                        "capacity_kg": float(params["capacity_kg"])}
                for key in ("level_kg", "inject_max_kgph", "withdraw_max_kgph"):
                    if key in params and params[key] is not None:
                        spec[key] = float(params[key])
                out["stores"].append(spec)
            elif kind == "offshore_hub":
                # §1.16 physics numbers come from the catalog like every
                # other kind (it was the ONE kind bypassing it — a
                # PARAMETERS retune meant editing this parser)
                hub_cat = catalog["offshore_hub"]
                p_max = float(params["p_max_mw"])
                out["hubs"].append({
                    "id": did, "island": 0, "p_rated": p_max, "avail": 0.0,
                    "t_up": hub_cat["t_up_s"], "t_down": hub_cat["t_down_s"],
                    # front-crossing rate
                    "avail_slew_mw_s": hub_cat["avail_slew_pct_pn_min"]
                    / 100.0 * p_max / 60.0,
                    "lfsm_from": hub_cat["lfsm_o_from_hz"],
                    "lfsm_droop": hub_cat["lfsm_o_droop_pu"],
                    "aux_mw": NO_LOAD_AUX_FRAC * p_max,
                    # extra keys (ignored by make_fleet), kept for the sim maps
                    "loss_frac": path_loss_frac(float(params.get("cable_km", 0.0))),
                    "p_max": p_max,
                })
            elif kind == "hvdc":
                link_id = str(params.get("link_id") or "")
                if not link_id:
                    raise WireDeviceError(f"{did}: hvdc terminal needs link_id")
                hvdc_groups.setdefault(link_id, []).append(dev)
            else:
                raise WireDeviceError(f"{did}: unsupported device kind {kind!r}")
        except KeyError as exc:
            raise WireDeviceError(f"{did}: missing param {exc}") from None
    for link_id, terms in hvdc_groups.items():
        if len(terms) != 2:
            raise WireDeviceError(
                f"hvdc link {link_id!r}: needs exactly 2 terminals, got {len(terms)}")
        p_max = max(float((t.get("params") or {}).get("p_max_mw", 0.0)) for t in terms)
        if p_max <= 0:
            raise WireDeviceError(f"hvdc link {link_id!r}: p_max_mw missing")
        length = max(float((t.get("params") or {}).get("length_km", 0.0)) for t in terms)
        out["pairs"].append({
            "link_id": link_id, "p_max_mw": p_max, "length_km": length,
            "terminals": [{"id": t["id"], "island": 0} for t in terms],
        })
    return out


# historical spelling (simulator.py re-exported it under this name)
_parse_wire_devices = parse_wire_devices
