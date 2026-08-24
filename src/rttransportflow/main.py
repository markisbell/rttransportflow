"""Console entry point: `rttransportflow` starts the API server."""

from __future__ import annotations

import logging

import uvicorn

from .api.runtime import create_app
from .config import Settings


def main() -> None:
    settings = Settings()
    # uvicorn configures only its own loggers; without a root handler the
    # backend's loggers (engine, …) fall back to logging's last-resort
    # WARNING+ stderr path and INFO is lost entirely.
    logging.basicConfig(
        level=settings.log_level.upper(),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_level=settings.log_level,
    )


if __name__ == "__main__":
    main()
