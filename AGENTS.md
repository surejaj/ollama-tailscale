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
| `TS_AUTHKEY` | Yes* | — (fails fast if unset) | Fresh ephemeral Tailscale auth key, generated per run. *Falls back to reading `RUNPOD_SECRET_TSAUTH_KEY` if `TS_AUTHKEY` itself isn't set in-container — but getting a RunPod account secret into either var via the REST `create-pod` API has NOT been made to work yet (see "RunPod secrets" below); as of now `TS_AUTHKEY` must be passed as a plain value via `env` |
| `TS_HOSTNAME` | No | `ollama-5090` | Fixed tailnet hostname / MagicDNS name |
| `OLLAMA_MODEL` | No | `hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL` | Full pull string passed to `ollama pull` — not just a short name, so any HF GGUF repo/tag can be swapped in without touching the Dockerfile |
| `OLLAMA_CONTEXT_LENGTH` | No | `16384` | Context window; see VRAM rationale above before raising |

## Files

- `Dockerfile` — `ollama/ollama:latest` + Tailscale install
- `entrypoint.sh` — orchestrates: `tailscaled` (userspace) → `tailscale up --ssh` →
  `ollama serve` → `ollama pull $OLLAMA_MODEL` → `tailscale serve` → `wait` on
  the Ollama process
- `.github/workflows/docker-publish.yml` — builds and pushes to GHCR on every
  push to `main` that touches the Dockerfile/entrypoint (or manual dispatch),
  tagging `latest` + short commit SHA

**Manual one-time step after the first workflow run:** GHCR packages pushed via
the workflow's `GITHUB_TOKEN` default to **private** — the token can't change
package visibility itself. Go to the repo's Packages tab (or
`github.com/users/<owner>/packages/container/<repo>/settings`) and set the
package visibility to Public, matching the "public image" decision above.

## Verified

- 2026-09-09: `ollama pull hf.co/unsloth/Qwen3.5-27B-GGUF:UD-Q6_K_XL` confirmed
  working on a live RunPod RTX 5090 pod (Community Cloud, `ollama/ollama:latest`
  base image).
- 2026-09-09: first full-entrypoint end-to-end attempt (real `TS_AUTHKEY`,
  published image) caught a real bug before it could burn the ephemeral key —
  see "Bugs found" below. Auth key was not consumed since the script failed
  before reaching `tailscale up`.
- 2026-09-09: second attempt, with the readiness-check fix
  (`ghcr.io/surejaj/ollama-tailscale:sha-efab8cc`), got much further:
  `tailscaled` came up correctly, `tailscale up` **succeeded** with the real
  key, `ollama serve` started, and `ollama pull` downloaded the main 25GB
  model blob completely. It then hit a transient HuggingFace timeout
  (`context deadline exceeded`) fetching a small ~931MB secondary blob —
  external flakiness, not an entrypoint bug — and exited via the fail-fast
  path as designed. A `restart` (which preserves container disk, so the
  already-downloaded 25GB blob and Tailscale state would carry over) was
  attempted to resume the pull, but by then the ephemeral authkey had
  expired, so `tailscale up` failed on the retry and the pod ended.
  **`tailscale serve` and the final ready state have still not been
  observed** — everything up to a completed model pull is confirmed working,
  but the last step (exposing over the tailnet) remains unverified end-to-end.

## Bugs found in testing

**Readiness check used `tailscale status`, which fails while logged out.**
`tailscale status` intentionally exits non-zero in the `NeedsLogin` state — it
answers "are we connected to the tailnet", not "is the daemon process up". The
entrypoint used it to detect "is `tailscaled` ready for `tailscale up`", so it
always timed out and exited before ever attempting authentication, even though
the daemon was healthy. Fixed by checking for the daemon's Unix socket file
(`/var/run/tailscale/tailscaled.sock`) existing instead — that appears as soon
as `tailscaled` binds it, well before login state is relevant.

## Live capacity constraints discovered during testing

RTX 5090 stock is scarce enough (LOW everywhere, frequently zero in practice)
that `create-pod` calls pinned to a specific data center often fail with "no
instances available," even when the catalog lists that DC as having stock —
the catalog label lags real-time availability. Calls with **no**
`dataCenterIds` succeed far more often (the scheduler can place anywhere), but
that's incompatible with attaching a network volume, since volumes are
DC-pinned and a mount can't be added to a pod after creation. In practice this
means: persistence (network volume) and "deploy right now" are sometimes in
tension — when the volume-compatible DCs (US-GA-2 / EU-RO-1 / EUR-IS-1 at last
check) have no 5090 stock, either wait/retry those DCs, or run without the
volume temporarily and accept the model re-downloading.

A 50GB Standard network volume (`a0szef22qu`) was created in US-GA-2 for this
but has not yet been used in a successful deploy, since US-GA-2 had no RTX
5090 stock at test time.

## Image

Published: `ghcr.io/surejaj/ollama-tailscale:sha-6862842` (also tagged `latest`
on `main`) — **contains the `tailscale status` readiness bug above**, fixed in
the entrypoint locally but not yet rebuilt/pushed as of this note. Confirm
visibility is set to Public (see note above) before relying on pulling it
without a registry credential.

## RunPod secrets — not resolved via the REST API (yet)

Tried getting the Tailscale authkey into the container via a RunPod account
secret instead of a plaintext env var, two ways, both failed:

1. Assuming account secrets auto-inject as `RUNPOD_SECRET_<NAME>` env vars
   into every pod automatically: **false** — the pod crash-looped with
   `entrypoint.sh`'s "required" error every ~15-20s (RunPod auto-restarts a
   pod whose container exits), meaning the env var was never present at all.
2. Passing `env: {"TS_AUTHKEY": "{{ RUNPOD_SECRET_TSAUTH_KEY }}"}` in the
   `create-pod` body, assuming the API resolves that templating syntax:
   **also false** — `tailscale up` actually ran with that literal string (or
   something equally invalid) and Tailscale's control server rejected it
   with "invalid key: unable to validate API key." The template substitution
   is most likely a RunPod **web console** feature (picking a secret from a
   dropdown when building a pod there), not something the REST API resolves
   from a literal string.

Until this is figured out (or the user confirms the right API-level syntax),
`TS_AUTHKEY` needs to be passed as its actual plain value in `env` on every
`create-pod` call — the `RUNPOD_SECRET_TSAUTH_KEY` fallback in `entrypoint.sh`
is harmless dead code until then, not a working feature.

## Not yet done

- Figure out the correct way to get a RunPod secret into a pod's env via the
  REST API (see "RunPod secrets" above), or drop the fallback if it turns out
  this genuinely requires the web console
- Confirm the GHCR package visibility is set to Public (see note above — not automatic)
- Re-run the full end-to-end test with a **fresh** `TS_AUTHKEY` — the previous
  key expired mid-test after a transient HF download timeout forced a retry
  (see Verified log above). Everything through a completed model pull is
  confirmed; `tailscale serve` and the final ready state are still unverified
- Get RTX 5090 stock in a volume-compatible DC (US-GA-2 / EU-RO-1 / EUR-IS-1)
  to validate the persistent-volume path specifically, separate from the
  general entrypoint validation above — the 50GB volume (`a0szef22qu`) already
  exists in US-GA-2 but has never been used in a successful deploy
