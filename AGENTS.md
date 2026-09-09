# runpod-ai

A Docker image that bundles Ollama + Tailscale for deployment on RunPod, exposing a
local LLM over a private tailnet — nothing public-facing.

## Goal

Run Ollama on a RunPod GPU pod (RTX 5090), reachable only via Tailscale, with a
stable hostname across restarts and a model that persists across pod restarts
without needing SSH/file-transfer tooling RunPod doesn't provide.

## Decisions and why

**Serving engine: Ollama, not vLLM.**
The default model quant (Q6_K_XL) is an Unsloth "dynamic quant" GGUF naming
convention, consumed by llama.cpp-based runtimes. Ollama runs on llama.cpp and
has first-class support for these exact files. vLLM's GGUF support is limited/
experimental and built around AWQ/GPTQ/FP8 instead — fighting the framework to
force Q6_K_XL through it isn't worth it, especially for a single-user tailnet
endpoint where vLLM's concurrent-throughput advantage doesn't apply.

**Base image: `FROM ollama/ollama:latest`.**
Already bundles everything needed for NVIDIA GPU inference (auto-detects CUDA via
the NVIDIA container runtime RunPod provides) — Tailscale is layered on top rather
than assembling CUDA + Ollama from scratch.

**Default model: `hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL`.**
Confirmed live on 2026-09-09 by pulling it inside a real RunPod pod (RTX 5090,
Community Cloud) — the tag resolves and Ollama's HF passthrough pulls it
correctly. Note the actual GGUF filename/tag is `UD-Q6_K_XL` (Unsloth-Dynamic
prefix), not bare `Q6_K_XL`.

**Context window: `OLLAMA_CONTEXT_LENGTH=16384` default.**
The 27B model at Q6_K_XL is ~25.7GB; the RTX 5090 has 32GB VRAM, leaving ~6GB
for KV cache + CUDA overhead. 16384 is a safe default within that headroom;
pushing higher (e.g. 32K) is possible but untested — would need to be verified
against real VRAM usage before trusting it.

**Ollama bind + exposure: loopback-only, via `tailscale serve`.**
`OLLAMA_HOST=127.0.0.1:11434` so the only way to reach it is through the
tailnet. RunPod also supports exposing ports publicly, which would silently
bypass this if Ollama bound to `0.0.0.0` — binding to loopback removes that
failure mode structurally rather than relying on remembering not to expose a
port in the pod config. `tailscale serve --bg --https=443` proxies from the
tailnet interface to the loopback address, using Tailscale's own MagicDNS +
HTTPS cert (already enabled on the tailnet this targets).

**Debug access: `tailscale up --ssh`.**
Lets you SSH into the running container over the tailnet
(`ssh <hostname>.<tailnet>.ts.net`) without exposing any port — consistent
with "everything through the tailnet, nothing public."

**Tailscale networking mode: userspace (`tailscaled --tun=userspace-networking`).**
RunPod's pod-create API has no field to grant `NET_ADMIN` or pass through
`/dev/net/tun`, which `tailscaled` normally wants for kernel-level networking.
Userspace mode is Tailscale's supported fallback for unprivileged containers —
`tailscale serve` and `tailscale ssh` are handled inside `tailscaled` itself,
not via OS routing, so nothing else in the design changes. This wasn't a
deliberate tradeoff discussion — it's the only mode that works given RunPod's
API surface.

**Tailscale identity: ephemeral, no state persistence, fixed hostname.**
Each container run gets a *fresh* Tailscale auth key (ephemeral, generated
externally per run) and a fresh node identity — no `tailscaled` state is
persisted across restarts. The old ephemeral node auto-deregisters when it
disconnects, so the new node cleanly claims the same `TS_HOSTNAME` each time.
This keeps the tailnet DNS name stable (what your local Ollama client config
actually depends on) without needing to persist any state.

**Failure handling: fail fast, no retries.**
If `TS_AUTHKEY` is missing/invalid/expired, or the model pull fails, the
entrypoint exits non-zero immediately. This is a manually-launched pod, not an
unattended autoscaling worker — a silent retry loop just burns GPU-hours while
looking healthy. Container lifetime is tied to the foregrounded `ollama serve`
process via `wait`, so if Ollama itself crashes after startup, the container
exits rather than idling as a zombie.

**Model persistence: RunPod network volume mounted at `/root/.ollama`.**
That's Ollama's default model storage path, so no `OLLAMA_MODELS` override is
needed. `ollama pull` is already idempotent (skips blobs it already has), so
the entrypoint always calls it unconditionally rather than writing a custom
existence check — cheap/fast on a warm volume, a real download only on a cold
one. Without this, every pod restart would re-download ~25.7GB.

**Data center: US-GA-2.**
Network volumes are pinned to one data center; pods can only mount a volume in
the same DC. At the time of checking, only US-GA-2, EU-NL-1, and EUR-IS-3 had
both RTX 5090 stock and Standard-tier network volume support — US-GA-2 chosen
for US-based proximity. GPU stock is live and can shift; re-check with
`list-gpu-types`/`list-data-centers` (include=AVAILABILITY) before assuming
this still holds.

**Deployment style: ad-hoc `create-pod` calls, not a saved RunPod Template.**
No pre-baked template — each deploy specifies image/GPU/env/volume directly.

**Ports: zero exposed on the RunPod pod config.**
Tailscale serve and Tailscale SSH are both outbound-initiated (via DERP relay/
NAT traversal), so no inbound RunPod port mapping is needed at all. This also
means there's no fallback path in if Tailscale itself fails to connect —
consistent with the fail-fast choice.

**Container disk: 20GB** (ephemeral, separate from the network volume — just
needs room for the OS layer, Ollama binary, Tailscale, and scratch space; the
model itself lives on the network volume).

**Registry: GitHub Container Registry (ghcr.io), public image.**
Nothing sensitive is baked into the image — `TS_AUTHKEY` and `OLLAMA_MODEL` are
runtime env vars, not build-time secrets — so a public image avoids registry
credential setup (`create-registry`) entirely.

## Environment variables

| Var | Required | Default | Purpose |
|---|---|---|---|
| `TS_AUTHKEY` | Yes | — (fails fast if unset) | Fresh ephemeral Tailscale auth key, generated per run |
| `TS_HOSTNAME` | No | `ollama-5090` | Fixed tailnet hostname / MagicDNS name |
| `OLLAMA_MODEL` | No | `hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL` | Full pull string passed to `ollama pull` — not just a short name, so any HF GGUF repo/tag can be swapped in without touching the Dockerfile |
| `OLLAMA_CONTEXT_LENGTH` | No | `16384` | Context window; see VRAM rationale above before raising |

## Files

- `Dockerfile` — `ollama/ollama:latest` + Tailscale install
- `entrypoint.sh` — orchestrates: `tailscaled` (userspace) → `tailscale up --ssh` →
  `ollama serve` → `ollama pull $OLLAMA_MODEL` → `tailscale serve` → `wait` on
  the Ollama process

## Verified

- 2026-09-09: `ollama pull hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL` confirmed
  working on a live RunPod RTX 5090 pod (Community Cloud, `ollama/ollama:latest`
  base image).

## Not yet done

- Build and push the image to GHCR
- Create the actual network volume in US-GA-2
- End-to-end `create-pod` run of the finished image (only the base image + pull
  step have been live-tested so far, not the full entrypoint with Tailscale)
