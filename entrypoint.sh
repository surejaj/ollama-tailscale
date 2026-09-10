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
OLLAMA_MODEL="${OLLAMA_MODEL:-hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"
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

echo "==> Cleaning up stale same-hostname nodes (if an admin authkey is provided)"
# Tailscale only appends a dedup suffix (-2, -3, -5, …) to the requested
# hostname when some other node in this tailnet was registered earlier with
# the same base name. With no persisted tailscaled state, every terminated pod
# leaves a zombie node behind, so without cleanup the suffix number grows by
# one on every new pod. Admin API note: a node's `HostName` field is the base
# name *without* the suffix — that's why matching on it finds the stale
# siblings (our own Name/DNSName carries the suffix, but HostName doesn't).
ACTUAL_HOSTNAME=$(tailscale --socket="${TS_SOCKET}" status --json | jq -r '.Self.HostName')
if [ -n "${TS_ADMIN_AUTHKEY}" ] && [ "${ACTUAL_HOSTNAME}" != "${TS_HOSTNAME}" ]; then
  echo "==> Hostname came back as '${ACTUAL_HOSTNAME}' (requested '${TS_HOSTNAME}') — deleting stale nodes claiming it"
  SELF_NODE_ID=$(tailscale --socket="${TS_SOCKET}" status --json | jq -r '.Self.NodeID')
  STALE_NODE_IDS=$(curl -sf -H "Authorization: Bearer ${TS_ADMIN_AUTHKEY}" \
    "https://api.tailscale.com/api/v2/tailnet/nodes" | \
    jq -r --arg self "${SELF_NODE_ID}" --arg host "${TS_HOSTNAME}" \
    '.[] | select((.ID|tostring) != $self and .HostName == $host) | .ID' || true)
  if [ -n "${STALE_NODE_IDS}" ]; then
    for STALE_ID in ${STALE_NODE_IDS}; do
      echo "==> Deleting stale node ${STALE_ID}"
      curl -sf -X DELETE -H "Authorization: Bearer ${TS_ADMIN_AUTHKEY}" \
        "https://api.tailscale.com/api/v2/tailnet/nodes/${STALE_ID}" || true
    done
  else
    echo "==> No live stale nodes found claiming '${TS_HOSTNAME}' — delete the zombie by hand in the admin console"
  fi
  echo "==> This node keeps its current suffix until the next boot; after the stale nodes above are gone, the next pod will claim '${TS_HOSTNAME}'"
else
  echo "==> Live at hostname: ${ACTUAL_HOSTNAME}"
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

echo "==> Ready (model: ${OLLAMA_MODEL}, ctx: ${OLLAMA_CONTEXT_LENGTH}) — see the tailnet URL printed by 'tailscale serve' above"

wait "${OLLAMA_PID}"
