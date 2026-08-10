"""JSONL run recorder: one wire frame per line, flushed per step."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, TextIO


class Recorder:
    def __init__(self, directory: str | Path) -> None:
        d = Path(directory)
        d.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.path = d / f"run-{stamp}.jsonl"
        self._fh: TextIO = self.path.open("a")

    def record(self, wire: dict[str, Any]) -> None:
        self._fh.write(json.dumps(wire, separators=(",", ":")) + "\n")
        self._fh.flush()

    def close(self) -> None:
        self._fh.close()
