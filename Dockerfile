# syntax=docker/dockerfile:1.7

# ── المرحلة 0: بناء واجهة المستخدم ─────────────────────────────────────
FROM node:22-alpine AS web-builder
WORKDIR /web
COPY web/package.json web/package-lock.json* ./
RUN npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts
COPY web/ .
RUN npm run build

# ── المرحلة 1: بناء تطبيق Rust ────────────────────────────────────────────
FROM rust:1.94-slim AS builder

WORKDIR /app
ARG ZEROCLAW_CARGO_FEATURES="memory-postgres"

# تثبيت التبعات - تم تبسيط الـ mount تماماً في سطر واحد
RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y pkg-config && rm -rf /var/lib/apt/lists/*

# نسخ المانيفست
COPY Cargo.toml Cargo.lock ./
RUN sed -i 's/members = \[".", "crates\/robot-kit"\]/members = ["."]/' Cargo.toml
RUN mkdir -p src benches && echo "fn main() {}" > src/main.rs && echo "" > src/lib.rs && echo "fn main() {}" > benches/agent_benchmarks.rs

# بناء التبعات - تم تقليل خيارات الـ mount لضمان القبول
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    if [ -n "$ZEROCLAW_CARGO_FEATURES" ]; then \
      cargo build --release --locked --features "$ZEROCLAW_CARGO_FEATURES"; \
    else \
      cargo build --release --locked; \
    fi
RUN rm -rf src benches

# البناء النهائي
COPY src/ src/
COPY benches/ benches/
COPY --from=web-builder /web/dist web/dist
COPY *.rs .
RUN touch src/main.rs

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    rm -rf target/release/.fingerprint/zeroclawlabs-* && \
    if [ -n "$ZEROCLAW_CARGO_FEATURES" ]; then \
      cargo build --release --locked --features "$ZEROCLAW_CARGO_FEATURES"; \
    else \
      cargo build --release --locked; \
    fi && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw

# إعداد البيانات
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace && \
    printf 'workspace_dir = "/zeroclaw-data/workspace"\nconfig_path = "/zeroclaw-data/.zeroclaw/config.toml"\ndefault_provider = "openrouter"\n[gateway]\nport = 42617\nhost = "[::]"\nallow_public_bind = true\n' > /zeroclaw-data/.zeroclaw/config.toml && \
    chown -R 65534:65534 /zeroclaw-data

# ── المرحلة 2: الإنتاج (Release) ─────────────────
FROM gcr.io/distroless/cc-debian13:nonroot AS release

COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=builder /zeroclaw-data /zeroclaw-data

ENV LANG=C.UTF-8 ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace HOME=/zeroclaw-data ZEROCLAW_GATEWAY_PORT=42617
WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617

ENTRYPOINT ["/usr/local/bin/zeroclaw"]
CMD ["gateway"]
