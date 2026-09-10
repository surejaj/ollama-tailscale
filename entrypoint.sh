#!/bin/bash
set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-${RUNPOD_SECRET_TSAUTH_KEY:-}}"
: "${TS_AUTHKEY:?TS_AUTHKEY (or RunPod secret TSAUTH_KEY) is required — generate a fresh ephemeral key each run}"
TS_HOSTNAME="${TS_HOSTNAME:-ollama-5090}"
OLLAMA_MODEL="${OLLAMA_MODEL:-hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-16384}"
OLLAMA_ORIGINS="${OLLAMA_ORIGINS:-*}"

export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_CONTEXT_LENGTH
export OLLAMA_ORIGINS

TS_SOCKET=/var/run/tailscale/tailscaled.sock
mkdir -p /var/lib/tailscale /var/run/tailscale

echo "==> Starting tailscaled (userspace networking — RunPod pods aren't granted NET_ADMIN/TUN)"
tailscaled \
  --tun=userspace-networking \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket="${TS_SOCKET}" &

# `tailscale status` exits non-zero while logged out (NeedsLogin), by design —
# it answers "are we connected", not "is the daemon up". So check for the
# daemon's socket instead; it appears well before login state matters.
for i in $(seq 1 30); do
  [ -S "${TS_SOCKET}" ] && break
  if [ "$i" -eq 30 ]; then
    echo "FATAL: tailscaled did not become ready in time" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Authenticating to tailnet as ${TS_HOSTNAME}"
if ! tailscale --socket="${TS_SOCKET}" up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME}" \
    --accept-dns=true; then
  echo "FATAL: tailscale up failed — authkey is likely invalid, expired, or already consumed" >&2
  exit 1
fi

echo "==> Starting ollama serve"
ollama serve &
OLLAMA_PID=$!

echo "==> Waiting for ollama API to come up"
for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
  if [ "$i" -eq 60 ]; then
    echo "FATAL: ollama server did not become ready in time" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Pulling model: ${OLLAMA_MODEL}"
if ! ollama pull "${OLLAMA_MODEL}"; then
  echo "FATAL: model pull failed for ${OLLAMA_MODEL}" >&2
  exit 1
fi

echo "==> Exposing ollama over the tailnet via tailscale serve"
if ! tailscale --socket="${TS_SOCKET}" serve --bg --https=443 http://127.0.0.1:11434; then
  echo "FATAL: tailscale serve failed to configure" >&2
  exit 1
fi

echo "==> Ready (model: ${OLLAMA_MODEL}, ctx: ${OLLAMA_CONTEXT_LENGTH}) — see the tailnet URL printed by 'tailscale serve' above"

wait "${OLLAMA_PID}"
