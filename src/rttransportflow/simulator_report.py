"""Wire-frame projection of the DynSimulator's state (mixin — see
simulator_topology.py for why a mixin).

Moved VERBATIM from api/gamebridge.py's _step_body: the projection logic for
every device class used to live in the HTTP layer, reading ~14 simulator
privates and even WRITING one (_pf_window_max) — the meter-delta protocol
was an implicit contract between two files. The expressions and dict
insertion orders are unchanged: the contract goldens compare serialized
frames, so byte-identity is the invariant. gamebridge keeps frame assembly,
_r(), idempotency and violations-from-notes.
"""

from __future__ import annotations

from typing import Any


class ReportingMixin:
    def begin_step(self) -> dict[str, Any]:
        """Meter snapshot for per-step deltas + the PF window-max reset
        (previously a cross-module WRITE from gamebridge)."""
        h2 = self.fleet.h2
        meters = {
            "e": self.fleet.energy_mwh.copy(),
            "fuel": self.fleet.fuel_mwh_th.copy(),
            "inv_e": self.fleet.inv_energy_mwh.copy(),
            "ely_e": self.fleet.ely_energy_mwh.copy(),
            "h2_wd": h2.withdrawn_kg.copy() if h2 is not None else None,
            "h2_in": h2.injected_kg.copy() if h2 is not None else None,
        }
        self._pf_window_max = {}
        return meters

    def device_report(self, meters: dict[str, Any]) -> dict[str, Any]:
        """The per-device wire block (state names, per-step meter deltas,
        SoC/H2/HVDC projections) — insertion order preserved."""
        e_before = meters["e"]
        fuel_before = meters["fuel"]
        inv_e_before = meters["inv_e"]
        ely_e_before = meters["ely_e"]
        h2_wd_before = meters["h2_wd"]
        h2_in_before = meters["h2_in"]
        h2 = self.fleet.h2

        devices: dict[str, Any] = {}
        status_names = {0: "offline", 1: "starting", 2: "online"}
        for pid, row in self._sync_row.items():
            state = status_names[int(self.fleet.status[row])]
            if state == "offline" and self.fleet.tripped_at_us[row] >= 0:
                state = "tripped"
            if state == "online" and self.fleet.h2_starved is not None \
                    and bool(self.fleet.h2_starved[row]):
                state = "starved"
            devices[pid] = {
                "p_mw": float(self.fleet.y[row] - self.fleet.hy_pump_p[row]),
                "state": state,
                "headroom_mw": max(0.0, float(self.fleet.p_max[row] - self.fleet.y[row])),
                "energy_mwh_step": float(self.fleet.energy_mwh[row] - e_before[row]),
                "fuel_mwh_th_step": float(self.fleet.fuel_mwh_th[row] - fuel_before[row]),
            }
            if bool(self.fleet.is_hydro[row]) and float(self.fleet.hy_e_mwh[row]) > 0:
                devices[pid]["soc"] = float(self.fleet.hy_soc_mwh[row]
                                            / self.fleet.hy_e_mwh[row])
                devices[pid]["soc_mwh"] = float(self.fleet.hy_soc_mwh[row])
        for pid, row in self._inv_row.items():
            devices[pid] = {
                "p_mw": float(self.fleet.inv_p[row]),
                "state": "online" if self.fleet.inv_online[row] else "tripped",
                "avail_mw": float(self.fleet.inv_avail[row]),
                "energy_mwh_step": float(self.fleet.inv_energy_mwh[row] - inv_e_before[row]),
            }
        for pid, row in self._bat_row.items():
            e_cap = float(self.fleet.bat_e_mwh[row])
            devices[pid] = {
                "p_mw": float(self.fleet.bat_p[row]),
                "state": "online" if self.fleet.bat_online[row] else "tripped",
                "soc": float(self.fleet.bat_soc[row]) / e_cap if e_cap > 0 else 0.0,
                "soc_mwh": float(self.fleet.bat_soc[row]),
                "clamped": bool(self.fleet.bat_clamped[row]),
            }
        for pid, row in self._ely_row.items():
            devices[pid] = {
                "p_mw": -float(self.fleet.ely_p[row]),  # a load: negative injection
                "state": "online" if self.fleet.ely_online[row] else "tripped",
                "energy_mwh_step": float(self.fleet.ely_energy_mwh[row] - ely_e_before[row]),
            }
        for sid, row in self._store_row.items():
            devices[sid] = {
                "h2_kg": float(h2.level_kg[row]),
                "capacity_kg": float(h2.capacity_kg[row]),
                "injected_kg_step": float(h2.injected_kg[row] - h2_in_before[row]),
                "withdrawn_kg_step": float(h2.withdrawn_kg[row] - h2_wd_before[row]),
                "state": "online",
            }
        if self.fleet.hvdc is not None:
            term_p = self.fleet.hvdc.term_p()
            for tid, i in self._term_row.items():
                link = int(self.fleet.hvdc.term_link[i])
                devices[tid] = {
                    "p_mw": float(term_p[i]),
                    "q_mvar": float(self.fleet.hvdc.term_q[i]),
                    "state": "online" if self.fleet.hvdc.online[link] else "tripped",
                    "link_id": self.fleet.hvdc.link_ids[link],
                }
        return devices

    def islands_report(self, res) -> dict[str, Any]:
        """The per-island wire block from an AdvanceResult."""
        island = self.integrator.islands
        n_islands = island.n
        s_online_arr = self.fleet.s_online_per_island(n_islands)
        agc_up, _agc_dn = self.fleet.agc_headroom(n_islands)
        fcr_arr = getattr(self.fleet, "fcr_used", None)
        return {str(i): {
            "f_hz": float(res.f_end[i]) if i < len(res.f_end) else float(island.f[i]),
            "rocof_hz_s": float(self.integrator.rings[i].rocof_window(self.integrator.t_us)),
            "f_min": float(res.f_min[i]) if i < len(res.f_min) else float(island.f[i]),
            "f_max": float(res.f_max[i]) if i < len(res.f_max) else float(island.f[i]),
            "rocof_max": float(res.rocof_max[i]) if i < len(res.rocof_max) else 0.0,
            "e_k_mj": float(island.e_k[i]),
            "s_online_mva": float(s_online_arr[i]),
            "h_sys_s": (float(island.e_k[i] / s_online_arr[i])
                        if s_online_arr[i] > 0 else 0.0),
            "blackout": bool(island.blackout()[i]),
            "fcr_used_mw": (float(fcr_arr[i])
                            if fcr_arr is not None and i < len(fcr_arr) else 0.0),
            "afrr_used_mw": (float(self.integrator.agc_mw[i])
                             if i < len(self.integrator.agc_mw) else 0.0),
            "afrr_headroom_up_mw": float(agc_up[i]) if i < len(agc_up) else 0.0,
            "w": float(island.w[i]),
        } for i in range(n_islands)}

    def zone_report(self) -> dict[str, Any]:
        """Per-zone supplied fraction + voltage detail."""
        pf = self._latest_pf
        island = self.integrator.islands
        zones = {}
        blackout = self.integrator.islands.blackout()
        for zone_id, bus in self._zone_bus.items():
            zone_island = self._bus_island[self.built.bus_index[bus]]
            detail = {}
            if pf.get("buses", {}).get(bus):
                detail["v_pu"] = pf["buses"][bus]["vm_pu"]
            zones[zone_id] = {"supplied": (0.0 if blackout[zone_island]
                                           else float(island.w[zone_island])),
                              "detail": detail}
        return zones

    def pf_violations(self) -> list[dict[str, Any]]:
        """Loading + voltage violations from the latest PF (PARAMETERS §5
        vocabulary); request-scoped notes are appended by the API layer."""
        pf = self._latest_pf
        violations: list[dict[str, Any]] = []
        for line_id, vals in pf.get("lines", {}).items():
            loading = vals["loading_percent"]
            if loading > 120.0:
                violations.append({"element": line_id, "kind": "loading",
                                   "severity": "critical", "value": loading})
            elif loading > 100.0:
                violations.append({"element": line_id, "kind": "loading",
                                   "severity": "warning", "value": loading})
        for bus, vals in pf.get("buses", {}).items():
            vm = vals["vm_pu"]
            if vm < 0.90 or vm > 1.10:
                violations.append({"element": bus, "kind": "voltage",
                                   "severity": "critical", "value": vm})
            elif vm < 0.95 or vm > 1.05:
                violations.append({"element": bus, "kind": "voltage",
                                   "severity": "warning", "value": vm})
        return violations

    def pf_report(self) -> tuple[dict[str, Any], dict[str, float]]:
        """(latest-PF projection, window extremes) for the wire pf block."""
        return {k: v for k, v in self._latest_pf.items()}, dict(self._pf_window_max)
