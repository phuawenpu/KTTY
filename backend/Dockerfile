FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY common/ ./common/
COPY relay/ ./relay/
COPY agent/ ./agent/
RUN cargo build --release -p ktty-relay

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/ktty-relay /usr/local/bin/ktty-relay
EXPOSE 8080
CMD ["ktty-relay", "8080"]
