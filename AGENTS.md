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

**Correction (2026-09-10): container disk is wiped on every restart, not just
`terminate`.** RunPod's own field description says as much ("Container disk in
GB (ephemeral, wiped on restart)"), but this was initially misread as only
applying to `terminate`. Confirmed live: after a pod-action `stop`+`start`
(and separately after `restart`), the container came back with `total blobs:
0` — the entire model had to redownload from scratch, not resume. **This
means the network volume is not optional for surviving restarts** — without
it mounted, every single restart re-downloads the full ~25.7GB, no exceptions.

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
  path as designed. A `restart` was attempted to resume the pull (wrongly
  assumed at the time to preserve container disk — see the correction
  below), but by then the ephemeral authkey had expired, so `tailscale up`
  failed on the retry and the pod ended.
- 2026-09-10: fresh authkey, same image. `tailscale up` **succeeded** again
  (confirmed the key is reusable, not single-use), `ollama serve` started,
  and the pull hit the **exact same secondary blob** (`29fe388bf3a4`,
  `sha256:f5a96332581f326b84ecf20412aaa17529e5ef6f3531f7f9a50ddbd81324c49a`)
  with the identical `context deadline exceeded` timeout — **four times in a
  row** across this session (once on the prior key, three times on this one,
  including two full pod restarts). Always after the main 25GB blob
  completes; always this one ~931MB file. This is conclusive: a persistent
  problem with that specific blob on HuggingFace's CDN, not transient
  flakiness. **`tailscale serve` and the final ready state remain
  unverified** — every attempt has died at the model-pull step before
  reaching it. Next step should be trying a different Unsloth quant tag
  (e.g. `Q6_K` instead of `UD-Q6_K_XL` — different blob composition, likely
  avoids this file) rather than continuing to retry the same pull.

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

Current: `ghcr.io/surejaj/ollama-tailscale:sha-13dc1e3` (also tagged `latest`
on `main`) — includes the readiness-check fix and the (currently-dead-code)
RunPod-secret fallback. Confirm GHCR visibility is set to Public (see note
above) before relying on pulling it without a registry credential.

## RunPod secrets — confirmed NOT usable via the REST API

Per RunPod's docs (docs.runpod.io/pods/templates/secrets), the templating
syntax `{{ RUNPOD_SECRET_<name> }}` in an env var value is how you reference
an account secret — but that page only documents it for the web console.
Tried three ways to get the Tailscale authkey in via the account secret
`TSAUTH_KEY` instead of a plaintext env var; all three failed on live pods:

1. Assuming account secrets auto-inject as `RUNPOD_SECRET_<NAME>` env vars
   into every pod automatically: **false** — the pod crash-looped with
   `entrypoint.sh`'s "required" error every ~15-20s (RunPod auto-restarts a
   pod whose container exits), meaning the env var was never present at all.
2. Passing `env: {"TS_AUTHKEY": "{{ RUNPOD_SECRET_TSAUTH_KEY }}"}` directly
   in an ad-hoc `create-pod` body: **false** — `tailscale up` ran with that
   literal/unresolved value and Tailscale's control server rejected it with
   "invalid key: unable to validate API key."
3. Same env value, but defined on a saved Template (`create-template`) and
   launched via `templateId` instead of ad-hoc, on the theory the docs'
   "environment variables section of templates" phrasing meant it only
   resolves for template-defined env vars: **also false** — identical
   "invalid key: unable to validate API key" error.

Conclusion: this templating syntax is web-console-only as of this test; the
REST API (`create-pod`/`create-template`) does not resolve it under any
combination tried. `TS_AUTHKEY` must be passed as its actual plain value in
`env` on every `create-pod` call. The `RUNPOD_SECRET_TSAUTH_KEY` fallback
left in `entrypoint.sh` is harmless (matches the docs' naming convention in
case the API adds support later) but is dead code today — don't rely on it.

## Not yet done

- **Try a different Unsloth quant tag** (e.g. `Q6_K` instead of
  `UD-Q6_K_XL`) — the current default's secondary blob has failed 4/4 times
  with an identical HuggingFace timeout; a different quant has a different
  blob composition and likely sidesteps this specific file entirely. Don't
  keep retrying the same pull blindly.
- Confirm the GHCR package visibility is set to Public (see note above — not automatic)
- Once a pull actually completes, verify `tailscale serve` and the final
  ready state — every attempt so far has died at the model-pull step before
  reaching this, so it remains entirely unverified
- Get RTX 5090 stock in a volume-compatible DC (US-GA-2 / EU-RO-1 / EUR-IS-1)
  to validate the persistent-volume path specifically, separate from the
  general entrypoint validation above — the 50GB volume (`a0szef22qu`) already
  exists in US-GA-2 but has never been used in a successful deploy. This also
  matters more now that container disk is confirmed wiped on every restart —
  without the volume, a flaky pull means starting the full 25.7GB download
  over from zero each time
