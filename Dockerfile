FROM python:3.12-slim

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src/ src/
RUN pip install --no-cache-dir .

COPY data/ data/

ENV RTTRANSPORTFLOW_HOST=0.0.0.0 \
    RTTRANSPORTFLOW_PORT=8003
EXPOSE 8003

CMD ["rttransportflow"]
