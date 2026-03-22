# syntax=docker/dockerfile:1.7

# ── المرحلة 0: بناء واجهة المستخدم (Frontend) ─────────────────────────────────────
FROM node:22-alpine AS web-builder
WORKDIR /web
COPY web/package.json web/package-lock.json* ./
RUN npm ci --ignore-scripts 2>/dev/null || npm install --ignore-scripts
COPY web/ .
RUN npm run build

# ── المرحلة 1: بناء تطبيق Rust (Builder) ────────────────────────────────────────────
FROM rust:1.94-slim@sha256:da9dab7a6b8dd428e71718402e97207bb3e54167d37b5708616050b1e8f60ed6 AS builder

WORKDIR /app
ARG ZEROCLAW_CARGO_FEATURES="memory-postgres"

# تثبيت التبعات مع تصحيح صياغة الـ mount (بدون مسافات زائدة)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# 1. نسخ ملفات المانيفست لتخزين التبعات مؤقتاً
COPY Cargo.toml Cargo.lock ./
RUN sed -i 's/members = \[".", "crates\/robot-kit"\]/members = ["."]/' Cargo.toml
RUN mkdir -p src benches \
    && echo "fn main() {}" > src/main.rs \
    && echo "" > src/lib.rs \
    && echo "fn main() {}" > benches/agent_benchmarks.rs

# بناء أولى للتبعات (Dependencies Only)
RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    if [ -n "$ZEROCLAW_CARGO_FEATURES" ]; then \
      cargo build --release --locked --features "$ZEROCLAW_CARGO_FEATURES"; \
    else \
      cargo build --release --locked; \
    fi
RUN rm -rf src benches

# 2. نسخ الكود المصدري والبناء النهائي
COPY src/ src/
COPY benches/ benches/
COPY --from=web-builder /web/dist web/dist
COPY *.rs .
RUN touch src/main.rs

RUN --mount=type=cache,id=zeroclaw-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=zeroclaw-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=zeroclaw-target,target=/app/target,sharing=locked \
    rm -rf target/release/.fingerprint/zeroclawlabs-* \
           target/release/deps/zeroclawlabs-* \
           target/release/incremental/zeroclawlabs-* && \
    if [ -n "$ZEROCLAW_CARGO_FEATURES" ]; then \
      cargo build --release --locked --features "$ZEROCLAW_CARGO_FEATURES"; \
    else \
      cargo build --release --locked; \
    fi && \
    cp target/release/zeroclaw /app/zeroclaw && \
    strip /app/zeroclaw

# التحقق من حجم الملف الناتج
RUN size=$(stat -c%s /app/zeroclaw 2>/dev/null || stat -f%z /app/zeroclaw) && \
    if [ "$size" -lt 1000000 ]; then echo "ERROR: binary too small" && exit 1; fi

# إعداد بنية المجلدات والإعدادات الافتراضية
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace && \
    printf '%s\n' \
        'workspace_dir = "/zeroclaw-data/workspace"' \
        'config_path = "/zeroclaw-data/.zeroclaw/config.toml"' \
        'api_key = ""' \
        'default_provider = "openrouter"' \
        'default_model = "anthropic/claude-sonnet-4-20250514"' \
        'default_temperature = 0.7' \
        '' \
        '[gateway]' \
        'port = 42617' \
        'host = "[::]"' \
        'allow_public_bind = true' \
        > /zeroclaw-data/.zeroclaw/config.toml && \
    chown -R 65534:65534 /zeroclaw-data

# ── المرحلة 2: بيئة التطوير (Dev) ────────────────────
FROM debian:trixie-slim@sha256:f6e2cfac5cf956ea044b4bd75e6397b4372ad88fe00908045e9a0d21712ae3ba AS dev
RUN apt-get update && apt-get install -y ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=builder /zeroclaw-data /zeroclaw-data
COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
ENV LANG=C.UTF-8 ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace HOME=/zeroclaw-data
WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617
ENTRYPOINT ["zeroclaw"]
CMD ["gateway"]

# ── المرحلة 3: بيئة الإنتاج النهائية (Production) ─────────────────
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:84fcd3c223b144b0cb6edc5ecc75641819842a9679a3a58fd6294bec47532bf7 AS release

# نسخ الملف التنفيذي والبيانات
COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=builder /zeroclaw-data /zeroclaw-data

# إعدادات البيئة
ENV LANG=C.UTF-8
ENV ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace
ENV HOME=/zeroclaw-data
ENV ZEROCLAW_GATEWAY_PORT=42617

WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617

# فحص الصحة (Healthcheck)
HEALTHCHECK --interval=60s --timeout=10s --retries=3 --start-period=15s \
    CMD ["/usr/local/bin/zeroclaw", "status", "--format=exit-code"]

ENTRYPOINT ["/usr/local/bin/zeroclaw"]
CMD ["gateway"]
