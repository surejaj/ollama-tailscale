#!/bin/bash
set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-${RUNPOD_SECRET_TSAUTH_KEY:-}}"
: "${TS_AUTHKEY:?TS_AUTHKEY (or RunPod secret TSAUTH_KEY) is required — generate a fresh ephemeral key each run}"
TS_HOSTNAME="${TS_HOSTNAME:-ollama-6000ada}"
# Optional long-lived admin authkey. The -N hostname dedup suffix (e.g.
# ollama-6000ada-5) appears whenever a stale node from a previous (terminated,
# never-cleaned-up) pod run is still registered in the tailnet under the same
# base hostname. With this set, the entrypoint deletes those stale nodes
# automatically after `tailscale up`; without it they must be removed by hand
# in the tailnet admin console.
TS_ADMIN_AUTHKEY="${TS_ADMIN_AUTHKEY:-${RUNPOD_SECRET_TSADMINAUTH_KEY:-}}"
# Ollama-library tag, not the hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL quant
# originally intended: that HF pull failed 4/4 times on the same blob timeout.
# Lower-precision quant, deliberately traded for a pull that terminates. Accepts
# a full hf.co/... string too, so it can be pointed back if the passthrough is fixed.
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.8:27b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"
OLLAMA_ORIGINS="${OLLAMA_ORIGINS:-*}"
# Halves KV cache memory vs the fp16 default (perplexity cost ~0.002-0.05), which
# is what makes a 128K context fit in 48GB alongside ~17GB of weights. Requires
# flash attention — auto-enabled where the backend supports it. WARNING: on an
# architecture that doesn't support it, Ollama silently falls back to fp16 and
# doubles KV usage, so verify with `ollama ps` (expect 100% GPU) before trusting
# a large context. Set to f16 to disable.
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
# Ollama splits OLLAMA_CONTEXT_LENGTH across parallel slots and auto-picks the
# slot count from available memory. Left on auto, a pod can silently allocate
# several times the expected KV, or hand each request a fraction of the context
# configured above. This is a single-user tailnet endpoint, so pin it to 1.
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"

export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_CONTEXT_LENGTH
export OLLAMA_ORIGINS
export OLLAMA_KV_CACHE_TYPE
export OLLAMA_NUM_PARALLEL

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

# Reap stale nodes BEFORE `tailscale up`, not after. Tailscale only appends a
# dedup suffix (-2, -3, -5, …) when another node already holds the base name, so
# the zombie has to be gone *before* we register — cleaning up afterwards leaves
# this boot stuck with its suffix and only helps the next one. With no persisted
# tailscaled state every run is a fresh identity, so any node still claiming
# TS_HOSTNAME at this point is stale by definition.
# Single-pod assumption: if a second pod is legitimately serving under the same
# TS_HOSTNAME, this deletes it. Give concurrent pods distinct TS_HOSTNAMEs.
if [ -n "${TS_ADMIN_AUTHKEY}" ]; then
  echo "==> Reaping stale nodes claiming '${TS_HOSTNAME}' before registering"
  # `-` means "the default tailnet for these credentials". API keys authenticate
  # as HTTP basic with an empty password. The list response is {"devices":[...]}
  # and its fields are lowercase (.id, .hostname) — unlike the CLI's status --json.
  STALE_IDS=$(curl -sf -u "${TS_ADMIN_AUTHKEY}:" \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" | \
    jq -r --arg host "${TS_HOSTNAME}" \
    '.devices[] | select(.hostname == $host) | .id' || true)
  if [ -n "${STALE_IDS}" ]; then
    for STALE_ID in ${STALE_IDS}; do
      echo "==> Deleting stale node ${STALE_ID}"
      curl -sf -X DELETE -u "${TS_ADMIN_AUTHKEY}:" \
        "https://api.tailscale.com/api/v2/device/${STALE_ID}" >/dev/null \
        || echo "WARN: could not delete node ${STALE_ID}" >&2
    done
  else
    echo "==> No stale nodes claiming '${TS_HOSTNAME}'"
  fi
else
  echo "==> TS_ADMIN_AUTHKEY not set — skipping stale-node reap; expect a -N suffix if a zombie still holds '${TS_HOSTNAME}'"
fi

echo "==> Authenticating to tailnet as ${TS_HOSTNAME}"
if ! tailscale --socket="${TS_SOCKET}" up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME}" \
    --accept-dns=true; then
  echo "FATAL: tailscale up failed — authkey is likely invalid, expired, or already consumed" >&2
  exit 1
fi

# Report the name actually granted. `.Self.HostName` is the *suffix-free* base
# name and so always equals TS_HOSTNAME — comparing against it was the bug that
# made the old cleanup branch unreachable. `.Self.DNSName` carries the real name
# ("ollama-6000ada-3.<tailnet>.ts.net."), so take its first label.
ACTUAL_NAME=$(tailscale --socket="${TS_SOCKET}" status --json | jq -r '.Self.DNSName' | cut -d. -f1)
if [ "${ACTUAL_NAME}" != "${TS_HOSTNAME}" ]; then
  echo "WARN: registered as '${ACTUAL_NAME}', not '${TS_HOSTNAME}' — another node still held the base name." >&2
  echo "WARN: clients pointed at '${TS_HOSTNAME}' will NOT reach this pod. Set TS_ADMIN_AUTHKEY, or delete the zombie by hand." >&2
else
  echo "==> Live at hostname: ${ACTUAL_NAME}"
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

# Ollama's own DNS-rebinding protection only activates when it's bound to
# loopback (see AGENTS.md "Bugs found" — allowedHostsMiddleware skips the
# check entirely for non-loopback binds), and it hardcodes the allowed Host
# header to "localhost"/the container hostname/.local/.internal — no env var
# controls this. `tailscale serve` proxies with the original tailnet Host
# header intact, which matches none of those, so it gets a 403 straight from
# ollama. Rather than bind ollama off loopback (which would defeat the point
# of loopback-only binding), run a tiny local nginx that rewrites the Host
# header to "localhost" and sits between `tailscale serve` and ollama.
OLLAMA_PROXY_PORT=8080
cat > /tmp/ollama-hostfix.conf <<EOF
daemon off;
worker_processes 1;
pid /tmp/ollama-hostfix.pid;
error_log /dev/stderr warn;
events { worker_connections 64; }
http {
  access_log off;
  server {
    listen 127.0.0.1:${OLLAMA_PROXY_PORT};
    location / {
      proxy_pass http://127.0.0.1:11434;
      proxy_set_header Host localhost;
      proxy_http_version 1.1;
    }
  }
}
EOF

echo "==> Starting local Host-header-rewrite proxy on 127.0.0.1:${OLLAMA_PROXY_PORT}"
nginx -c /tmp/ollama-hostfix.conf &

echo "==> Waiting for the proxy to come up"
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:${OLLAMA_PROXY_PORT}/api/tags" >/dev/null 2>&1 && break
  if [ "$i" -eq 30 ]; then
    echo "FATAL: Host-header-rewrite proxy did not become ready in time" >&2
    exit 1
  fi
  sleep 1
done

echo "==> Exposing ollama over the tailnet via tailscale serve"
if ! tailscale --socket="${TS_SOCKET}" serve --bg --https=443 "http://127.0.0.1:${OLLAMA_PROXY_PORT}"; then
  echo "FATAL: tailscale serve failed to configure" >&2
  exit 1
fi

echo "==> Ready (model: ${OLLAMA_MODEL}, ctx: ${OLLAMA_CONTEXT_LENGTH}, kv: ${OLLAMA_KV_CACHE_TYPE}, parallel: ${OLLAMA_NUM_PARALLEL}) — see the tailnet URL printed by 'tailscale serve' above"
# Ollama loads lazily, so none of the above proves the model actually fit in VRAM
# at this context length — that only happens on the first real request. Force it
# now with a 1-token generation so a bad fit surfaces here in the boot log rather
# than on the user's first prompt. Loading honours OLLAMA_CONTEXT_LENGTH, so this
# allocates the full KV cache. Non-fatal: a failure here is worth seeing, but the
# server is already serving and shouldn't be torn down over a warm-up.
echo "==> Warming up (forces model load + full KV allocation)"
curl -fsS --max-time 300 http://127.0.0.1:11434/api/generate \
  -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}" \
  >/dev/null || echo "WARN: warm-up request failed — check VRAM fit at ctx ${OLLAMA_CONTEXT_LENGTH}" >&2
# Anything less than 100% GPU means layers spilled to CPU, most likely because
# the KV cache quantization silently fell back to fp16 on an unsupported arch.
echo "==> VRAM/offload split (expect 100% GPU):"
ollama ps || true

wait "${OLLAMA_PID}"
