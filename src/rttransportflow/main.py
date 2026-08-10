"""Console entry point: `rttransportflow` starts the API server."""

from __future__ import annotations

import uvicorn

from .api.runtime import create_app
from .config import Settings


def main() -> None:
    settings = Settings()
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
    )


if __name__ == "__main__":
    main()
