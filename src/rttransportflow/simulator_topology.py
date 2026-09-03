"""Topology layer of the DynSimulator (P8): bus graph, island split/merge,
line switching, and the line overload protection at PF instants.

A MIXIN, not a collaborator: the split is file-level separation of the
topology concern out of the 1100-line simulator module — `self` stays one
object, every attribute name is unchanged, and no float operation moved
(the bit-exact pins are the constraint; a delegating facade would have had
to re-plumb a dozen shared attributes for zero behavioral gain).
"""

from __future__ import annotations

# Line overload protection at PF instants (PARAMETERS §2.2). Named here
# beside the duty logic; the frequency-side siblings (UFLS, interruptible
# tiers, RoCoF table) live in dynamics/protection.py.
OVERLOAD_INSTANT_PCT = 150.0  # instant trip at/above
DUTY_ARM_PCT = 120.0          # duty integrates above this loading
DUTY_TRIP_PCT_S = 3000.0      # ∫(loading−100)dt trip threshold [%·s]
DUTY_DECAY_PCT_S = 50.0       # duty decays below DUTY_CLEAR_PCT at this rate
DUTY_CLEAR_PCT = 100.0
RESYNC_MAX_DF_HZ = 0.2        # line_close between live islands (PHYSICS §2.7)


class TopologyMixin:
    def _components(self) -> tuple[dict[int, int], int]:
        """Connected components of the IN-SERVICE line graph; component ids
        ordered by minimum bus index (deterministic across runs)."""
        buses = [int(b) for b in self.built.net.bus.index]
        parent = {b: b for b in buses}

        def find(x: int) -> int:
            while parent[x] != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        net = self.built.net
        for lid, idx in zip(self.built.line_ids, self.built.line_idx):
            if not self._line_in_service[lid]:
                continue
            a = find(int(net.line.from_bus.at[idx]))
            b = find(int(net.line.to_bus.at[idx]))
            if a != b:
                parent[max(a, b)] = min(a, b)
        roots = sorted({find(b) for b in buses})
        comp_of_root = {r: i for i, r in enumerate(roots)}
        return {b: comp_of_root[find(b)] for b in buses}, len(roots)

    def _refresh_p_l0(self) -> None:
        np_ = self._np
        islands = self.integrator.islands
        p_l0 = np_.zeros(islands.n)
        for row, bus in enumerate(self._load_bus):
            p_l0[self._bus_island[bus]] += self._load_p_col[row]
        islands.p_l0 = p_l0

    def _retopologize(self) -> list[tuple[str, str, dict]]:
        """Recompute islands after a line state change. New islands inherit
        the parent's f/w/defense state (COI approximation, PHYSICS §2.7)."""
        np_ = self._np
        bus_comp, n = self._components()
        old_map = self._bus_island
        old = self.integrator.islands
        if n == old.n and all(old_map[b] == c for b, c in bus_comp.items()):
            return []
        # parent of each new island = old island of its minimum member bus
        rep: dict[int, int] = {}
        for bus in sorted(bus_comp):
            rep.setdefault(bus_comp[bus], bus)
        parents = [old_map[rep[c]] for c in range(n)]
        self._bus_island = bus_comp

        fleet = self.fleet
        fleet.island_of = np_.array(
            [bus_comp[b] for b in self._gen_bus], dtype=np_.int64)             if self._gen_bus else np_.zeros(0, dtype=np_.int64)
        inv_buses = self._nsgen_bus + self._hub_bus
        fleet.inv_island = np_.array(
            [bus_comp[b] for b in inv_buses], dtype=np_.int64)             if inv_buses else np_.zeros(0, dtype=np_.int64)
        if len(fleet.bat_ids):
            fleet.bat_island = np_.array(
                [bus_comp[b] for b in self._bat_bus], dtype=np_.int64)
        if len(fleet.ely_ids):
            fleet.ely_island = np_.array(
                [bus_comp[b] for b in self._ely_bus], dtype=np_.int64)
        if fleet.hvdc is not None and len(self._term_bus):
            term_islands = [bus_comp[b] for b in self._term_bus]
            fleet.hvdc.island_a = np_.array(term_islands[0::2], dtype=np_.int64)
            fleet.hvdc.island_b = np_.array(term_islands[1::2], dtype=np_.int64)
        if fleet.h2 is not None and len(fleet.ely_ids):
            # compressor aux follows each store's first bound electrolyzer
            for store_row in range(fleet.h2.n):
                bound = np_.nonzero(fleet.ely_store_row == store_row)[0]
                if len(bound):
                    fleet.h2.island[store_row] = fleet.ely_island[bound[0]]

        from .dynamics.integrator import IslandState
        idx = np_.array(parents, dtype=np_.int64)
        # p_loss/p_extra: split by load share of the parent (PF refreshes
        # p_loss at the very next event solve anyway)
        p_l0_new = np_.zeros(n)
        for row, bus in enumerate(self._load_bus):
            p_l0_new[bus_comp[bus]] += self._load_p_col[row]
        parent_l0 = np_.maximum(old.p_l0[idx], 1e-9)
        share = np_.where(parent_l0 > 1e-6, p_l0_new / parent_l0, 1.0)
        islands_new = IslandState(
            f=old.f[idx].copy(), e_k=np_.zeros(n), p_l0=p_l0_new,
            w=old.w[idx].copy(), p_loss=old.p_loss[idx] * share,
            d_pu=old.d_pu, p_extra=old.p_extra[idx] * share)
        old_n = old.n
        self.integrator.replace_islands(islands_new, parents)
        self._apply_pf_topology()
        kind = "island_split" if n > old_n else "island_merge"
        return [(kind, f"islands:{old_n}->{n}", {"n_islands": n})]

    def _apply_pf_topology(self) -> None:
        """Slack election + dead-island isolation for the AC solve: every
        live island (>=1 online sync machine) gets exactly one reference;
        islands without a source drop out of the PF entirely."""
        np_ = self._np
        net = self.built.net
        fleet = self.fleet
        n = self.integrator.islands.n
        live = np_.zeros(n, dtype=bool)
        for row in np_.nonzero(fleet.online)[0]:
            live[fleet.island_of[row]] = True
        ext_bus = int(net.ext_grid.bus.iat[0])
        ext_island = self._bus_island[ext_bus]
        net.ext_grid.loc[net.ext_grid.index, "in_service"] = bool(live[ext_island])
        if "slack" in net.gen.columns:
            net.gen.loc[net.gen.index, "slack"] = False
        for island in np_.nonzero(live)[0]:
            if island == ext_island:
                continue
            rows = np_.nonzero(fleet.online
                               & (fleet.island_of == island))[0]
            # slack must be a machine that can SOURCE power: a 300 MVA
            # syncon (p_max 0) would out-rank a 200 MW OCGT on raw s_n
            # and pandapower would draw the island's residual from a
            # machine with no prime mover (C6). Prefer real generators;
            # a syncon-only island keeps a slack for solvability and its
            # frequency model collapses it honestly (p_mech stays 0).
            sourced = [r for r in rows if float(fleet.p_max[r]) > 0.0]
            best = max(sourced or list(rows), key=lambda r: float(fleet.s_n[r]))
            net.gen.at[self.built.gen_idx[best], "slack"] = True
        for bus, comp in self._bus_island.items():
            net.bus.at[bus, "in_service"] = bool(live[comp])

    def _on_line_event(self, kind: str, line_id: str) -> list[tuple[str, str, dict]]:
        """Integrator callback for line_trip / line_close events."""
        if line_id not in self._line_in_service:
            return [("line_reject", line_id, {"reason": "unknown line"})]
        net = self.built.net
        idx = self._line_pp_idx[line_id]
        if kind == "line_trip":
            if not self._line_in_service[line_id]:
                return []
            self._line_in_service[line_id] = False
            net.line.at[idx, "in_service"] = False
            self._trip_scheduled.discard(line_id)
            self._line_duty.pop(line_id, None)
        else:  # line_close — resync gate (PHYSICS §2.7): |Δf| < 200 mHz
            if self._line_in_service[line_id]:
                return []
            fb = int(net.line.from_bus.at[idx])
            tb = int(net.line.to_bus.at[idx])
            ia, ib = self._bus_island[fb], self._bus_island[tb]
            islands = self.integrator.islands
            if ia != ib:
                black = islands.blackout()
                if not black[ia] and not black[ib]                         and abs(float(islands.f[ia] - islands.f[ib])) > RESYNC_MAX_DF_HZ:
                    return [("resync_rejected", line_id,
                             {"df_hz": float(islands.f[ia] - islands.f[ib])})]
            self._line_in_service[line_id] = True
            net.line.at[idx, "in_service"] = True
        return self._retopologize()

    def apply_line_commands(self, cmds: dict | None) -> list[tuple[str, str, dict]]:
        """Wire `line_commands`: immediate state change (contract: a STATE
        change, never a topology reset). Returns wire events."""
        events: list[tuple[str, str, dict]] = []
        for line_id, cmd in (cmds or {}).items():
            breaker = (cmd or {}).get("breaker")
            if breaker == "open":
                events += self._on_line_event("line_trip", line_id)
                events.append(("line_trip", line_id, {"cause": "breaker"}))
            elif breaker == "close":
                out = self._on_line_event("line_close", line_id)
                events += out
                if not any(k == "resync_rejected" for k, _, _ in out):
                    events.append(("line_close", line_id, {}))
        if events:
            self._run_pf("line_command")
        return events


    def _line_protection_scan(self, net, b, dt_pf: float, reason: str) -> None:
        """Per-line window-max tracking + overload protection (instant at
        >=150 %, duty-integrated above 120 %, decay below 100 %) — moved
        verbatim from _run_pf's post-solve section."""
        from .dynamics import QUANTUM_US
        from .dynamics.events import Event
        for line_id, idx in zip(b.line_ids, b.line_idx):
            if not self._line_in_service[line_id]:
                continue
            loading = float(net.res_line.loading_percent.at[idx])
            if loading > self._pf_window_max.get(line_id, 0.0):
                self._pf_window_max[line_id] = loading
            # overload protection (PARAMETERS §2.2): instant at >=150 %,
            # duty-integrated above 120 %, decay below 100 %.
            # NOT on the warmup solve: that operating point is the reset
            # artifact (every unit still at its scheduled setpoint, nothing
            # ramped, no dispatcher word yet), and tripping on it killed a
            # freshly registered grid inside 10 ms. Real protection is armed
            # on an energised, settled system.
            if reason == "warmup" or line_id in self._trip_scheduled:
                continue
            if loading >= OVERLOAD_INSTANT_PCT:
                self.integrator.queue.schedule(Event(
                    self.integrator.t_us + QUANTUM_US, "line_trip", line_id,
                    {"cause": "overload_instant", "loading": loading}))
                self._trip_scheduled.add(line_id)
            elif loading > DUTY_ARM_PCT:
                duty = self._line_duty.get(line_id, 0.0)                     + (loading - 100.0) * dt_pf
                self._line_duty[line_id] = duty
                if duty >= DUTY_TRIP_PCT_S:
                    self.integrator.queue.schedule(Event(
                        self.integrator.t_us + QUANTUM_US, "line_trip", line_id,
                        {"cause": "overload_duty", "loading": loading}))
                    self._trip_scheduled.add(line_id)
            elif loading < DUTY_CLEAR_PCT and line_id in self._line_duty:
                duty = self._line_duty[line_id] - DUTY_DECAY_PCT_S * dt_pf
                if duty <= 0.0:
                    del self._line_duty[line_id]
                else:
                    self._line_duty[line_id] = duty
