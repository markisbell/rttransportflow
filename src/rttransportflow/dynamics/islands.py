"""Island partition: connected components of the in-service grid graph.

P2 runs a single connected island; splits/merges arrive with protection (P8).
The partition function is real from day one so nothing assumes island 0.
"""

from __future__ import annotations


def connected_components(
    bus_names: list[str], edges: list[tuple[str, str, bool]]
) -> dict[str, int]:
    """Map bus name -> island index. `edges` are (from, to, in_service)."""
    parent = {b: b for b in bus_names}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for a, b, in_service in edges:
        if in_service:
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[ra] = rb

    roots: dict[str, int] = {}
    result: dict[str, int] = {}
    for bus in bus_names:
        root = find(bus)
        if root not in roots:
            roots[root] = len(roots)
        result[bus] = roots[root]
    return result
