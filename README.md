# KubePyrometer -- Kubernetes Control-Plane Load-Testing Harness

A harness that uses [kube-burner](https://github.com/kube-burner/kube-burner) to measure end-to-end control-plane request latency under configurable CPU, memory, disk, network, and API stress. Latency is measured from inside the cluster by a probe pod that issues API requests (`/readyz`, list nodes, list configmaps) and records round-trip time. The measured path includes the API server, authn/authz, admission controllers, etcd, and the in-cluster network between the probe pod and the API server.

No Go toolchain required -- the harness automatically downloads a pinned kube-burner release binary.

> **Note:** Probe latency depends on the node the probe pod is scheduled to, the cluster's network topology, and API server configuration. Results reflect the specific measurement path, not an absolute property of the cluster.

## Installation

### Homebrew (macOS / Linux)

```bash
brew tap spectronauts/kubepyrometer
brew install kubepyrometer
```

### From source

```bash
git clone https://github.com/spectronauts/KubePyrometer.git
cd KubePyrometer
make install              # installs to /usr/local by default
# or: make install PREFIX=$HOME/.local
```

### No install (run from repo checkout)

```bash
git clone https://github.com/spectronauts/KubePyrometer.git
cd KubePyrometer
./kubepyrometer run       # or: lib/run.sh (still works)
```

After installing, run `kubepyrometer init` to generate a config file (`kubepyrometer.yaml`) in your current directory. This file contains every tunable parameter with its default value -- it is the easiest way to see what is configurable and to customize the tool for your cluster. The harness works without a config file (sensible defaults are built in), but having one makes it easy to adjust settings and reproduce runs.

## Quickstart

```bash
# 1. Point kubectl at your target cluster
kubectl config current-context

# 2. Generate a config file (shows all tunable parameters with defaults)
kubepyrometer init
# Edit kubepyrometer.yaml to adjust ramp steps, replicas, probe durations, etc.

# 3. Run the harness
kubepyrometer run

# 4. Analyze results
kubepyrometer analyze "$(ls -dt runs/*/ | head -1)"
```

Step 2 creates a `kubepyrometer.yaml` in the current directory. You can skip it to run with defaults, but reviewing it first is recommended -- it documents every setting the harness uses. See [Configuration](#configuration) for the full reference.

> **Direct invocation:** `lib/run.sh` still works from a repo checkout and behaves identically to previous versions.

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

### Built-in guardrails

Before creating any cluster resources, the harness computes a **safety plan** estimating the total pods, namespaces, and API objects the run will create. If estimated usage exceeds configurable limits, the run is blocked:

- **Interactive mode** -- prompts for confirmation before proceeding.
- **Non-interactive mode** -- aborts with a clear message. Set `SAFETY_BYPASS=1` to override (prints a prominent warning).

The safety plan is always written to `safety-plan.txt` in the run directory for review and audit.

Default limits (configurable via `config.yaml` or environment variables):

| Limit | Default | Env var |
|-------|---------|---------|
| Max cumulative pods | 2000 | `SAFETY_MAX_PODS` |
| Max namespaces | 100 | `SAFETY_MAX_NAMESPACES` |
| Max API objects per step | 5000 | `SAFETY_MAX_OBJECTS_PER_STEP` |

### Failure detection

During ramp steps, the harness checks for namespace creation failures, pods stuck in `Pending` with `FailedScheduling` events, and quota violations. If a health check fails, the ramp is aborted, teardown runs immediately, and the failure is logged to `failures.log` with timestamps and reasons.

### Config profiles

For large or production clusters, use the `large` profile for safer defaults (smaller increments, longer probe windows, tighter safety limits):

```bash
kubepyrometer run -p large
# or: CONFIG_PROFILE=large kubepyrometer run
```

### Recommendations

- **Start small.** The defaults (1 replica, 50m CPU, 32 Mi memory, 2 ramp steps) are intentionally conservative.
- **Test in non-production first.** Use a Kind cluster (`lib/scripts/kind-smoke.sh`) or a dedicated test cluster before running against shared infrastructure.
- **Monitor during runs.** Watch node conditions (`kubectl top nodes`) and API server latency from outside the harness.
- **Know your teardown.** The harness deletes stress namespaces automatically, but if the process is killed mid-run (e.g., Ctrl-C during ramp), stress pods may remain. Delete them manually: `kubectl delete ns -l app=kb-stress` or use the individual namespace names (`kb-stress-1`, `kb-stress-2`, ...).

## How it works

The harness runs four phases in order:

```
BASELINE probe  ->  RAMP stress (N steps)  ->  TEARDOWN  ->  RECOVERY probe
```

- **Baseline probe** -- Deploys a Job that repeatedly queries the API server (`/readyz`, list nodes, list configmaps in `kube-system`) and records latency. This establishes the "quiet" baseline.
- **Ramp steps** -- For each step, deploys stress workloads into isolated namespaces (`kb-stress-1`, `kb-stress-2`, ...) to put pressure on the cluster. Which stress types are active (CPU, memory, disk, network, API) is determined by the contention mode selection at the start of the run.
- **Teardown** -- Deletes all stress namespaces.
- **Recovery probe** -- Identical to baseline, measures how quickly control-plane latency returns to baseline levels.

Every phase is recorded to `phases.jsonl`, probe measurements go to `probe.jsonl`, and CSV summaries are generated. All artifacts land in a timestamped run directory (`./runs/YYYYMMDD-HHMMSS/` by default, or the path set with `-o`).

## Contention modes

The harness supports five contention modes, each independently enabled or disabled:

| Mode | What it does | Default (interactive) | Default (non-interactive) |
|------|-------------|----------------------|--------------------------|
| **cpu** | Infinite busy-loop pods consuming configurable millicores | on | on |
| **mem** | Pods that fill `/dev/shm` with configurable MB | on | on |
| **disk** | Pods that continuously write/delete files on an `emptyDir` volume | on | off |
| **network** | Pod-to-pod HTTP traffic via an in-cluster echo server | on | off |
| **api** | Floods the Kubernetes API server with ConfigMap + Secret creation at configurable QPS | on | off |

The cpu, mem, disk, and network stress modes use `busybox:1.36.1` and run as unprivileged pods with no `NET_ADMIN` capabilities or PVCs. Network stress deploys a lightweight echo server (busybox httpd) and client pods that download a 64 KB payload in a loop, saturating pod network I/O without requiring any RBAC or API server access. The api stress mode uses kube-burner's native object creation to hammer the API server through the full request path (authn, authz, admission, etcd). The probe pods use `bitnami/kubectl:latest`.

### CLI commands

```
kubepyrometer run              # non-interactive (default)
kubepyrometer run -i           # fully interactive (modes + registry)
kubepyrometer run -c           # prompt for contention mode selection/settings
kubepyrometer run -r           # prompt for image registry redirect + pull secret
kubepyrometer run -p large     # load a config profile (e.g., safer defaults for production)
kubepyrometer run -f my.yaml   # use a specific config file
kubepyrometer run -o ./out     # write run artifacts to a custom directory
kubepyrometer analyze <dir>    # analyze a completed run and explain results
kubepyrometer init             # generate a default kubepyrometer.yaml in the current directory
kubepyrometer summarize <dir>  # regenerate summary CSVs from a run directory
kubepyrometer monitor          # start the cluster resource monitor standalone
kubepyrometer tui              # launch interactive TUI (requires gum)
kubepyrometer bundle <dir>     # package run artifacts into a shareable tarball
kubepyrometer version          # print version information
```

**Config file search order** (for `kubepyrometer run` without `-f`):
1. `CONFIG_FILE` environment variable
2. `./kubepyrometer.yaml` in the current directory
3. `~/.kubepyrometer/config.yaml`
4. Built-in defaults

`NONINTERACTIVE=1` is still supported for backward compatibility and overrides any flags.

> **Direct invocation:** `lib/run.sh [-i] [-c] [-r] [-p PROFILE] [-f CONFIG] [-o OUTDIR]` still works from a repo checkout.

### Interactive mode (`-i` or `-c`)

When you run `kubepyrometer run -i` (or `-c`), it prompts for each mode in order before starting the test sequence:

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
Enable API stress? [Y/n]
Edit API stress settings for this run? [Y/n] n
Enable cluster monitor (kubectl top)? [Y/n]
  Monitor interval (seconds) [10]: 5

>>> Contention modes:
    cpu     = on   (replicas=1, millicores=50)
    mem     = on   (replicas=2, mb=64)
    disk    = on   (replicas=1, mb=64)
    network = off  (replicas=1, interval=0.5s)
    api     = on   (qps=20, burst=40, iterations=50, replicas=5)
    monitor = on   (interval=5s)
```

All enable prompts default to **YES** (press Enter to accept). Settings show their current default in brackets; press Enter to keep the default or type a new value.

### Registry redirect (`-i` or `-r`)

When you run `kubepyrometer run -i` (or `-r`), the harness prompts for image registry redirects (useful for air-gapped clusters or private registries). If any images are redirected, it also asks for an optional `imagePullSecrets` name -- the Secret is injected into all pod specs so kubelet can authenticate to the private registry. You are responsible for creating the Secret beforehand (see workflow below).

For non-interactive registry redirect, use an **image map file** and set `IMAGE_MAP_FILE` and `IMAGE_PULL_SECRET` via `config.yaml` or environment variables.

#### Image map file format

The image map file is a plain-text list of `original = replacement` mappings, one per line. Lines starting with `#` are comments. Whitespace around `=` is trimmed.

Example `my-images.txt` for a private ECR registry:

```
# Redirect harness images to private ECR
busybox:1.36.1 = 123456789.dkr.ecr.us-east-1.amazonaws.com/busybox:1.36.1
bitnami/kubectl:latest = 123456789.dkr.ecr.us-east-1.amazonaws.com/bitnami/kubectl:latest
```

The harness detects all `image:` references in `templates/*.yaml` and `manifests/*.yaml`, then does a global find-and-replace in the staged copies. Source files are never modified.

#### End-to-end workflow (private registry)

```bash
# 1. Push images to your private registry
docker pull busybox:1.36.1
docker tag busybox:1.36.1 123456789.dkr.ecr.us-east-1.amazonaws.com/busybox:1.36.1
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/busybox:1.36.1

docker pull bitnami/kubectl:latest
docker tag bitnami/kubectl:latest 123456789.dkr.ecr.us-east-1.amazonaws.com/bitnami/kubectl:latest
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/bitnami/kubectl:latest

# 2. Create an image pull secret in the cluster
#    (The harness injects imagePullSecrets into all pod specs automatically.)
kubectl create secret docker-registry my-registry-creds \
  --docker-server=123456789.dkr.ecr.us-east-1.amazonaws.com \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password)" \
  -n default

# 3. Run with the map file + pull secret
IMAGE_MAP_FILE=my-images.txt IMAGE_PULL_SECRET=my-registry-creds SKIP_IMAGE_LOAD=1 kubepyrometer run
```

Or configure it in `config.yaml` for repeatable runs:

```yaml
image_map_file: /path/to/my-images.txt
image_pull_secret: my-registry-creds
skip_image_load: 1
```

> **Note:** Set `skip_image_load: 1` when using registry redirect — otherwise the harness tries to load the bundled image tar first, which is unnecessary when pulling from a registry.

### Non-interactive overrides

In non-interactive mode (default), use environment variables to control behavior:

```bash
# Enable extra contention modes
MODE_DISK=on MODE_NETWORK=on kubepyrometer run

# Redirect images via a map file and supply a pull secret
IMAGE_MAP_FILE=my-images.txt IMAGE_PULL_SECRET=my-registry-creds SKIP_IMAGE_LOAD=1 kubepyrometer run
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
| Request interval (seconds) | `RAMP_NET_INTERVAL` | `0.5` |

Network stress deploys a lightweight echo server (busybox httpd serving a 64 KB payload) and client pods that `wget` it in a tight loop. This saturates pod network I/O -- affecting CNI, node networking, kube-proxy/iptables, and potentially etcd gossip on shared networks -- without requiring any RBAC or API server access. For API server stress, use the `api` mode instead.

**API:**

| Setting | Env var | Default |
|---------|---------|---------|
| Queries per second | `RAMP_API_QPS` | `20` |
| Burst | `RAMP_API_BURST` | `40` |
| Iterations (objects per step) | `RAMP_API_ITERATIONS` | `50` |
| Replicas per iteration | `RAMP_API_REPLICAS` | `5` |

API stress uses kube-burner's native object creation engine to create ConfigMaps and Secrets at the configured QPS. Each iteration creates `RAMP_API_REPLICAS` of each object type, so the total objects per ramp step is `RAMP_API_ITERATIONS * RAMP_API_REPLICAS * 2`. Every request traverses the full Kubernetes API path: authentication, authorization, admission controllers, etcd write, and watch notifications. Secrets are slightly heavier than ConfigMaps because the API server encrypts them at rest (when etcd encryption is configured). No additional container images required -- kube-burner handles this directly.

## Images and registry access

Both container images are bundled in the repo as `lib/images/harness-images.tar`:

| Image | Used by | Size |
|-------|---------|------|
| `busybox:1.36.1` | All stress pods | ~2 MB |
| `bitnami/kubectl:latest` | Probe pods | ~70 MB |

All templates set `imagePullPolicy: IfNotPresent`, so kubelet uses pre-loaded images and does not contact a registry when they are present on the node.

### Local dev clusters (Kind / k3d) -- no registry needed

For Kind and k3d, the harness automatically loads the bundled tar into the cluster at startup. No registry access is required. The smoke test (`scripts/kind-smoke.sh`) also pre-loads images before running.

### Managed / remote clusters (EKS, GKE, AKS, on-prem)

The bundled tar cannot be loaded directly onto remote cluster nodes. For managed clusters, you must ensure the images are reachable by one of these methods:

1. **Public registry access** -- If the cluster nodes can pull from Docker Hub, the images will be pulled normally on first use (the `IfNotPresent` policy means subsequent runs reuse them).
2. **Registry redirect** -- Use `-r` (interactive) or `IMAGE_MAP_FILE` (non-interactive) to rewrite image references to a private registry or mirror. See [Image map file format](#image-map-file-format) for the file syntax and a full end-to-end workflow. If the registry requires authentication, set `IMAGE_PULL_SECRET` to the name of a pre-existing `docker-registry` Secret.
3. **Node pre-loading** -- If you have SSH access to nodes, you can manually load the tar into the container runtime (e.g., `ctr -n k8s.io images import harness-images.tar` for containerd).

Set `SKIP_IMAGE_LOAD=1` to skip the automatic load attempt entirely (useful when images are already present on nodes or available from a registry).

### Refreshing bundled images

To update the bundled images (e.g., after a kubectl version bump):

```bash
# Requires Docker. Edit KUBECTL_TAG in the script if the upstream version changed.
bash lib/scripts/save-images.sh
```

## Preflight

Before running the harness, confirm your environment:

```bash
# 1. Verify kubectl points at the intended cluster
kubectl config current-context
kubectl get nodes -o wide

# 2. Verify kube-burner is available (auto-downloaded on first run if missing)
kubepyrometer version
```

Prerequisites:

- **kubectl** -- configured to reach your target cluster
- **curl** -- for auto-downloading kube-burner (first run only)
- **Docker** -- only needed to run `scripts/save-images.sh` (image refresh) or for Docker Desktop K8s
- **kind** -- only needed for local dry runs (see below)
- No Go toolchain required

The running user's kubeconfig identity must be able to create/apply: Namespaces, ServiceAccounts, ClusterRoles, ClusterRoleBindings, Roles (in `kube-system`), RoleBindings (in `kube-system`), Jobs (in `kb-probe`), Deployments (in `kb-stress-*` namespaces), Services (network stress echo server), ConfigMaps, and Secrets (API stress mode).

## Run against a real cluster

Use this workflow for EKS, GKE, AKS, on-prem, or any non-local cluster. Kind is **not** required.

### Step 1: Confirm kubectl context

```bash
kubectl config current-context
# Should print your target cluster name, e.g. "my-eks-cluster"

kubectl get nodes -o wide
# Verify these are the nodes you intend to stress-test
```

### Step 2: Apply RBAC (automatic)

The harness needs a ServiceAccount and RBAC rules for probe pods. `kubepyrometer run` applies these automatically at the start of every run, so no manual step is required. If you want to verify your permissions ahead of time (useful on locked-down clusters), apply the manifest manually:

```bash
# From a repo checkout:
kubectl apply -f lib/manifests/probe-rbac.yaml
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

With default parameters, non-interactive:

```bash
kubepyrometer run
```

Fully interactive (contention modes + registry redirect prompts):

```bash
kubepyrometer run -i
```

Interactive for contention modes only:

```bash
kubepyrometer run -c
```

With a custom config file:

```bash
kubepyrometer run -f lib/configs/eks-small.yaml
```

With environment variable overrides (highest precedence):

```bash
RAMP_STEPS=3 RAMP_CPU_REPLICAS=2 RAMP_CPU_MILLICORES=250 MODE_DISK=on kubepyrometer run
```

### Step 4: Verify artifacts

The run directory is printed at the start and end of every run. When using the CLI, artifacts are written to `./runs/<timestamp>/` by default (override with `-o`).

```bash
# Find the latest run
ls -dt runs/*/ | head -1

# Check contents
RUN_DIR=$(ls -dt runs/*/ | head -1)
cat "$RUN_DIR/kb-version.txt"
cat "$RUN_DIR/modes.env"
cat "$RUN_DIR/phases.jsonl"
cat "$RUN_DIR/summary.csv"
cat "$RUN_DIR/probe-stats.csv"
```

## Interpreting results

The fastest way to understand a run is `kubepyrometer analyze`:

```bash
kubepyrometer analyze runs/20260316-110035
```

This prints a structured report covering the run overview, phase-by-phase pass/fail breakdown, latency table (p50/p95/min/max), degradation scoring vs baseline (nominal / elevated / degraded / critical), recovery assessment, failure root-cause diagnosis, capacity context, and actionable recommendations.

### Reading the raw data

Each run also produces CSV and JSONL files for programmatic analysis:

**`probe-stats.csv`** -- per-phase latency percentiles:

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

For time-series analysis, use `probe.jsonl` directly -- each line contains the individual probe type, latency, and timestamp.

## Dry run (local Kind cluster)

Use this workflow for local smoke testing. This is the only workflow that requires Kind.

### Prerequisites

- `kubectl`
- `kind` (only for this section)

### Run the smoke test

```bash
lib/scripts/kind-smoke.sh
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

### Getting a config file

Run `kubepyrometer init` to generate a `kubepyrometer.yaml` in the current directory. This is a copy of the built-in defaults with comments -- every setting the harness supports is listed. Edit it to match your cluster and testing goals, then run `kubepyrometer run` from the same directory. The harness picks it up automatically.

To create a **global** config that applies to all runs (regardless of working directory), move or copy the file to `~/.kubepyrometer/config.yaml`:

```bash
mkdir -p ~/.kubepyrometer
kubepyrometer init
mv kubepyrometer.yaml ~/.kubepyrometer/config.yaml
```

A local `./kubepyrometer.yaml` takes precedence over the global config, and `-f` or `CONFIG_FILE` takes precedence over both. See [CLI commands](#cli-commands) for the full search order.

### `config.yaml` reference

Each key in the config file is uppercased and exported as an env var (e.g., `ramp_steps: 2` becomes `RAMP_STEPS=2`). Environment variables take precedence over the config file, so any key below can also be overridden at the command line (e.g., `RAMP_STEPS=5 kubepyrometer run`). In interactive mode (`-i` or `-c`), prompts override both.

| Key | Default | Description |
|-----|---------|-------------|
| `baseline_probe_duration` | `10` | Seconds to run the baseline probe |
| `baseline_probe_interval` | `2` | Seconds between probe iterations |
| `ramp_steps` | `2` | Number of incremental stress steps |
| `ramp_probe_duration` | `10` | Seconds to probe during each ramp step |
| `ramp_probe_interval` | `2` | Seconds between ramp-step probe iterations |
| `recovery_probe_duration` | `10` | Seconds to run the recovery probe |
| `recovery_probe_interval` | `2` | Seconds between recovery probe iterations |
| `kb_timeout` | `5m` | kube-burner per-phase timeout |
| `skip_log_file` | `true` | Skip kube-burner's own log file |
| `probe_readyz` | `1` | Set to `0` to disable `/readyz` probe |
| `ramp_qps` | `50` | kube-burner client QPS for ramp-step object creation and readiness checks |
| `ramp_burst` | `100` | kube-burner client burst limit for ramp-step operations |
| `mode_cpu` | `on` | Enable CPU contention |
| `mode_mem` | `on` | Enable memory contention |
| `mode_disk` | `off` | Enable disk contention |
| `mode_network` | `off` | Enable network contention |
| `mode_api` | `off` | Enable API stress |
| `ramp_cpu_replicas` | `1` | CPU-stress Deployments per step |
| `ramp_cpu_millicores` | `50` | CPU request/limit per stress pod (millicores) |
| `ramp_mem_replicas` | `1` | Memory-stress Deployments per step |
| `ramp_mem_mb` | `32` | Memory request/limit per stress pod (Mi) |
| `ramp_disk_replicas` | `1` | Disk-stress Deployments per step |
| `ramp_disk_mb` | `64` | MB to write per disk-stress pod |
| `ramp_net_replicas` | `1` | Network-stress Deployments per step |
| `ramp_net_interval` | `0.5` | Seconds between network requests per pod |
| `ramp_api_qps` | `20` | API stress queries per second |
| `ramp_api_burst` | `40` | API stress burst limit |
| `ramp_api_iterations` | `50` | kube-burner iterations per ramp step |
| `ramp_api_replicas` | `5` | ConfigMaps + Secrets created per iteration |
| `cluster_monitor` | `0` | Set to `1` for resource monitoring during run |
| `monitor_interval` | `10` | Seconds between monitor snapshots |
| `safety_max_pods` | `2000` | Abort if estimated cumulative pods exceed this |
| `safety_max_namespaces` | `100` | Abort if estimated namespaces exceed this |
| `safety_max_objects_per_step` | `5000` | Abort if estimated API objects per step exceed this |
| `image_map_file` | *(empty)* | Path to image redirect map file |
| `image_pull_secret` | *(empty)* | Kubernetes Secret name for private registry auth |
| `skip_image_load` | `0` | Set to `1` to skip bundled image loading |

### Cluster monitor

The harness includes an optional lightweight cluster monitor that captures resource usage throughout the test -- useful when Prometheus is not available.

When enabled, it runs in the background and writes timestamped snapshots to `cluster-monitor.log` in the run directory. Each snapshot captures:

- **Node resource usage** (`kubectl top nodes`) -- CPU and memory utilization per node
- **Pod resource usage** (`kubectl top pods`) -- per-pod consumption in the `kb-stress-*` and `kb-probe` namespaces
- **Cluster events** -- recent events in the stress namespaces (OOM kills, evictions, scheduling failures)
- **Node conditions** -- current node status (Ready, MemoryPressure, DiskPressure, etc.)

**Prerequisites:** `metrics-server` must be installed for `kubectl top` to work. It is present by default on EKS, GKE, and AKS. On Kind or k3d, install it separately. If metrics-server is unavailable, the monitor gracefully falls back to events-only mode.

**Enable via interactive mode:**

```bash
kubepyrometer run -i
# ... contention mode prompts ...
# Enable cluster monitor (kubectl top)? [Y/n] y
#   Monitor interval (seconds) [10]: 5
```

**Enable via environment variable:**

```bash
CLUSTER_MONITOR=1 MONITOR_INTERVAL=5 kubepyrometer run
```

**Standalone mode** (run in a separate terminal, writes to stdout):

```bash
kubepyrometer monitor --interval 5
kubepyrometer monitor --interval 10 --output monitor.log
```

### Use a custom kube-burner binary

```bash
# Must be v2.4.0 (enforced by default)
KB_BIN=/usr/local/bin/kube-burner kubepyrometer run

# Skip version check
KB_BIN=/path/to/custom-build KB_ALLOW_ANY=1 kubepyrometer run
```

### Build kube-burner from source (optional)

```bash
# Requires Go >= 1.23 and a local kube-burner source checkout
bash lib/scripts/build-kube-burner.sh
```

## Common gotchas

**RBAC already applied automatically.** The harness runs `kubectl apply` on the probe RBAC manifest at the start of every run. You do not need to apply it manually, but doing so before the first run is a good way to verify you have the right permissions. If you see permission errors, check that your kubeconfig identity can create namespaces, serviceaccounts, clusterroles, clusterrolebindings, roles, and rolebindings.

**`/readyz` may be restricted.** Some managed Kubernetes services restrict access to the `/readyz` endpoint. If you see persistent `exit_code` failures for the `readyz` probe, set `PROBE_READYZ=0` to disable it. The `list-nodes` and `list-configmaps` probes will continue to measure control-plane latency.

**kube-burner version must be 2.4.x.** The harness accepts any kube-burner 2.4.x patch release (e.g., v2.4.0, v2.4.1) and installs v2.4.0 by default. If you set `KB_BIN` to a binary that reports a different minor version, the harness will refuse to start. Set `KB_ALLOW_ANY=1` to bypass the version check if you know what you are doing.

**Templates are staged per run.** The harness copies templates, workloads, and manifests into a staging directory (`$RUN_DIR/staging/`) before each run. The staged `ramp-step.yaml` is generated to include only the enabled contention modes, and any image rewrites are applied to the staged copies. This keeps every run fully isolated from source files and from other runs.

**Image pre-loading only works on local clusters.** The automatic image-loading step detects Kind (via `kind-*` kubectl context prefix) and k3d, and loads the bundled tar directly. For Docker Desktop Kubernetes, it falls back to `docker load` which shares images with the kubelet. For remote clusters (EKS, GKE, AKS), `docker load` does not make images available on cluster nodes -- use registry redirect (`-r` / `IMAGE_MAP_FILE`) or ensure nodes have pull access to Docker Hub.

**Disk stress uses emptyDir.** The disk contention mode writes to an `emptyDir` volume, which is backed by the node's filesystem. No PVCs or StorageClasses are required. Write sizes are conservative by default (64 MB).

**Network stress is pod-to-pod.** Network stress deploys its own echo server and client pods that download a 64 KB payload in a loop. Traffic routes through CoreDNS (service name resolution) and kube-proxy/iptables (ClusterIP routing), saturating real network I/O. No RBAC, API server access, privileged mode, or `NET_ADMIN` capability is needed. To stress the API server with CRUD operations, use the `api` mode instead.

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

Each run creates `runs/YYYYMMDD-HHMMSS/` (or a custom path via `-o`) containing:

- **`kb-version.txt`** -- Binary path and full version output
- **`modes.env`** -- Human-readable KEY=VALUE record of selected contention modes and settings
- **`modes.json`** -- Machine-readable JSON of the same mode configuration
- **`safety-plan.txt`** -- Pre-flight safety plan: estimated pods, namespaces, API objects, and limit checks
- **`cluster-fingerprint.txt`** -- Best-effort cluster metadata: K8s version, node count, allocatable resources, CNI, metrics-server
- **`phases.jsonl`** -- One JSON line per phase: `{"phase", "uuid", "rc", "start", "end", "elapsed_s"}`
- **`probe.jsonl`** -- One JSON line per probe check: `{"ts", "phase", "probe", "latency_ms", "exit_code", "seq"}`
- **`summary.csv`** -- Phase-level CSV: phase, uuid, exit_code, start/end epochs, elapsed, pass/fail
- **`probe-stats.csv`** -- Probe latency percentiles per phase: count, min, p50, p95, max (ms)
- **`phase-*.log`** -- Raw kube-burner output for each phase
- **`failures.log`** -- Failure events with timestamps and reasons (only if failures occurred)
- **`cluster-monitor.log`** -- Timestamped node/pod resource usage and events (if `CLUSTER_MONITOR=1`)
- **`image-map.txt`** -- Image registry rewrites applied (or "(no rewrites)")
- **`staging/`** -- Staged copies of templates, workloads, and manifests used for this run

## Sharing results (support bundle)

Use `kubepyrometer bundle` to package a run's artifacts into a `.tar.gz` for sharing with teammates or support:

```bash
kubepyrometer bundle runs/20260306-113300
# Creates: runs/20260306-113300/kubepyrometer-20260306-113300.tar.gz
```

The bundle includes summaries, JSONL data, phase logs, cluster fingerprint, failure logs, and configuration snapshots. It excludes the `staging/` directory (bulky template copies) and any cluster credentials. The resulting archive is safe to attach to tickets or send to colleagues for review.

## Folder structure

```
kubepyrometer                       # CLI entry point (subcommands: run, init, summarize, etc.)
VERSION                             # Release version (e.g. 1.1.0)
Makefile                            # install / uninstall / dist targets
.github/workflows/release.yml      # GitHub Actions release automation
lib/
├── run.sh                          # Main harness entrypoint
├── config.yaml                     # Built-in defaults (source for `kubepyrometer init`)
├── .gitignore                      # Ignores bin/, runs/, logs, collected-metrics/
│
├── bin/                            # Auto-populated (gitignored)
│   ├── kube-burner                 #   Downloaded binary
│   └── .kb-version                 #   Version stamp file
│
├── configs/                        # Custom config files
│   ├── eks-small.yaml              #   Small EKS test parameters
│   └── profile-large.yaml          #   Profile: safer defaults for large clusters
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
│   ├── analyze.sh                  # Analyzes a run directory and explains results
│   ├── summarize.sh                # Generates summary.csv + probe-stats.csv from run data
│   ├── cluster-monitor.sh          # Lightweight cluster resource monitor (kubectl top + events)
│   ├── bundle-run.sh               # Packages run artifacts into a shareable .tar.gz
│   └── v0tui.sh                    # Interactive TUI (requires gum; optional fzf, jq)
│
├── workloads/                      # kube-burner job definitions
│   ├── probe.yaml                  #   Probe phase (creates a kubectl Job)
│   └── ramp-step.yaml              #   Ramp phase (all five stress modes + probe)
│
├── templates/                      # Kubernetes object templates (Go-templated)
│   ├── probe-job.yaml              #   Job: polls /readyz, list-nodes, list-configmaps
│   ├── cpu-stress.yaml             #   Deployment: busybox infinite CPU loop
│   ├── mem-stress.yaml             #   Deployment: busybox dd into /dev/shm
│   ├── disk-stress.yaml            #   Deployment: busybox dd write/delete on emptyDir
│   ├── net-echo-server.yaml         #   Deployment: busybox httpd echo server for net stress
│   ├── net-echo-service.yaml       #   Service: ClusterIP for echo server
│   ├── net-stress.yaml             #   Deployment: busybox wget loop hitting echo server
│   ├── api-stress-configmap.yaml   #   ConfigMap: lightweight object for API flood
│   └── api-stress-secret.yaml     #   Secret: lightweight object for API flood (etcd encryption)
│
├── manifests/
│   └── probe-rbac.yaml             # Namespace, ServiceAccount, RBAC for probes
│
└── runs/                           # Timestamped run artifact directories (gitignored)
    └── YYYYMMDD-HHMMSS/
        ├── kb-version.txt          #   Binary path + version output
        ├── modes.env               #   Contention mode selection + settings (KEY=VALUE)
        ├── modes.json              #   Same as modes.env in JSON format
        ├── safety-plan.txt         #   Pre-flight safety plan + limit checks
        ├── cluster-fingerprint.txt #   Best-effort cluster metadata snapshot
        ├── image-map.txt           #   Image registry rewrites (if any)
        ├── phases.jsonl            #   One JSON object per phase (rc, elapsed, uuid)
        ├── probe.jsonl             #   Probe measurements (latency, exit code, seq)
        ├── summary.csv             #   CSV summary of all phases
        ├── probe-stats.csv         #   Probe latency percentiles per phase
        ├── phase-*.log             #   Per-phase kube-burner stdout/stderr
        ├── failures.log            #   Failure events with reasons (if any)
        ├── cluster-monitor.log     #   Timestamped resource snapshots (if monitor enabled)
        └── staging/                #   Staged templates/workloads/manifests for this run
```

## File reference

### `kubepyrometer` (CLI entry point)

The top-level CLI wrapper. Resolves the data directory (`KUBEPYROMETER_HOME`), dispatches to subcommands (`run`, `analyze`, `init`, `summarize`, `monitor`, `tui`, `bundle`, `version`), and handles config file search (see [CLI commands](#cli-commands)). When installed via Homebrew, data files live under `$(brew --prefix)/libexec/kubepyrometer/`; from a repo checkout, they're found under `lib/`.

### `run.sh`

The core harness engine (called by `kubepyrometer run`). Accepts `-i` (full interactive), `-c` (contention mode prompts), `-r` (registry redirect prompts), `-p PROFILE` (load a config profile), `-f CONFIG` (config file path), `-o OUTDIR` (output directory), or no flags (non-interactive default). Resolves the kube-burner binary, parses the config file (and an optional profile), stages templates into the run directory, generates a filtered `ramp-step.yaml` containing only the enabled modes, computes and enforces safety limits, optionally applies image registry rewrites and `imagePullSecrets`, loads bundled images, applies RBAC, collects a cluster fingerprint, then orchestrates the four-phase sequence. During ramp steps, it checks for scheduling failures and quota violations, aborting early if issues are detected. All artifacts are collected into a timestamped `runs/` directory, even on failure.

**kube-burner resolution order:**
1. `KB_BIN` env var (must be executable; version-checked against v2.4.0 unless `KB_ALLOW_ANY=1`)
2. System `kube-burner` in `$PATH` (only if it reports v2.4.0)
3. `~/.kubepyrometer/bin/kube-burner` (when installed via Homebrew) or `lib/bin/kube-burner` (repo checkout) -- auto-downloaded via `install-kube-burner.sh` if missing

### `scripts/kind-smoke.sh`

Self-contained smoke test for **local dry runs only**. Creates a Kind cluster (or reuses an existing one named `kb-smoke`), pre-loads bundled images, runs the harness with `NONINTERACTIVE=1` and small parameter values, then asserts that all expected artifacts exist and contain the right phases. Cleans up the cluster on exit if it created one.

### `scripts/install-kube-burner.sh`

Downloads kube-burner v2.4.0 from GitHub Releases for the current OS/arch (`darwin`/`linux` + `amd64`/`arm64`). Tries multiple known asset name patterns until one succeeds. After extracting, verifies the binary reports v2.4.0 and writes a stamp file to `lib/bin/.kb-version`.

### `scripts/build-kube-burner.sh`

**Optional.** Builds kube-burner from a local source checkout using Go >= 1.23. Not called automatically by any script. Use only if you need a custom build.

### `scripts/save-images.sh`

Pulls `busybox:1.36.1` and `bitnami/kubectl:latest` via Docker and saves both into `lib/images/harness-images.tar`. Run this to refresh the bundled images.

### `scripts/load-images.sh`

Loads `lib/images/harness-images.tar` into the current cluster. Auto-detects Kind (via `kind-*` kubectl context prefix) and k3d. Falls back to `docker load`, which only helps when Docker Desktop is the Kubernetes runtime (Docker and kubelet share the image store). For remote clusters, this fallback is not useful -- use registry redirect instead. Called automatically by `kubepyrometer run` unless `IMAGE_MAP_FILE` or `SKIP_IMAGE_LOAD=1` is set.

### `scripts/analyze.sh`

Analyzes a completed run directory and prints a human-readable report. Covers: run overview (cluster, nodes, K8s version, verdict), phase-by-phase breakdown with timing and pass/fail, latency table (p50/p95/min/max per phase), degradation scoring vs baseline, recovery assessment, failure root-cause diagnosis (timeouts, image pulls, RBAC, schema errors), capacity context (stress pressure as a percentage of cluster resources), and actionable recommendations. No external dependencies -- works with bash, grep, sed, and awk. Called by `kubepyrometer analyze <run-dir>`.

### `scripts/summarize.sh`

Parses `phases.jsonl` from a run directory and writes `summary.csv` with columns: `phase, uuid, exit_code, start_epoch, end_epoch, elapsed_seconds, status`. Also computes per-phase probe latency percentiles from `probe.jsonl` and writes `probe-stats.csv` with columns: `phase, count, min_ms, p50_ms, p95_ms, max_ms`.

### `scripts/cluster-monitor.sh`

Lightweight cluster resource monitor. Periodically captures `kubectl top nodes`, `kubectl top pods` (in stress and probe namespaces), recent Kubernetes events, and node conditions. Can be run embedded (started automatically by `run.sh` when `CLUSTER_MONITOR=1`) or standalone in a separate terminal. Requires `metrics-server` for `kubectl top`; gracefully falls back to events-only mode if unavailable.

### `scripts/bundle-run.sh`

Packages a run directory's artifacts into a shareable `.tar.gz` support bundle. Includes summaries, JSONL data, phase logs, cluster fingerprint, failure logs, and configuration snapshots. Excludes the `staging/` directory and cluster credentials. Usage: `bash lib/scripts/bundle-run.sh runs/YYYYMMDD-HHMMSS`.

### `scripts/v0tui.sh`

Interactive terminal UI for the harness. Provides a menu-driven interface for running the harness, viewing results, editing config, running the smoke test, and cluster cleanup. Requires `gum` (auto-installed if missing). Optional: `fzf` (fuzzy file picker), `jq` (JSON processing; falls back to Python or grep).

### `workloads/probe.yaml`

kube-burner job definition for the probe phase. Creates a single Kubernetes Job (from `templates/probe-job.yaml`) that runs kubectl commands in a loop to measure API latency.

### `workloads/ramp-step.yaml`

kube-burner job definition for each ramp step. The checked-in file references all stress templates (CPU, memory, disk, network echo server + service + clients, API ConfigMap + Secret) plus the probe job. At runtime, `run.sh` generates a filtered copy in staging that includes only the enabled modes' objects.

### `templates/probe-job.yaml`

Kubernetes Job template. Runs a shell loop inside a `bitnami/kubectl:latest` container that performs up to three checks per iteration (`/readyz` if `PROBE_READYZ=1`, list nodes, list configmaps in `kube-system`) and emits one JSON line per check to stdout.

### `templates/cpu-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container with an infinite `while true; do :; done` loop, consuming a configurable amount of CPU (millicores). Unprivileged.

### `templates/mem-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container that uses `dd` to fill `/dev/shm` with a configurable number of megabytes, then sleeps forever. Mounts `/dev/shm` as a memory-backed `emptyDir` volume so the container can actually fill beyond the default 64 MB tmpfs limit. Unprivileged.

### `templates/disk-stress.yaml`

Kubernetes Deployment template. Runs a `busybox:1.36.1` container that continuously writes and deletes files on an `emptyDir` volume using `dd`. Write size is configurable via the `diskMb` input variable. No PVC or privileged mode required.

### `templates/net-echo-server.yaml`

Kubernetes Deployment template for the network stress echo server. Deploys 2 replicas of a `busybox:1.36.1` container running `httpd` serving a 64 KB zero-filled payload file. Created automatically when `MODE_NETWORK=on`.

### `templates/net-echo-service.yaml`

ClusterIP Service that load-balances traffic across the echo server pods. Client pods resolve `net-echo:8080` via in-namespace DNS.

### `templates/net-stress.yaml`

Kubernetes Deployment template for network stress client pods. Each pod runs a `wget` loop that downloads the 64 KB payload from the `net-echo` Service at a configurable interval. This generates real pod-to-pod network I/O without requiring any RBAC, API server access, or elevated privileges.

### `templates/api-stress-configmap.yaml`

Lightweight ConfigMap template used by the API stress mode. kube-burner creates these objects at the configured QPS to flood the Kubernetes API server with CRUD operations. No container images or pods are created -- kube-burner issues the API calls directly.

### `templates/api-stress-secret.yaml`

Lightweight Opaque Secret template used alongside the ConfigMap template in API stress mode. Secrets exercise the etcd encryption path (when encryption at rest is configured), making them a heavier write than ConfigMaps.

### `manifests/probe-rbac.yaml`

Creates the `kb-probe` namespace, a `probe-sa` ServiceAccount, a ClusterRole for `/readyz` and node listing (cluster-scoped), and a Role for configmap listing scoped to `kube-system`. The probe SA has read-only access and cannot modify any resources.
