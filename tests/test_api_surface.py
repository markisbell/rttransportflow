"""Pin the route inventory (family rule: the surface never changes silently)."""

from __future__ import annotations

EXPECTED_ROUTES = {
    ("GET", "/"),
    ("GET", "/health"),
    ("GET", "/status"),
    ("GET", "/state"),
    ("GET", "/history"),
    ("GET", "/network"),
    ("GET", "/export.jsonl"),
    ("WS", "/ws"),
    ("POST", "/control/start"),
    ("POST", "/control/pause"),
    ("POST", "/control/resume"),
}

DOC_PATHS = ("/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc")


def _walk(routes):
    for route in routes:
        # FastAPI >= 0.141 wraps include_router() results in _IncludedRouter
        # containers; the actual APIRoutes sit on .original_router.routes.
        inner = getattr(route, "original_router", None)
        if inner is not None:
            yield from _walk(inner.routes)
        else:
            yield route


def test_route_inventory(app) -> None:
    found = set()
    for route in _walk(app.routes):
        path = getattr(route, "path", None)
        if path is None or path in DOC_PATHS:
            continue
        methods = getattr(route, "methods", None)
        if methods is None:
            found.add(("WS", path))
        else:
            for m in methods - {"HEAD", "OPTIONS"}:
                found.add((m, path))
    assert found == EXPECTED_ROUTES
