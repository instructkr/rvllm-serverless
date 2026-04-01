# rvLLM Serverless for RunPod

![Status: WIP](https://img.shields.io/badge/status-WIP-orange)

RunPod Serverless wrapper for [`rvLLM`](https://github.com/m0at/rvllm), keeping the Rust inference server intact and adding only the minimal serverless layer needed for deployment.

This repo follows the shape of the official RunPod worker repos:

- a thin Python `runpod.serverless.start(...)` handler
- `rvllm serve` running as the local OpenAI-compatible backend
- generic-image deployment with `MODEL_ID` at runtime
- baked-image deployment with a model snapshot inside the image

## Current Status

- generic serverless image is built and published
- tested against real RunPod GPU workers
- validated startup path after fixing missing PTX kernel packaging
- still WIP in the sense that the deployment ergonomics and tuning will keep improving

## Published Image

Current test image:

- `reniyap/rvllm-serverless:exp-20260401`
- digest: `sha256:9fa7c365b125f15ad7f703d7952ba5b41291e8d14bea00efa0be52cdf2552e0d`

If you want the most deterministic pull in RunPod, use the digest form:

```text
reniyap/rvllm-serverless@sha256:9fa7c365b125f15ad7f703d7952ba5b41291e8d14bea00efa0be52cdf2552e0d
```

## Why This Shape

`rvLLM` already handles the core inference work:

- OpenAI-compatible HTTP API
- Hugging Face model-id loading
- Rust-native runtime with much smaller overhead than Python `vLLM`

This serverless layer only does three things:

1. Launch `rvllm serve` with env-driven configuration.
2. Wait for `/health`.
3. Proxy RunPod jobs to the local OpenAI-compatible API.

That keeps `rvLLM` itself respected and avoids growing a second inference implementation in Python.

## Quick Start

### Option 1. Use the Published Image in RunPod

In RunPod Serverless:

1. Create a `Custom deployment`.
2. Choose `Deploy from Docker registry`.
3. Use the image above.
4. Set endpoint type to `Queue-based`.
5. Leave `Container start command` empty.
6. Leave `Expose HTTP ports` and `Expose TCP ports` empty.
7. Add runtime env vars like this:

```env
MODEL_ID=Qwen/Qwen2.5-7B-Instruct
DTYPE=half
MAX_MODEL_LEN=4096
GPU_MEMORY_UTILIZATION=0.80
MAX_NUM_SEQS=16
MAX_CONCURRENCY=4
```

For gated/private models, add `HF_TOKEN` as a RunPod Secret.

### Option 2. Build Your Own Image

```bash
cd rvLLM-serverless
./scripts/build.sh --tag your-registry/rvllm-serverless:latest --push
```

To inspect the generated Docker command without building:

```bash
cd rvLLM-serverless
./scripts/build.sh --tag your-registry/rvllm-serverless:latest --dry-run
```

### Option 3. Bake a Model into the Image

```bash
cd rvLLM-serverless
HF_TOKEN=hf_xxx ./scripts/build.sh \
  --tag your-registry/rvllm-serverless:qwen25-7b \
  --bake-model \
  --model-id Qwen/Qwen2.5-7B-Instruct \
  --push
```

For baked images, use runtime env like:

```env
MODEL_TARGET=/models/default
SERVED_MODEL_NAME=Qwen/Qwen2.5-7B-Instruct
DTYPE=half
MAX_MODEL_LEN=4096
GPU_MEMORY_UTILIZATION=0.80
MAX_NUM_SEQS=16
MAX_CONCURRENCY=4
```

## How To Call It

This is a queue-based RunPod worker, so call the RunPod endpoint APIs, not the container port directly.

### List Models

```bash
curl --request POST \
  --url "https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync" \
  -H "authorization: <RUNPOD_API_KEY>" \
  -H "content-type: application/json" \
  -d '{
    "input": {
      "path": "/v1/models",
      "method": "GET"
    }
  }'
```

### Chat Completion

```bash
curl --request POST \
  --url "https://api.runpod.ai/v2/<ENDPOINT_ID>/runsync" \
  -H "authorization: <RUNPOD_API_KEY>" \
  -H "content-type: application/json" \
  -d '{
    "input": {
      "messages": [
        {"role": "system", "content": "Answer briefly."},
        {"role": "user", "content": "What is rvLLM?"}
      ],
      "temperature": 0.2,
      "max_tokens": 128
    }
  }'
```

### Streamed Chat Completion

```bash
curl --request POST \
  --url "https://api.runpod.ai/v2/<ENDPOINT_ID>/run" \
  -H "authorization: <RUNPOD_API_KEY>" \
  -H "content-type: application/json" \
  -d '{
    "input": {
      "messages": [
        {"role": "user", "content": "Write three bullet points about rvLLM."}
      ],
      "stream": true,
      "max_tokens": 128
    }
  }'
```

Then read the stream with the returned job id:

```bash
curl --request GET \
  --url "https://api.runpod.ai/v2/<ENDPOINT_ID>/stream/<JOB_ID>" \
  -H "authorization: <RUNPOD_API_KEY>"
```

## Configuration

### Core Runtime Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL_ID` | unset | Public Hugging Face model id for generic images. |
| `MODEL_TARGET` | unset | Actual value passed to `rvllm serve --model`. |
| `SERVED_MODEL_NAME` | `MODEL_ID` or `MODEL_TARGET` | Public model name exposed to clients. |
| `TOKENIZER_ID` | unset | Optional tokenizer override. |
| `HF_TOKEN` | unset | Hugging Face token for gated/private models. |
| `HF_HOME` | `/runpod-volume/huggingface` | Hugging Face cache root. |
| `HUGGINGFACE_HUB_CACHE` | `${HF_HOME}/hub` | Hugging Face hub cache path. |
| `RVLLM_PORT` | `8000` | Local port used by `rvllm serve`. |
| `MAX_CONCURRENCY` | `30` | RunPod worker concurrency hint. |
| `SERVER_READY_TIMEOUT` | `900` | Startup timeout in seconds. |
| `REQUEST_TIMEOUT` | `600` | Proxy request timeout in seconds. |

### `rvLLM` Launch Variables

| Variable | Default |
| --- | --- |
| `DTYPE` | `auto` |
| `MAX_MODEL_LEN` | `2048` |
| `GPU_MEMORY_UTILIZATION` | `0.9` |
| `TENSOR_PARALLEL_SIZE` | `1` |
| `MAX_NUM_SEQS` | `256` |
| `RUST_LOG` | `info` |
| `DISABLE_TELEMETRY` | `false` |

## Job Input Contract

The worker accepts two styles of input.

### Direct OpenAI-Style Input

If `input` contains `messages`, it becomes `/v1/chat/completions`.

```json
{
  "input": {
    "messages": [
      { "role": "user", "content": "What is rvLLM?" }
    ],
    "max_tokens": 128
  }
}
```

If `input` contains `prompt`, it becomes `/v1/completions`.

```json
{
  "input": {
    "prompt": "Write a one-line summary of RunPod Serverless.",
    "max_tokens": 64
  }
}
```

If `model` is omitted, the worker injects `SERVED_MODEL_NAME`.

### Explicit Proxy Input

If you want direct control over the local endpoint:

```json
{
  "input": {
    "path": "/v1/chat/completions",
    "method": "POST",
    "body": {
      "model": "Qwen/Qwen2.5-7B-Instruct",
      "messages": [
        { "role": "user", "content": "Return JSON only." }
      ],
      "stream": true
    }
  }
}
```

## Repository Layout

```text
rvLLM-serverless/
├── .runpod/hub.json
├── builder/
│   ├── download_model.py
│   └── requirements.txt
├── scripts/
│   ├── build.sh
│   └── smoke_test.sh
├── src/
│   ├── config.py
│   ├── handler.py
│   ├── proxy.py
│   ├── request_mapping.py
│   └── server_launcher.py
└── tests/
    ├── test_config.py
    └── test_request_mapping.py
```

## Verification

What has been verified so far:

- local Python tests for config and request mapping
- local Docker build flow on macOS with `linux/amd64`
- published Docker image build and push
- real RunPod GPU startup testing
- startup fix for missing PTX kernel packaging

Run local checks:

```bash
cd rvLLM-serverless
./scripts/smoke_test.sh
```

## Notes

- The wrapper intentionally targets the existing `rvllm serve` CLI surface.
- This repo is meant to stay thin. Inference behavior belongs in `rvLLM`, not here.
- PTX kernels are compiled during image build and packaged into the runtime image.
