# KubePyrometer -- Kubernetes Control-Plane Load-Testing Harness

A harness that uses [kube-burner](https://github.com/kube-burner/kube-burner) to measure end-to-end control-plane request latency under configurable CPU, memory, disk, and network stress. Latency is measured from inside the cluster by a probe pod that issues API requests (`/readyz`, list nodes, list configmaps) and records round-trip time. The measured path includes the API server, authn/authz, admission controllers, etcd, and the in-cluster network between the probe pod and the API server.

No Go toolchain required -- the harness automatically downloads a pinned kube-burner release binary.

> **Note:** Probe latency depends on the node the probe pod is scheduled to, the cluster's network topology, and API server configuration. Results reflect the specific measurement path, not an absolute property of the cluster.

## Quickstart (30 seconds)

```bash
# 1. Point kubectl at your target cluster
kubectl config current-context

# 2. Run the harness (non-interactive, default parameters)
v0/run.sh

# 3. View results
cat "$(ls -dt v0/runs/*/ | head -1)/summary.csv"
cat "$(ls -dt v0/runs/*/ | head -1)/probe-stats.csv"
```

Example output (`summary.csv`):

```
phase,uuid,exit_code,start_epoch,end_epoch,elapsed_seconds,status
baseline,e24ae432-...,0,1772594963,1772594985,22,pass
ramp-step-1,7a030ae6-...,0,1772594985,1772595026,41,pass
teardown,n/a,0,1772595026,1772595068,42,pass
recovery,902bd49b-...,0,1772595068,1772595083,15,pass
```

Example output (`probe-stats.csv`):

```
phase,count,min_ms,p50_ms,p95_ms,max_ms
baseline,9,305,901,1092,1092
ramp-step-1,9,507,892,1058,1058
recovery,6,807,989,1289,1289
```

Example probe JSONL line (`probe.jsonl`):

```json
{"ts":"2026-03-04T03:29:28Z","phase":"baseline","probe":"readyz","latency_ms":709,"exit_code":0,"seq":1,"error":""}
```

## Safety

**This tool creates real resource pressure on your cluster.** CPU and memory stress pods consume actual compute resources. On small or production clusters, aggressive settings can cause node pressure, pod evictions, or degraded API responsiveness for all tenants.

Recommendations:

- **Start small.** The defaults (1 replica, 50m CPU, 32 Mi memory, 2 ramp steps) are intentionally conservative.
- **Test in non-production first.** Use a Kind cluster (`v0/scripts/kind-smoke.sh`) or a dedicated test cluster before running against shared infrastructure.
- **Monitor during runs.** Watch node conditions (`kubectl top nodes`) and API server latency from outside the harness.
- **Know your teardown.** The harness deletes stress namespaces automatically, but if `run.sh` is killed mid-run (e.g., Ctrl-C during ramp), stress pods may remain. Delete them manually: `kubectl delete ns -l app=kb-stress` or use the individual namespace names (`kb-stress-1`, `kb-stress-2`, ...).

## How it works

The harness runs four phases in order:

```
BASELINE probe  ->  RAMP stress (N steps)  ->  TEARDOWN  ->  RECOVERY probe
```

- **Baseline probe** -- Deploys a Job that repeatedly queries the API server (`/readyz`, list nodes, list configmaps in `kube-system`) and records latency. This establishes the "quiet" baseline.
- **Ramp steps** -- For each step, deploys stress workloads into isolated namespaces (`kb-stress-1`, `kb-stress-2`, ...) to put pressure on the cluster. Which stress types are active (CPU, memory, disk, network) is determined by the contention mode selection at the start of the run.
- **Teardown** -- Deletes all stress namespaces.
- **Recovery probe** -- Identical to baseline, measures how quickly control-plane latency returns to baseline levels.

Every phase is recorded to `phases.jsonl`, probe measurements go to `probe.jsonl`, and CSV summaries are generated. All artifacts land in a timestamped run directory under `v0/runs/`.

## Contention modes

The harness supports four contention modes, each independently enabled or disabled:

| Mode | What it does | Default (interactive) | Default (non-interactive) |
|------|-------------|----------------------|--------------------------|
| **cpu** | Infinite busy-loop pods consuming configurable millicores | on | on |
| **mem** | Pods that fill `/dev/shm` with configurable MB | on | on |
| **disk** | Pods that continuously write/delete files on an `emptyDir` volume | on | off |
| **network** | Pods that make continuous HTTPS requests to a configurable target | on | off |

All four stress modes use `busybox:1.36.1` and run as unprivileged pods with no `NET_ADMIN` capabilities or PVCs. The probe pods use `bitnami/kubectl:1.35.2`.

### CLI flags

By default, `run.sh` runs **non-interactively** using `config.yaml` and environment variable defaults. Use flags to enable interactive prompts:

```
v0/run.sh              # non-interactive (default)
v0/run.sh -i           # fully interactive (modes + registry)
v0/run.sh -c           # prompt for contention mode selection/settings
v0/run.sh -r           # prompt for image registry redirect + pull secret
v0/run.sh -cr          # prompt for both
v0/run.sh -h           # show usage help
```

`NONINTERACTIVE=1` is still supported for backward compatibility and overrides any flags.

### Interactive mode (`-i` or `-c`)

When you run `v0/run.sh -i` (or `-c`), it prompts for each mode in order before starting the test sequence:

```
>>> Contention mode selection
Enable cpu contention? [Y/n]
Edit cpu settings for this run? [Y/n] n
Enable mem contention? [Y/n]
Edit mem settings for this run? [Y/n]
  MEM replicas per step [1]: 2
  MEM MB per pod [32]: 64
Enable disk contention? [Y/n]
Edit disk settings for this run? [Y/n] n
Enable network contention? [Y/n] n

>>> Contention modes:
    cpu     = on   (replicas=1, millicores=50)
    mem     = on   (replicas=2, mb=64)
    disk    = on   (replicas=1, mb=64)
    network = off  (replicas=1, target=kubernetes.default.svc, interval=0.5s)
```

All enable prompts default to **YES** (press Enter to accept). Settings show their current default in brackets; press Enter to keep the default or type a new value.

### Registry redirect (`-i` or `-r`)

When you run `v0/run.sh -i` (or `-r`), the harness prompts for image registry redirects (useful for air-gapped clusters or private registries). If any images are redirected, it also asks for an optional `imagePullSecrets` name -- the Secret is injected into all pod specs so kubelet can authenticate to the private registry. You are responsible for creating the Secret in the target namespaces beforehand (e.g., via `kubectl create secret docker-registry`).

### Non-interactive overrides

In non-interactive mode (default), use environment variables to control behavior:

```bash
# Enable extra contention modes
MODE_DISK=on MODE_NETWORK=on v0/run.sh

# Redirect images via a map file and supply a pull secret
IMAGE_MAP_FILE=my-images.txt IMAGE_PULL_SECRET=my-registry-creds v0/run.sh
```

### Mode-specific settings

Each mode has tunable parameters, settable via interactive prompts, `config.yaml`, or environment variables:

**CPU:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_CPU_REPLICAS` | `1` |
| Millicores per pod | `RAMP_CPU_MILLICORES` | `50` |

**Memory:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_MEM_REPLICAS` | `1` |
| MB per pod | `RAMP_MEM_MB` | `32` |

**Disk:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_DISK_REPLICAS` | `1` |
| MB to write per pod | `RAMP_DISK_MB` | `64` |

Disk stress uses `dd` to write/delete files on an `emptyDir` volume. No PVCs or StorageClasses required.

**Network:**

| Setting | Env var | Default |
|---------|---------|---------|
| Replicas per step | `RAMP_NET_REPLICAS` | `1` |
| Target host | `RAMP_NET_TARGET` | `kubernetes.default.svc` |
| Request interval (seconds) | `RAMP_NET_INTERVAL` | `0.5` |

Network stress uses `wget` to make HTTPS requests to the target. The default target (`kubernetes.default.svc`) is the cluster's own API server via its in-cluster service DNS, so the network path includes CoreDNS resolution and kube-proxy/iptables service routing in addition to the HTTPS request itself.

## Images and registry access

Both container images are bundled in the repo as `v0/images/harness-images.tar`:

| Image | Used by | Size |
|-------|---------|------|
| `busybox:1.36.1` | All stress pods | ~2 MB |
| `bitnami/kubectl:1.35.2` | Probe pods | ~70 MB |

All templates set `imagePullPolicy: IfNotPresent`, so kubelet uses pre-loaded images and does not contact a registry when they are present on the node.

### Local dev clusters (Kind / k3d) -- no registry needed

For Kind and k3d, `run.sh` automatically loads the bundled tar into the cluster at startup. No registry access is required. The smoke test (`scripts/kind-smoke.sh`) also pre-loads images before running.

### Managed / remote clusters (EKS, GKE, AKS, on-prem)

The bundled tar cannot be loaded directly onto remote cluster nodes. For managed clusters, you must ensure the images are reachable by one of these methods:

1. **Public registry access** -- If the cluster nodes can pull from Docker Hub, the images will be pulled normally on first use (the `IfNotPresent` policy means subsequent runs reuse them).
2. **Registry redirect** -- Use `-r` (interactive) or `IMAGE_MAP_FILE` (non-interactive) to rewrite image references to a private registry or mirror. If the registry requires authentication, set `IMAGE_PULL_SECRET` to the name of a pre-existing `docker-registry` Secret.
3. **Node pre-loading** -- If you have SSH access to nodes, you can manually load the tar into the container runtime (e.g., `ctr -n k8s.io images import harness-images.tar` for containerd).

Set `SKIP_IMAGE_LOAD=1` to skip the automatic load attempt entirely (useful when images are already present on nodes or available from a registry).

### Refreshing bundled images

To update the bundled images (e.g., after a kubectl version bump):

```bash
# Requires Docker. Edit KUBECTL_TAG in the script if the upstream version changed.
bash v0/scripts/save-images.sh
```

## Preflight

Before running the harness, confirm your environment:

```bash
# 1. Verify kubectl points at the intended cluster
kubectl config current-context
kubectl get nodes -o wide

# 2. Verify kube-burner is available (auto-downloaded on first run if missing)
v0/bin/kube-burner version 2>/dev/null || echo "Will be installed automatically"
```

Prerequisites:

- **kubectl** -- configured to reach your target cluster
- **curl** -- for auto-downloading kube-burner (first run only)
- **Docker** -- only needed to run `scripts/save-images.sh` (image refresh) or for Docker Desktop K8s
- **kind** -- only needed for local dry runs (see below)
- No Go toolchain required

The running user's kubeconfig identity must be able to create/apply: Namespaces, ServiceAccounts, ClusterRoles, ClusterRoleBindings, Roles (in `kube-system`), RoleBindings (in `kube-system`), Jobs (in `kb-probe`), and Deployments (in `kb-stress-*` namespaces).

## Run against a real cluster

Use this workflow for EKS, GKE, AKS, on-prem, or any non-local cluster. Kind is **not** required.

### Step 1: Confirm kubectl context

```bash
kubectl config current-context
# Should print your target cluster name, e.g. "my-eks-cluster"

kubectl get nodes -o wide
# Verify these are the nodes you intend to stress-test
```

### Step 2: Apply RBAC

The harness needs a ServiceAccount and RBAC rules for probe pods. `run.sh` applies this automatically, but you can apply it ahead of time to verify permissions:

```bash
kubectl apply -f v0/manifests/probe-rbac.yaml
```

This creates:

| Resource | Scope | Purpose |
|----------|-------|---------|
| Namespace `kb-probe` | -- | Home for probe jobs and the service account |
| ServiceAccount `probe-sa` | `kb-probe` | Identity for probe pods |
| ClusterRole `kb-probe-reader` | cluster | `GET` on `/readyz`, `/healthz`, `/livez` (nonResourceURLs); `get`/`list` on `nodes` |
| ClusterRoleBinding `kb-probe-reader-binding` | cluster | Binds ClusterRole to `probe-sa` |
| Role `kb-probe-configmap-reader` | `kube-system` | `get`/`list` on `configmaps` (scoped to `kube-system` only) |
| RoleBinding `kb-probe-configmap-reader-binding` | `kube-system` | Binds Role to `probe-sa` |

Node listing requires a ClusterRole because nodes are cluster-scoped. Configmap listing is restricted to `kube-system` because that is the only namespace the probe queries. The probe SA has no write permissions and no access to secrets, pods, or other sensitive resources.

### Step 3: Run the harness

With default parameters (`v0/config.yaml`), non-interactive:

```bash
v0/run.sh
```

Fully interactive (contention modes + registry redirect prompts):

```bash
v0/run.sh -i
```

Interactive for contention modes only:

```bash
v0/run.sh -c
```

With a custom config file:

```bash
CONFIG_FILE=v0/configs/eks-small.yaml v0/run.sh
```

With environment variable overrides (highest precedence):

```bash
RAMP_STEPS=3 RAMP_CPU_REPLICAS=2 RAMP_CPU_MILLICORES=250 MODE_DISK=on v0/run.sh
```

### Step 4: Verify artifacts

The run directory is printed at the start and end of every run:

```bash
# Find the latest run
ls -dt v0/runs/*/ | head -1

# Check contents
RUN_DIR=$(ls -dt v0/runs/*/ | head -1)
cat "$RUN_DIR/kb-version.txt"
cat "$RUN_DIR/modes.env"
cat "$RUN_DIR/phases.jsonl"
cat "$RUN_DIR/summary.csv"
cat "$RUN_DIR/probe-stats.csv"
```

## Interpreting results

Each run produces `probe-stats.csv` with per-phase latency percentiles (aggregated across all probe types):

```
phase,count,min_ms,p50_ms,p95_ms,max_ms
baseline,9,305,901,1092,1092
ramp-step-1,9,507,892,1058,1058
recovery,6,807,989,1289,1289
```

**What to look for:**

- **Baseline p50/p95** -- Establishes the cluster's "quiet" control-plane latency. On a healthy cluster this is typically under 100 ms for each probe. Higher values may indicate an already-loaded cluster or network latency between the probe pod and the API server. (The example above was captured on a local Kind cluster where latency is higher than on dedicated infrastructure.)
- **Ramp-step p50/p95 vs baseline** -- Shows how latency increases under load. A 2-3x increase is expected with moderate stress. If p95 exceeds 5x baseline, the cluster is under significant pressure.
- **Recovery p50/p95 vs baseline** -- Should return to near-baseline levels after teardown. If recovery latency remains elevated, the cluster may need more time to stabilize (increase `RECOVERY_PROBE_DURATION`) or there may be residual resource pressure.
- **exit_code > 0** -- Indicates a probe request failed entirely (e.g., API server unreachable). Occasional failures during heavy ramp steps are expected; persistent failures indicate the cluster is overwhelmed.

For deeper analysis, use `probe.jsonl` directly -- each line contains the individual probe type, latency, and timestamp for time-series analysis.

## Dry run (local Kind cluster)

Use this workflow for local smoke testing. This is the only workflow that requires Kind.

### Prerequisites

- `kubectl`
- `kind` (only for this section)

### Run the smoke test

```bash
v0/scripts/kind-smoke.sh
```

This single command will:
1. Create (or reuse) a Kind cluster named `kb-smoke`
2. Pre-load the bundled container images into the Kind cluster
3. Auto-download kube-burner v2.4.0 if not already present
4. Run the harness with `NONINTERACTIVE=1` (CPU and memory on, disk and network off)
5. Assert that all expected artifacts exist and contain the right phases
6. Print PASS/FAIL and clean up the Kind cluster if it created one

The smoke test uses intentionally small parameter values (1 ramp step, 10s probes) to finish quickly.

## Configuration

### `config.yaml`

Flat YAML file of default parameters. Each key is uppercased and exported as an env var (e.g., `ramp_steps: 2` becomes `RAMP_STEPS=2`). Environment variables take precedence over the config file.

| Key | Default | Description |
|-----|---------|-------------|
| `baseline_probe_duration` | `10` | Seconds to run the baseline probe |
| `baseline_probe_interval` | `2` | Seconds between probe iterations |
| `ramp_steps` | `2` | Number of incremental stress steps |
| `ramp_cpu_replicas` | `1` | CPU-stress Deployments per step |
| `ramp_cpu_millicores` | `50` | CPU request/limit per stress pod (millicores) |
| `ramp_mem_replicas` | `1` | Memory-stress Deployments per step |
| `ramp_mem_mb` | `32` | Memory request/limit per stress pod (Mi) |
| `ramp_probe_duration` | `10` | Seconds to probe during each ramp step |
| `ramp_probe_interval` | `2` | Seconds between ramp-step probe iterations |
| `recovery_probe_duration` | `10` | Seconds to run the recovery probe |
| `recovery_probe_interval` | `2` | Seconds between recovery probe iterations |
| `kb_timeout` | `5m` | kube-burner per-phase timeout |

### Contention mode variables

These control which stress modes are active and their parameters. They can be set via environment variables or `config.yaml`. In interactive mode the enable/disable prompts override the `MODE_*` values; in non-interactive mode (`NONINTERACTIVE=1`) these variables are used directly.

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE_CPU` | `on` | Enable CPU contention |
| `MODE_MEM` | `on` | Enable memory contention |
| `MODE_DISK` | `off` | Enable disk contention |
| `MODE_NETWORK` | `off` | Enable network contention |
| `RAMP_DISK_REPLICAS` | `1` | Disk-stress Deployments per step |
| `RAMP_DISK_MB` | `64` | MB to write per disk-stress pod |
| `RAMP_NET_REPLICAS` | `1` | Network-stress Deployments per step |
| `RAMP_NET_TARGET` | `kubernetes.default.svc` | Target host for network requests |
| `RAMP_NET_INTERVAL` | `0.5` | Seconds between network requests per pod |
| `IMAGE_PULL_SECRET` | *(empty)* | Kubernetes Secret name for private registry auth (injected into all pod specs) |
| `SKIP_IMAGE_LOAD` | `0` | Set to `1` to skip loading the bundled image tar into the cluster |
| `PROBE_READYZ` | `1` | Set to `0` to disable the `/readyz` probe (useful if the endpoint is restricted) |

### Use a custom kube-burner binary

```bash
# Must be v2.4.0 (enforced by default)
KB_BIN=/usr/local/bin/kube-burner v0/run.sh

# Skip version check
KB_BIN=/path/to/custom-build KB_ALLOW_ANY=1 v0/run.sh
```

### Build kube-burner from source (optional)

```bash
# Requires Go >= 1.23 and a local kube-burner source checkout
bash v0/scripts/build-kube-burner.sh
```

## Common gotchas

**RBAC already applied automatically.** `run.sh` runs `kubectl apply -f manifests/probe-rbac.yaml` at the start of every run. You do not need to apply it manually, but doing so before the first run is a good way to verify you have the right permissions. If you see permission errors, check that your kubeconfig identity can create namespaces, serviceaccounts, clusterroles, clusterrolebindings, roles, and rolebindings.

**`/readyz` may be restricted.** Some managed Kubernetes services restrict access to the `/readyz` endpoint. If you see persistent `exit_code` failures for the `readyz` probe, set `PROBE_READYZ=0` to disable it. The `list-nodes` and `list-configmaps` probes will continue to measure control-plane latency.

**kube-burner version must be v2.4.0.** The harness pins kube-burner v2.4.0 and enforces this on all resolution paths. If you set `KB_BIN` to a binary that reports a different version, `run.sh` will refuse to start. Set `KB_ALLOW_ANY=1` to bypass the version check if you know what you are doing.

**Templates are staged per run.** `run.sh` copies templates, workloads, and manifests into a staging directory (`$RUN_DIR/staging/`) before each run. The staged `ramp-step.yaml` is generated to include only the enabled contention modes, and any image rewrites are applied to the staged copies. This keeps every run fully isolated from source files and from other runs.

**Image pre-loading only works on local clusters.** The automatic `load-images.sh` step detects Kind (via `kind-*` kubectl context prefix) and k3d, and loads the bundled tar directly. For Docker Desktop Kubernetes, it falls back to `docker load` which shares images with the kubelet. For remote clusters (EKS, GKE, AKS), `docker load` does not make images available on cluster nodes -- use registry redirect (`-r` / `IMAGE_MAP_FILE`) or ensure nodes have pull access to Docker Hub.

**Disk stress uses emptyDir.** The disk contention mode writes to an `emptyDir` volume, which is backed by the node's filesystem. No PVCs or StorageClasses are required. Write sizes are conservative by default (64 MB).

**Network stress target includes DNS + service routing.** The default network target `kubernetes.default.svc` routes through CoreDNS and kube-proxy/iptables before reaching the API server. This means the network stress path includes cluster DNS resolution, service routing, and the HTTPS request itself. No privileged mode or `NET_ADMIN` capability is needed.

## Compatibility

| Component | Tested / supported |
|-----------|-------------------|
| Kubernetes | 1.27+ (any conformant distribution) |
| Container runtimes | containerd, CRI-O, Docker (via dockershim or cri-dockerd) |
| Local clusters | Kind, k3d, Docker Desktop K8s, minikube (with manual image load) |
| Managed services | EKS, GKE, AKS (requires registry access or image redirect) |
| Architectures | `amd64`, `arm64` (both kube-burner and container images) |
| Host OS | Linux, macOS (bash 4+) |

## Run artifacts

Each run creates `v0/runs/YYYYMMDD-HHMMSS/` containing:

- **`kb-version.txt`** -- Binary path and full version output
- **`modes.env`** -- Human-readable KEY=VALUE record of selected contention modes and settings
- **`modes.json`** -- Machine-readable JSON of the same mode configuration
- **`phases.jsonl`** -- One JSON line per phase: `{"phase", "uuid", "rc", "start", "end", "elapsed_s"}`
- **`probe.jsonl`** -- One JSON line per probe check: `{"ts", "phase", "probe", "latency_ms", "exit_code", "seq"}`
- **`summary.csv`** -- Phase-level CSV: phase, uuid, exit_code, start/end epochs, elapsed, pass/fail
- **`probe-stats.csv`** -- Probe latency percentiles per phase: count, min, p50, p95, max (ms)
- **`phase-*.log`** -- Raw kube-burner output for each phase
- **`image-map.txt`** -- Image registry rewrites applied (or "(no rewrites)")
- **`staging/`** -- Staged copies of templates, workloads, and manifests used for this run

## Folder structure

```
v0/
├── run.sh                          # Main harness entrypoint
├── config.yaml                     # Default parameters (overridable via env)
├── .gitignore                      # Ignores bin/, runs/, logs, collected-metrics/
│
├── bin/                            # Auto-populated (gitignored)
│   ├── kube-burner                 #   Downloaded binary
│   └── .kb-version                 #   Version stamp file
│
├── configs/                        # Custom config files
│   └── eks-small.yaml              #   Small EKS test parameters
│
├── images/
│   └── harness-images.tar          # Bundled container images (busybox + kubectl)
│
├── scripts/
│   ├── kind-smoke.sh               # End-to-end smoke test (Kind + harness + assertions)
│   ├── install-kube-burner.sh      # Downloads kube-burner v2.4.0 from GitHub Releases
│   ├── build-kube-burner.sh        # OPTIONAL: build from source (requires Go >= 1.23)
│   ├── save-images.sh              # Pulls and saves container images to images/harness-images.tar
│   ├── load-images.sh              # Loads bundled images into the current cluster
│   ├── summarize.sh                # Generates summary.csv + probe-stats.csv from run data
│   └── v0tui.sh                    # Interactive TUI (requires gum; optional fzf, jq)
│
├── workloads/                      # kube-burner job definitions
│   ├── probe.yaml                  #   Probe phase (creates a kubectl Job)
│   └── ramp-step.yaml              #   Ramp phase (all four stress modes + probe)
│
├── templates/                      # Kubernetes object templates (Go-templated)
│   ├── probe-job.yaml              #   Job: polls /readyz, list-nodes, list-configmaps
│   ├── cpu-stress.yaml             #   Deployment: busybox infinite CPU loop
│   ├── mem-stress.yaml             #   Deployment: busybox dd into /dev/shm
│   ├── disk-stress.yaml            #   Deployment: busybox dd write/delete on emptyDir
│   └── net-stress.yaml             #   Deployment: busybox wget loop to target host
│
├── manifests/
│   └── probe-rbac.yaml             # Namespace, ServiceAccount, RBAC for probes
│
└── runs/                           # Timestamped run artifact directories (gitignored)
    └── YYYYMMDD-HHMMSS/
        ├── kb-version.txt          #   Binary path + version output
        ├── modes.env               #   Contention mode selection + settings (KEY=VALUE)
        ├── modes.json              #   Same as modes.env in JSON format
        ├── image-map.txt           #   Image registry rewrites (if any)
        ├── phases.jsonl            #   One JSON object per phase (rc, elapsed, uuid)
        ├── probe.jsonl             #   Probe measurements (latency, exit code, seq)
        ├── summary.csv             #   CSV summary of all phases
        ├── probe-stats.csv         #   Probe latency percentiles per phase
        ├── phase-*.log             #   Per-phase kube-burner stdout/stderr
        └── staging/                #   Staged templates/workloads/manifests for this run
```

## File reference

### `run.sh`

The main entrypoint. Accepts `-i` (full interactive), `-c` (contention mode prompts), `-r` (registry redirect prompts), or no flags (non-interactive default). Resolves the kube-burner binary, parses `config.yaml`, stages templates into the run directory, generates a filtered `ramp-step.yaml` containing only the enabled modes, optionally applies image registry rewrites and `imagePullSecrets`, loads bundled images, applies RBAC, then orchestrates the four-phase sequence. All artifacts are collected into a timestamped `runs/` directory, even on failure.

**kube-burner resolution order:**
1. `KB_BIN` env var (must be executable; version-checked against v2.4.0 unless `KB_ALLOW_ANY=1`)
2. System `kube-burner` in `$PATH` (only if it reports v2.4.0)
3. `v0/bin/kube-burner` (auto-downloaded via `install-kube-burner.sh` if missing)

### `scripts/kind-smoke.sh`

Self-contained smoke test for **local dry runs only**. Creates a Kind cluster (or reuses an existing one named `kb-smoke`), pre-loads bundled images, runs the harness with `NONINTERACTIVE=1` and small parameter values, then asserts that all expected artifacts exist and contain the right phases. Cleans up the cluster on exit if it created one.

### `scripts/install-kube-burner.sh`

Downloads kube-burner v2.4.0 from GitHub Releases for the current OS/arch (`darwin`/`linux` + `amd64`/`arm64`). Tries multiple known asset name patterns until one succeeds. After extracting, verifies the binary reports v2.4.0 and writes a stamp file to `v0/bin/.kb-version`.

### `scripts/build-kube-burner.sh`

**Optional.** Builds kube-burner from a local source checkout using Go >= 1.23. Not called automatically by any script. Use only if you need a custom build.

### `scripts/save-images.sh`

Pulls `busybox:1.36.1` and `bitnami/kubectl:latest` via Docker, re-tags kubectl to the pinned version (`1.35.2`), and saves both into `v0/images/harness-images.tar`. Run this to refresh the bundled images. The pinned version (`KUBECTL_TAG`) is defined at the top of the script and must match the image ref in `templates/probe-job.yaml`.

### `scripts/load-images.sh`

Loads `v0/images/harness-images.tar` into the current cluster. Auto-detects Kind (via `kind-*` kubectl context prefix) and k3d. Falls back to `docker load`, which only helps when Docker Desktop is the Kubernetes runtime (Docker and kubelet share the image store). For remote clusters, this fallback is not useful -- use registry redirect instead. Called automatically by `run.sh` unless `-r`, `IMAGE_MAP_FILE`, or `SKIP_IMAGE_LOAD=1` is set.

### `scripts/summarize.sh`

Parses `phases.jsonl` from a run directory and writes `summary.csv` with columns: `phase, uuid, exit_code, start_epoch, end_epoch, elapsed_seconds, status`. Also computes per-phase probe latency percentiles from `probe.jsonl` and writes `probe-stats.csv` with columns: `phase, count, min_ms, p50_ms, p95_ms, max_ms`.

### `scripts/v0tui.sh`

Interactive terminal UI for the harness. Provides a menu-driven interface for running the harness, viewing results, editing config, running the smoke test, and cluster cleanup. Requires `gum` (auto-installed if missing). Optional: `fzf` (fuzzy file picker), `jq` (JSON processing; falls back to Python or grep).

### `workloads/probe.yaml`

kube-burner job definition for the probe phase. Creates a single Kubernetes Job (from `templates/probe-job.yaml`) that runs kubectl commands in a loop to measure API latency.

### `workloads/ramp-step.yaml`

kube-burner job definition for each ramp step. The checked-in file references all four stress templates (CPU, memory, disk, network) plus the probe job. At runtime, `run.sh` generates a filtered copy in staging that includes only the enabled modes' objects.

### `templates/probe-job.yaml`

Kubernetes Job template. Runs a shell loop inside a `bitnami/kubectl:1.35.2` container that performs up to three checks per iteration (`/readyz` if `PROBE_READYZ=1`, list nodes, list configmaps in `kube-system`) and emits one JSON line per check to stdout.

### `templates/cpu-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container with an infinite `while true; do :; done` loop, consuming a configurable amount of CPU (millicores). Unprivileged.

### `templates/mem-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container that uses `dd` to fill `/dev/shm` with a configurable number of megabytes, then sleeps forever. Mounts `/dev/shm` as a memory-backed `emptyDir` volume so the container can actually fill beyond the default 64 MB tmpfs limit. Unprivileged.

### `templates/disk-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container that continuously writes and deletes files on an `emptyDir` volume using `dd`. Write size is configurable via the `diskMb` input variable. No PVC or privileged mode required.

### `templates/net-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container that makes continuous `wget` HTTPS requests to a configurable target host at a configurable interval. No privileged mode or `NET_ADMIN` capability required. The default target (`kubernetes.default.svc`) routes through CoreDNS and kube-proxy service routing.

### `manifests/probe-rbac.yaml`

Creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, a ClusterRole for `/readyz` and node listing (cluster-scoped), and a Role for configmap listing scoped to `kube-system`. The probe SA has read-only access and cannot modify any resources.
