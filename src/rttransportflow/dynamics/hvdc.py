"""HVDC point-to-point links (PHYSICS §2.4 converter path, PARAMETERS §1.16).

A link is a paired ±P injection between two terminals: the sending end draws
`p`, the receiving end injects `p·(1 − loss_frac)`, and each end carries half
of the no-load auxiliary (0.15 % P_max while energized — STATCOM service is
not free). H = 0: links never contribute inertia. An embedded link (both
terminals in one island) is therefore frequency-neutral up to its losses —
tripping it is a flow-redistribution contingency, not an infeed loss
(ledger 28).

Wire convention: `dispatch_mw` on a terminal commands flow FROM that
terminal's bus TO the partner (positive export). Internally `p` is the A→B
flow of the first-registered terminal.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from . import US
from ..snapshot import parse_floats, repr_floats

CONVERTER_LOSS_FRAC = 0.01  # per station, two stations per path
CABLE_LOSS_FRAC_PER_100KM = 0.003
NO_LOAD_AUX_FRAC = 0.0015  # of P_max while energized
Q_BAND_FRAC = 0.40  # per terminal, at any P
T_HVDC_S = 0.1


def path_loss_frac(length_km: float) -> float:
    return 2.0 * CONVERTER_LOSS_FRAC + CABLE_LOSS_FRAC_PER_100KM * length_km / 100.0


@dataclass
class HVDCLinks:
    link_ids: list[str] = field(default_factory=list)
    island_a: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))
    island_b: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))
    p_max: np.ndarray = field(default_factory=lambda: np.zeros(0))
    loss_frac: np.ndarray = field(default_factory=lambda: np.zeros(0))
    aux_mw: np.ndarray = field(default_factory=lambda: np.zeros(0))  # total per link
    t_lag_s: np.ndarray = field(default_factory=lambda: np.zeros(0))
    p_set: np.ndarray = field(default_factory=lambda: np.zeros(0))  # A→B command
    p: np.ndarray = field(default_factory=lambda: np.zeros(0))  # A→B state
    online: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=bool))
    # terminals: exactly 2 per link, wire-addressable
    term_ids: list[str] = field(default_factory=list)
    term_link: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))
    term_sign: np.ndarray = field(default_factory=lambda: np.zeros(0))  # +1 = A end
    term_q: np.ndarray = field(default_factory=lambda: np.zeros(0))  # PF only [MVAr]

    _row_of: dict = field(default_factory=dict, repr=False)

    def __post_init__(self) -> None:
        self._row_of = {tid: i for i, tid in enumerate(self.term_ids)}

    @property
    def n(self) -> int:
        return len(self.link_ids)

    def has(self, device_id: str) -> bool:
        return device_id in self._row_of or device_id in self.link_ids

    def command(self, term_id: str, dispatch_mw: float) -> None:
        row = self._row_of[term_id]
        link = self.term_link[row]
        self.p_set[link] = float(np.clip(self.term_sign[row] * dispatch_mw,
                                         -self.p_max[link], self.p_max[link]))

    def command_q(self, term_id: str, q_mvar: float) -> None:
        row = self._row_of[term_id]
        band = Q_BAND_FRAC * self.p_max[self.term_link[row]]
        self.term_q[row] = float(np.clip(q_mvar, -band, band))

    def trip(self, device_id: str) -> None:
        """Trip by terminal OR link id — a converter fault takes the bipole."""
        link = (self.term_link[self._row_of[device_id]]
                if device_id in self._row_of else self.link_ids.index(device_id))
        self.online[link] = False
        self.p[link] = 0.0
        self.p_set[link] = 0.0

    def close(self, device_id: str) -> None:
        link = (self.term_link[self._row_of[device_id]]
                if device_id in self._row_of else self.link_ids.index(device_id))
        self.online[link] = True

    def tick(self, dt_us: int, n_islands: int) -> np.ndarray:
        """Advance the delivery lag; returns per-island net injection [MW]."""
        inj = np.zeros(n_islands)
        if self.n == 0:
            return inj
        a = 1.0 - np.exp(-(dt_us / US) / self.t_lag_s)
        self.p += a * (self.p_set - self.p)
        self.p = np.where(self.online, np.clip(self.p, -self.p_max, self.p_max), 0.0)
        delivered = self.p * (1.0 - self.loss_frac)
        inj_a = np.where(self.p >= 0.0, -self.p, -delivered)
        inj_b = np.where(self.p >= 0.0, delivered, self.p)
        half_aux = np.where(self.online, 0.5 * self.aux_mw, 0.0)
        np.add.at(inj, self.island_a, inj_a - half_aux)
        np.add.at(inj, self.island_b, inj_b - half_aux)
        return inj

    def term_p(self) -> np.ndarray:
        """Per-terminal bus injection [MW] for PF/reporting: negative at the
        sending end (draws |p|), positive at the receiving end (|p|·(1−loss)).
        Aux excluded — it is station-service load, not a bus flow."""
        p = self.p[self.term_link]
        delivered = p * (1.0 - self.loss_frac[self.term_link])
        inj_a = np.where(p >= 0.0, -p, -delivered)
        inj_b = np.where(p >= 0.0, delivered, p)
        return np.where(self.term_sign > 0, inj_a, inj_b)

    def state_dict(self) -> dict:
        rf = repr_floats
        return {"p_set": rf(self.p_set), "p": rf(self.p),
                "online": self.online.tolist(), "term_q": rf(self.term_q)}

    def restore_state(self, state: dict) -> None:
        self.p_set[:] = parse_floats(state["p_set"])
        self.p[:] = parse_floats(state["p"])
        self.online[:] = np.array(state["online"], dtype=bool)
        self.term_q[:] = parse_floats(state["term_q"])


def make_links(pairs: list[dict]) -> HVDCLinks:
    """pairs: one dict per LINK: {link_id, p_max_mw, length_km,
    terminals: [{id, island}, {id, island}]} (order fixes the A end)."""
    n = len(pairs)
    term_ids: list[str] = []
    term_link: list[int] = []
    term_sign: list[float] = []
    for i, pair in enumerate(pairs):
        for j, term in enumerate(pair["terminals"]):
            term_ids.append(term["id"])
            term_link.append(i)
            term_sign.append(1.0 if j == 0 else -1.0)
    return HVDCLinks(
        link_ids=[p["link_id"] for p in pairs],
        island_a=np.array([int(p["terminals"][0].get("island", 0)) for p in pairs],
                          dtype=np.int64) if n else np.zeros(0, dtype=np.int64),
        island_b=np.array([int(p["terminals"][1].get("island", 0)) for p in pairs],
                          dtype=np.int64) if n else np.zeros(0, dtype=np.int64),
        p_max=np.array([float(p["p_max_mw"]) for p in pairs]) if n else np.zeros(0),
        loss_frac=np.array([path_loss_frac(float(p.get("length_km", 0.0)))
                            for p in pairs]) if n else np.zeros(0),
        aux_mw=np.array([NO_LOAD_AUX_FRAC * float(p["p_max_mw"]) for p in pairs])
        if n else np.zeros(0),
        t_lag_s=np.full(n, T_HVDC_S),
        p_set=np.zeros(n),
        p=np.zeros(n),
        online=np.ones(n, dtype=bool),
        term_ids=term_ids,
        term_link=np.array(term_link, dtype=np.int64) if term_ids
        else np.zeros(0, dtype=np.int64),
        term_sign=np.array(term_sign) if term_ids else np.zeros(0),
        term_q=np.zeros(len(term_ids)),
    )
