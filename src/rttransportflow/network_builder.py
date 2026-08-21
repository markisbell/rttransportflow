"""Build the pandapower net ONCE + dense profile arrays (family pattern).

Per step the simulator writes profile columns into the net via the
element-index lists — the net is never rebuilt in the loop. Synchronous
plant kinds become PV-node `gen`s (vm setpoint, Q limits); converter kinds
(wind/PV) become `sgen`s at unity pf. The reference bus carries the single
`ext_grid` slack.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .data_loader import InputData
from .models import CONVERTER_KINDS, SYNC_KINDS

DEFAULT_Q_FACTOR = 0.2506  # tan(acos(0.97)) — pf 0.97 inductive
GEN_Q_BAND = 0.40  # ± fraction of p_max as Q limits (PARAMETERS-adjacent default)
SGEN_Q_FACTOR = 0.25  # converter plants support voltage at ~pf 0.97 capacitive
# (static stand-in for the ±0.33·P_n converter Q capability until P2 controls)


@dataclass
class BuiltNetwork:
    net: object  # pandapower net
    bus_index: dict[str, int]  # bus name -> pandapower bus index
    load_idx: list[int]  # pandapower load indices, row order = profile row
    gen_idx: list[int]
    sgen_idx: list[int]
    load_names: list[str]
    gen_ids: list[str]
    sgen_ids: list[str]
    line_idx: list[int]
    line_ids: list[str]
    load_p: np.ndarray  # [n_load, steps]
    load_q: np.ndarray
    gen_p: np.ndarray  # [n_gen, steps]
    sgen_p: np.ndarray
    sgen_q: np.ndarray


def build_network(data: InputData) -> BuiltNetwork:
    import pandapower as pp

    net = pp.create_empty_network(sn_mva=1000.0)
    steps = data.load_centers.steps

    bus_index: dict[str, int] = {}
    for bus in data.grid.buses:
        geodata = (bus.geo.lat, bus.geo.lon) if bus.geo else None
        bus_index[bus.name] = pp.create_bus(
            net, vn_kv=bus.vn_kv, name=bus.name, geodata=geodata
        )

    line_idx: list[int] = []
    line_ids: list[str] = []
    # Shunt-reactor compensation (scenario.shunt_comp): each line's charging
    # is absorbed half at each end, scaled by the compensation degree —
    # the standard EHV practice the bundle's flag stands for. Aggregated
    # per bus into one shunt element after the line loop.
    comp = float(getattr(data.scenario, "shunt_comp", 0.0) or 0.0)
    shunt_q: dict[int, float] = {}
    for ln in data.lines.lines:
        if ln.std_type is not None:
            idx = pp.create_line(
                net,
                bus_index[ln.from_bus],
                bus_index[ln.to_bus],
                length_km=ln.length_km,
                std_type=ln.std_type,
                parallel=ln.parallel,
                name=ln.id,
            )
            if comp > 0.0:
                std = pp.load_std_type(net, ln.std_type, "line")
                qc = (2.0 * 3.141592653589793 * 50.0
                      * float(std["c_nf_per_km"]) * 1e-9
                      * ln.length_km * ln.parallel
                      * (net.bus.at[bus_index[ln.from_bus], "vn_kv"] * 1e3) ** 2
                      / 1e6)
                for end in (ln.from_bus, ln.to_bus):
                    b = bus_index[end]
                    shunt_q[b] = shunt_q.get(b, 0.0) + qc * comp / 2.0
        else:
            idx = pp.create_line_from_parameters(
                net,
                bus_index[ln.from_bus],
                bus_index[ln.to_bus],
                length_km=ln.length_km,
                r_ohm_per_km=ln.r_ohm_per_km,
                x_ohm_per_km=ln.x_ohm_per_km,
                c_nf_per_km=ln.c_nf_per_km,
                max_i_ka=ln.max_i_ka,
                parallel=ln.parallel,
                name=ln.id,
            )
        line_idx.append(idx)
        line_ids.append(ln.id)

    for b, q in sorted(shunt_q.items()):
        pp.create_shunt(net, b, q_mvar=q, name="comp")

    zone_bus = {z.id: z.bus for z in data.grid.zones}
    load_idx: list[int] = []
    load_names: list[str] = []
    n_load = len(data.load_centers.items)
    load_p = np.zeros((n_load, steps))
    load_q = np.zeros((n_load, steps))
    for row, item in enumerate(data.load_centers.items):
        idx = pp.create_load(net, bus_index[zone_bus[item.zone]], p_mw=0.0, name=item.name)
        load_idx.append(idx)
        load_names.append(item.name)
        load_p[row, :] = item.p_mw
        load_q[row, :] = item.q_mvar if item.q_mvar is not None else np.asarray(item.p_mw) * DEFAULT_Q_FACTOR

    gen_idx: list[int] = []
    gen_ids: list[str] = []
    sgen_idx: list[int] = []
    sgen_ids: list[str] = []
    gen_rows: list[list[float]] = []
    sgen_rows: list[list[float]] = []
    for plant in data.plants.plants:
        if plant.kind in SYNC_KINDS:
            idx = pp.create_gen(
                net,
                bus_index[plant.bus],
                p_mw=0.0,
                vm_pu=plant.vm_pu,
                min_q_mvar=-GEN_Q_BAND * plant.p_max_mw,
                max_q_mvar=GEN_Q_BAND * plant.p_max_mw,
                name=plant.id,
            )
            gen_idx.append(idx)
            gen_ids.append(plant.id)
            gen_rows.append(plant.profile_p_mw)
        elif plant.kind in CONVERTER_KINDS:
            idx = pp.create_sgen(net, bus_index[plant.bus], p_mw=0.0, q_mvar=0.0, name=plant.id)
            sgen_idx.append(idx)
            sgen_ids.append(plant.id)
            sgen_rows.append(plant.profile_p_mw)
        else:  # pragma: no cover — the schema forbids this
            raise ValueError(f"unknown plant kind {plant.kind!r}")

    pp.create_ext_grid(net, bus_index[data.grid.reference_bus], vm_pu=1.02, name="slack")

    return BuiltNetwork(
        net=net,
        bus_index=bus_index,
        load_idx=load_idx,
        gen_idx=gen_idx,
        sgen_idx=sgen_idx,
        load_names=load_names,
        gen_ids=gen_ids,
        sgen_ids=sgen_ids,
        line_idx=line_idx,
        line_ids=line_ids,
        load_p=load_p,
        load_q=load_q,
        gen_p=np.array(gen_rows) if gen_rows else np.zeros((0, steps)),
        sgen_p=np.array(sgen_rows) if sgen_rows else np.zeros((0, steps)),
        sgen_q=(np.array(sgen_rows) * SGEN_Q_FACTOR) if sgen_rows else np.zeros((0, steps)),
    )
