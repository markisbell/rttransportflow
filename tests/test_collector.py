from __future__ import annotations

import importlib.util
from pathlib import Path

COLLECTOR = Path(__file__).resolve().parent.parent / "visualization" / "collector.py"


def _load_collector():
    spec = importlib.util.spec_from_file_location("collector", COLLECTOR)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_to_lines_line_protocol() -> None:
    c = _load_collector()
    state = {
        "step": 5,
        "day": 1,
        "converged": True,
        "solve_ms": 6.25,
        "summary": {"load_mw": 33480.0, "loss_mw": 196.7, "min_vm_pu": 1.02},
        "lines": {"lyon-milan": {"loading_percent": 69.9, "p_from_mw": 1500.0, "pl_mw": 12.0}},
        "buses": {"paris": {"vm_pu": 1.02, "va_degree": -3.5}},
    }
    body = c.to_lines(state, 1234567890)
    lines = body.split("\n")
    assert lines[0].startswith("summary step=5i,day=1i,converged=1i,solve_ms=6.25")
    assert "load_mw=33480.0" in lines[0]
    assert lines[0].endswith(" 1234567890")
    assert any(ln.startswith("line,id=lyon-milan loading_percent=69.9") for ln in lines)
    assert any(ln.startswith("bus,name=paris vm_pu=1.02") for ln in lines)


def test_to_lines_degraded_frame_has_no_physics_fields() -> None:
    c = _load_collector()
    state = {"step": 3, "day": 0, "converged": False, "solve_ms": 1.0,
             "summary": {}, "lines": {}, "buses": {}, "error": "LoadflowNotConverged"}
    body = c.to_lines(state, 42)
    assert body == "summary step=3i,day=0i,converged=0i,solve_ms=1.0 42"


def test_tag_escaping() -> None:
    c = _load_collector()
    assert c.esc_tag("a b,c=d") == "a\\ b\\,c\\=d"
