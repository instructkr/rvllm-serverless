FROM nvidia/cuda:13.0.1-devel-ubuntu24.04 AS rvllm-builder

RUN apt-get update && apt-get install -y curl build-essential pkg-config libssl-dev && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /build/rvllm
COPY rvllm /build/rvllm
RUN bash kernels/build.sh
RUN cargo build --release --features cuda -p rvllm-server

FROM nvidia/cuda:13.0.1-runtime-ubuntu24.04 AS runtime

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    libssl3t64 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY rvLLM-serverless/builder/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/python -m pip install --upgrade pip && \
    /opt/venv/bin/python -m pip install --no-cache-dir -r /tmp/requirements.txt

COPY --from=rvllm-builder /build/rvllm/target/release/rvllm /usr/local/bin/rvllm
COPY --from=rvllm-builder /build/rvllm/kernels/*.ptx /usr/local/share/rvllm/kernels/

ARG BAKE_MODEL=false
ARG MODEL_ID=""
ARG MODEL_REVISION="main"
ARG MODEL_DIR="/models/default"

ENV PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:${PATH} \
    RVLLM_KERNEL_DIR=/usr/local/share/rvllm/kernels \
    HF_HOME=/runpod-volume/huggingface \
    HUGGINGFACE_HUB_CACHE=/runpod-volume/huggingface/hub \
    MODEL_ID=${MODEL_ID} \
    SERVED_MODEL_NAME=${MODEL_ID}

COPY rvLLM-serverless/builder /opt/rvllm-serverless/builder
RUN --mount=type=secret,id=HF_TOKEN,required=false \
    if [ "${BAKE_MODEL}" = "true" ] && [ -n "${MODEL_ID}" ]; then \
        export HF_TOKEN=""; \
        if [ -f /run/secrets/HF_TOKEN ]; then \
            export HF_TOKEN="$(cat /run/secrets/HF_TOKEN)"; \
        fi; \
        python3 /opt/rvllm-serverless/builder/download_model.py \
            --model-id "${MODEL_ID}" \
            --revision "${MODEL_REVISION}" \
            --target-dir "${MODEL_DIR}"; \
    fi

ENV MODEL_DIR=${MODEL_DIR}

COPY rvLLM-serverless/src /opt/rvllm-serverless/src

WORKDIR /opt/rvllm-serverless
CMD ["python3", "/opt/rvllm-serverless/src/handler.py"]
