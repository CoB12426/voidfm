# Build context: repo root (docker-compose.all.yml sets context: .)
ARG BACKEND=cpu

# ── Stage 1: Build s2.cpp (CPU) ──────────────────────────────────────────
FROM debian:bookworm-slim AS s2-builder-cpu
RUN apt-get update && apt-get install -y cmake build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY s2.cpp/ ./
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DS2_CUDA=OFF && \
    cmake --build build --target s2 -j$(nproc)

# ── Stage 1: Build s2.cpp (CUDA) ─────────────────────────────────────────
FROM nvidia/cuda:12.6.3-devel-ubuntu24.04 AS s2-builder-cuda
RUN apt-get update && apt-get install -y cmake build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY s2.cpp/ ./
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DS2_CUDA=ON && \
    cmake --build build --target s2 -j$(nproc)

FROM s2-builder-${BACKEND} AS s2-builder

# ── Stage 2: Runtime (CPU) ────────────────────────────────────────────────
FROM python:3.11-slim AS runtime-cpu
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y libgomp1 && rm -rf /var/lib/apt/lists/*

# ── Stage 2: Runtime (CUDA) ───────────────────────────────────────────────
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04 AS runtime-cuda
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y python3.11 python3-pip libgomp1 && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3.11 /usr/bin/python && \
    ln -sf /usr/bin/python3.11 /usr/bin/python3

FROM runtime-${BACKEND} AS app

WORKDIR /app
COPY --from=s2-builder /build/build/s2 /app/s2
RUN chmod +x /app/s2
COPY s2.cpp/tokenizer.json /app/tokenizer.json
COPY mydj-host/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY mydj-host/ ./

EXPOSE 8000
CMD ["python", "main.py"]
