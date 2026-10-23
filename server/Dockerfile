# Multi-stage build for benito-server
FROM rust:1.85-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock* ./
COPY migrations ./migrations
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /app/target/release/benito-server /usr/local/bin/benito-server
ENV BIND_ADDR=0.0.0.0:8080 \
    DATABASE_PATH=/data/data.db \
    SESSION_SECRET=dev-only-change-me
VOLUME ["/data"]
EXPOSE 8080
CMD ["benito-server"]
