"""Wire-boundary application + per-class device command handlers of the
DynSimulator (mixin — see simulator_topology.py for why a mixin)."""

from __future__ import annotations


class CommandsMixin:
    def apply_wire_boundary(self, zone_demand: dict | None, avail_mw: dict | None,
                            device_commands: dict | None) -> list[str]:
        """Apply a step request's boundary; returns per-entry problem notes
        (tolerant: unknown ids are reported, never fatal)."""
        from .network_builder import DEFAULT_Q_FACTOR

        notes: list[str] = []
        for zone_id, payload in (zone_demand or {}).items():
            rows = self._zone_rows.get(zone_id)
            if rows is None:
                notes.append(f"zone_demand: unknown zone {zone_id!r}")
                continue
            value = float(payload["value_mw"]) if isinstance(payload, dict) else float(payload)
            share = value / len(rows)
            for row in rows:
                self._load_p_col[row] = share
                self._load_q_col[row] = share * DEFAULT_Q_FACTOR
        self._refresh_p_l0()

        for plant_id, value in (avail_mw or {}).items():
            hub_row = self._hub_row.get(plant_id)
            if hub_row is not None:
                # hub availability arrives farm-aggregated; the backend owns
                # the §1.16 path losses (2 stations + cable) and the rating clamp
                p_max = self._hub_p_max[plant_id]
                delivered = min(float(value), p_max) * (1.0 - self._hub_loss[plant_id])
                self.fleet.inv_avail[hub_row] = max(delivered, 0.0)
                continue
            row = self._inv_row.get(plant_id)
            if row is None:
                notes.append(f"avail_mw: unknown converter plant {plant_id!r}")
                continue
            self.fleet.inv_avail[row] = float(value)

        for device_id, cmd in (device_commands or {}).items():
            if device_id in self._sync_row:
                notes += self._cmd_sync(device_id, cmd)
            elif device_id in self._hub_row:
                notes += self._cmd_hub(device_id, cmd)
            elif device_id in self._inv_row:
                notes += self._cmd_inv(device_id, cmd)
            elif device_id in self._bat_row:
                notes += self._cmd_battery(device_id, cmd)
            elif device_id in self._ely_row:
                notes += self._cmd_electrolyzer(device_id, cmd)
            elif device_id in self._term_row:
                notes += self._cmd_hvdc_term(device_id, cmd)
            else:
                notes.append(f"device_commands: unknown device {device_id!r}")
        return notes

    # -- per-class command handlers (tolerant: bad fields note, never raise) --

    def _cmd_sync(self, device_id: str, cmd: dict) -> list[str]:
        notes: list[str] = []
        row = self._sync_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            value = float(cmd["dispatch_mw"])
            if value < 0.0:
                # pump mode (PHS): negative dispatch = pumping draw
                if bool(self.fleet.is_hydro[row]):
                    self.fleet.hy_pump_set[row] = min(
                        -value, float(self.fleet.p_max[row]))
                    self.fleet.p_set[row] = 0.0
                else:
                    notes.append(f"{device_id}: negative dispatch on a "
                                 "non-hydro unit")
            else:
                self.fleet.p_set[row] = value
                if bool(self.fleet.is_hydro[row]):
                    self.fleet.hy_pump_set[row] = 0.0
        if cmd.get("curtail_to_mw") is not None:
            notes.append(f"{device_id}: curtail_to_mw on a synchronous plant")
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.command_stop(device_id, self.integrator.t_us)
            self.integrator.refresh_e_k()
        elif breaker == "close":
            try:
                self.fleet.command_start(device_id, self.integrator.t_us)
                if cmd.get("black_start"):
                    if self.fleet.black_start_rows is None:
                        self.fleet.black_start_rows = set()
                    self.fleet.black_start_rows.add(int(row))
            except RuntimeError as exc:
                notes.append(str(exc))
        return notes

    def _cmd_inv(self, device_id: str, cmd: dict) -> list[str]:
        notes: list[str] = []
        row = self._inv_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            notes.append(f"{device_id}: dispatch_mw on a converter plant")
        if cmd.get("curtail_to_mw") is not None:
            self.fleet.inv_curtail[row] = float(cmd["curtail_to_mw"])
        return notes

    def _cmd_hub(self, device_id: str, cmd: dict) -> list[str]:
        from .dynamics.hvdc import Q_BAND_FRAC

        notes: list[str] = []
        row = self._inv_row[device_id]
        if cmd.get("curtail_to_mw") is not None:
            self.fleet.inv_curtail[row] = float(cmd["curtail_to_mw"])
        if cmd.get("q_mvar") is not None:
            band = Q_BAND_FRAC * self._hub_p_max[device_id]  # STATCOM at any P (§1.16)
            hub_i = row - self._n_native_inv
            self._hub_q[hub_i] = float(self._np.clip(float(cmd["q_mvar"]), -band, band))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.inv_online[row] = False
            self.fleet.inv_p[row] = 0.0
        elif breaker == "close":
            self.fleet.inv_online[row] = True
        return notes

    def _cmd_battery(self, device_id: str, cmd: dict) -> list[str]:
        row = self._bat_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            p_max = float(self.fleet.bat_p_max[row])
            self.fleet.bat_p_set[row] = float(
                self._np.clip(float(cmd["dispatch_mw"]), -p_max, p_max))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.bat_online[row] = False
            self.fleet.bat_p[row] = 0.0
            self.integrator.refresh_e_k()  # grid-forming H_v leaves the ledger
        elif breaker == "close":
            self.fleet.bat_online[row] = True
            self.integrator.refresh_e_k()
        return []

    def _cmd_electrolyzer(self, device_id: str, cmd: dict) -> list[str]:
        row = self._ely_row[device_id]
        if cmd.get("dispatch_mw") is not None:
            self.fleet.ely_p_set[row] = float(self._np.clip(
                float(cmd["dispatch_mw"]), 0.0, float(self.fleet.ely_p_max[row])))
        breaker = cmd.get("breaker")
        if breaker == "open":
            self.fleet.ely_online[row] = False
            self.fleet.ely_p[row] = 0.0
        elif breaker == "close":
            self.fleet.ely_online[row] = True
        return []

    def _cmd_hvdc_term(self, device_id: str, cmd: dict) -> list[str]:
        links = self.fleet.hvdc
        if cmd.get("dispatch_mw") is not None:
            links.command(device_id, float(cmd["dispatch_mw"]))
        if cmd.get("q_mvar") is not None:
            links.command_q(device_id, float(cmd["q_mvar"]))
        breaker = cmd.get("breaker")
        if breaker == "open":
            links.trip(device_id)
        elif breaker == "close":
            links.close(device_id)
        return []


    def set_watch(self, watch: list[str]) -> list[str]:
        specs: list[tuple[str, str, int]] = []
        notes: list[str] = []
        for device_id in watch:
            if device_id in self._sync_row:
                specs.append((device_id, "sync", self._sync_row[device_id]))
            elif device_id in self._inv_row:
                specs.append((device_id, "inv", self._inv_row[device_id]))
            elif device_id in self._bat_row:
                specs.append((device_id, "bat", self._bat_row[device_id]))
            elif device_id in self._ely_row:
                specs.append((device_id, "ely", self._ely_row[device_id]))
            else:
                notes.append(f"watch: unknown device {device_id!r}")
        self.integrator.watch_specs = specs
        return notes

