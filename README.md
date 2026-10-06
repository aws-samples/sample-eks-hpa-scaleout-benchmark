# HPA Scale-Out Latency Benchmark for Amazon EKS

A reproducible benchmark that measures **time-to-ready (TTR)**, how long an
HPA-driven scale-out takes from traffic spike to pods actually serving, across:

- **Control-plane tier:** EKS Standard vs. [Provisioned Control Plane](https://aws.amazon.com/blogs/containers/amazon-eks-introduces-provisioned-control-plane/) (XL / 2XL)
- **Warm capacity:** [Karpenter](https://karpenter.sh/) with and without a capacity buffer

Companion code for the AWS Containers blog post
*"What actually speeds up Horizontal Pod Autoscaler scale-out on Amazon EKS"*.

The full matrix ran twice: on Kubernetes 1.31 (raw data in
[`results/`](results/)) and on Kubernetes 1.36 (raw data in
[`results/1.36/`](results/1.36/)).

**Headline results** (10 → 150 pods, identical closed-loop load, p50 TTR
with the new-node p50 in parentheses):

| Configuration | Kubernetes 1.31 | Kubernetes 1.36 |
|---------------|----------------:|----------------:|
| Standard | 38s (165s) | 25s (62s) |
| Provisioned XL | 38s (248s) | 39s (179s) |
| Provisioned 2XL | 40s (310s) | 38s (141s) |
| Standard + capacity buffer | 18s (88s) | 62s / 76s, two runs (134s / 118s) |

On both versions the control-plane tier didn't move scale-out latency; node
provisioning did. On 1.31 a Karpenter capacity buffer halved p50 TTR. On 1.36
cold node launches got fast enough (62s p50 vs 165s) that the buffer stopped
paying: preemption and backfill churn cost more than the warm nodes saved.
Measure your own cold path before reserving warm capacity.

## Repository layout

```
├── clusters/
│   ├── create-cluster.sh                  # one-command cluster create (Karpenter baked in,
│   │                                      #   optional Provisioned Control Plane tier)
│   ├── create-standard-with-karpenter.sh  # Standard-tier variant, fixed cluster name
│   ├── create-provisioned-cluster.sh      # AWS CLI path (no eksctl) for provisioned tiers
│   └── standard.yaml                      # minimal eksctl config (baseline reference)
├── karpenter/
│   ├── nodepool.yaml            # benchmark NodePool (tainted app-only, consolidation off)
│   ├── ec2nodeclass.yaml        # EC2NodeClass template (placeholders filled by create-cluster.sh)
│   ├── warm-headroom.yaml       # capacity buffer via the overprovisioning pattern (any Karpenter)
│   ├── capacity-buffer.yaml     # first-class CapacityBuffer CRD (Karpenter v1.14+, alpha gate)
│   └── install-karpenter.sh     # bolt-on Karpenter install for pre-existing clusters
├── workload/
│   ├── deployment.yaml          # CPU-burnable HTTP app + Service (HPA target)
│   └── hpa.yaml                 # HPA: 10 -> 300 pods @ 50% CPU
├── load/
│   ├── loadgen.yaml             # in-cluster Fortio load Deployment (closed-loop controlled)
│   └── spike.js                 # k6 profile (reference only, for an ALB-exposed variant)
├── scripts/
│   ├── run-benchmark.sh         # runs one matrix cell end to end, captures all data
│   ├── measure-ttr.sh           # per-pod TTR from pod condition timestamps
│   ├── analyze.sh               # aggregates runs; data-quality gate (>=80% pods Ready)
│   ├── plot-curve.py            # figure: ready pods vs. time
│   ├── plot-ttr-split.py        # figure: warm-node vs. new-node TTR
│   └── plot-version-compare.py  # figure: p50 TTR by config, 1.31 vs 1.36
└── results/                     # the four quality-gated runs behind the table above
```

## How it works

1. Each matrix cell gets its own short-lived EKS cluster: a 4-node managed
   node group (`role=system`) hosts Karpenter, metrics-server, and the load
   generators; a tainted Karpenter NodePool (`role=benchmark`) hosts only the
   measured app.
2. The app ([`hpa-example`](https://registry.k8s.io/hpa-example)) burns CPU per
   HTTP request, so HTTP load drives the CPU-based HPA. CPU limit > request so
   busy pods still pass readiness probes (request == limit causes readiness
   flapping that invalidates the data).
3. `run-benchmark.sh` applies in-cluster Fortio loaders and runs a **closed
   feedback loop**: every ~20s it scales loaders up/down to hold app CPU in a
   60–78% band — a sustained spike that forces pod scale-out *and* node
   provisioning without starving pods.
4. TTR comes from the API server's own records: pod `creationTimestamp` →
   `Ready` condition transition, for pods created after the spike. No agents.
5. `analyze.sh` aggregates runs and enforces a quality gate: any run where
   <80% of scaled-out pods reached `Ready` is flagged SUSPECT and excluded.

## Prerequisites

- AWS account with permissions to create Amazon EKS clusters, AWS Identity and Access
  Management (IAM) roles/policies (via AWS CloudFormation), and Amazon EC2 instances
- Tools: `aws` CLI (v2), `eksctl` (>= 0.230 for `controlPlaneScalingConfig`),
  `kubectl`, `helm`, `jq`, `bash`, `python3` (+ `matplotlib` for the plots)
- A region with Provisioned Control Plane availability (default: `us-west-2`)
- **Cost awareness:** a full four-cell matrix costs roughly $30–80 over a few
  hours (clusters, node groups, Karpenter-launched instances). Provisioned
  Control Plane tiers add an hourly premium — check current EKS pricing.
  Tear down each cell when done (see Cleanup).

## Quick start — run one cell

```bash
# 1. Create the cluster (Karpenter, NodePool, EC2NodeClass all wired in).
#    Standard tier:
./clusters/create-cluster.sh hpa-bench-std ""
#    Provisioned tier:  ./clusters/create-cluster.sh hpa-bench-xl tier-xl
aws eks update-kubeconfig --name hpa-bench-std --region us-west-2

# 2. (buffer arm only) add warm headroom — pick ONE:
kubectl create namespace benchmark
kubectl apply -f karpenter/warm-headroom.yaml      # portable overprovisioning pattern
# or: kubectl apply -f karpenter/capacity-buffer.yaml   # Karpenter v1.14+ alpha gate

# 3. Deploy the workload and wait for the 10-pod baseline to be Ready.
kubectl apply -f workload/
kubectl -n benchmark rollout status deploy/scaleout-app

# 4. Run the benchmark IN THE FOREGROUND (same target on every cell for fairness).
bash scripts/run-benchmark.sh std nobuffer 150 900
#    ... streams progress; prints "RESULTS CAPTURED" when data is on disk.

# 5. Validate data quality — only trust runs marked OK.
bash scripts/analyze.sh results/std-nobuffer-*
```

`run-benchmark.sh <tier-label> <buffer|nobuffer> [target_pods] [max_seconds]`
writes one directory per run:

```
results/<tier>-<buffer>-<UTC timestamp>/
├── spike_start          # epoch second the spike was launched
├── scaleout-curve.csv   # ts,ready,desired,cpu,bench_nodes,loaders (one row / ~10s)
└── ttr.csv              # per-pod: created, scheduled, ready, TTR seconds
```

## Run the full matrix

Repeat the quick start per cell — `standard`, `tier-xl`, `2xl` (all
`nobuffer`), plus `standard` + `buffer`. One cluster at a time keeps costs and
quota pressure down. Then aggregate and render the figures:

```bash
bash scripts/analyze.sh results/*                 # table: p50/p90, warm vs new node, quality
pip install matplotlib
python3 scripts/plot-curve.py results/<run1> results/<run2> ...      # scaleout-curve.png
python3 scripts/plot-ttr-split.py results/<run1> results/<run2> ...  # ttr-split.png
```

## Interpreting the results

- `ttr_created_to_ready_s` < 60s ⇒ the pod landed on an already-warm node;
  ≥ 60s ⇒ it waited for Karpenter to launch a node (the 60s cutoff is
  empirical — the two populations are far apart; see the raw CSVs).
- Compare **p50** across cells for the typical pod experience, **p90** for the
  tail (dominated by EC2 node-launch variability).
- Treat single runs as directional. For production-grade claims, repeat each
  cell 3–5× and confirm every run passes the `analyze.sh` quality gate.

## Benchmark integrity rules

Learned the hard way during dry runs; the harness encodes all of them:

- **Never `kubectl scale` the app** — the HPA owns replica count and reverts it.
  Scale-out must be load-driven.
- **Run `run-benchmark.sh` in the foreground** — it writes TTR to disk before
  returning; backgrounding it risks losing the capture.
- **Keep loaders off benchmark nodes** — loadgen pins to `role=system`, the app
  to tainted `role=benchmark` nodes, so loader CPU never pollutes the signal.
- **Consolidation stays off during runs** (`consolidateAfter: Never`) — node
  churn mid-run disrupts pods and corrupts TTR.
- **Only trust quality-gated runs** — `analyze.sh` rejects runs where <80% of
  pods reached Ready (readiness flapping / starvation).
- **Graceful node shutdown stays off on benchmark nodes** (EC2NodeClass user
  data sets `shutdownGracePeriod: 0s`). On 1.36 AL2023 nodes we observed false
  "imminent node shutdown" events that SIGTERM every pod; kubelet marks them
  `Succeeded` and never restarts them, silently corrupting TTR.
- **No Karpenter interruption queue on benchmark clusters.** The interruption
  controller reacts to EC2 state-change noise (including your own cleanup
  between runs) and drains healthy benchmark nodes mid-measurement.
- **Reset cells by deleting NodeClaims, not EC2 instances.** Karpenter-native
  cleanup avoids feeding state-change events into anything that reacts to them.
- **Group revision runs with `RESULTS_DIR`**, e.g.
  `RESULTS_DIR=results/1.36 bash scripts/run-benchmark.sh ...`.

## Cleanup

Terminate Karpenter-launched nodes **first** (consolidation is off, so
Karpenter won't reclaim them), then delete the cluster:

```bash
kubectl delete namespace benchmark --timeout=120s
IDS=$(aws ec2 describe-instances --region us-west-2 \
  --filters "Name=instance-state-name,Values=running,pending" \
            "Name=tag:karpenter.sh/nodepool,Values=benchmark" \
  --query "Reservations[].Instances[].InstanceId" --output text)
[ -n "$IDS" ] && aws ec2 terminate-instances --instance-ids $IDS
eksctl delete cluster --name <cluster-name> --region us-west-2 \
  --disable-nodegroup-eviction --wait
aws cloudformation delete-stack --stack-name Karpenter-<cluster-name> --region us-west-2
```

Verify: no running instances tagged `karpenter.sh/nodepool=benchmark`, no
`DELETE_FAILED` CloudFormation stacks (clean up orphaned ENIs/security groups
if one appears).

## Security

See [SECURITY.md](SECURITY.md) for the project's security posture, known
trade-offs, and production hardening recommendations. See
[CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for how to
report a vulnerability.

> This is sample code, for non-production usage. You should work with your
> security and legal teams to meet your organizational security, regulatory
> and compliance requirements before deployment.

This repository is benchmark scaffolding intended for short-lived, dedicated
test clusters — it is not production infrastructure. The manifests follow a
hardened baseline (images pinned by tag or digest, seccomp
`RuntimeDefault`, dropped capabilities, no service-account token automount,
non-root where images allow). The application image
(`registry.k8s.io/hpa-example`) is pinned by digest; the loadgen and pause
images are pinned by tag only (not yet digest-pinned — see
[SECURITY.md](SECURITY.md)). Documented exceptions live as
`checkov.io/skip` annotations on each manifest, and repo-level scan
configuration for [ASH](https://github.com/awslabs/automated-security-helper)
is in [`.ash/.ash.yaml`](.ash/.ash.yaml). Before adapting any of it for
production, add NetworkPolicies, digest-pin the remaining images, and add
liveness probes.

## Version notes

Validated with EKS 1.31 and 1.36, Karpenter v1.14.1, eksctl 0.230+ (2026-09).
Script defaults target 1.36; override with `K8S_VERSION`. Two APIs
worth re-verifying against current docs before you run:

- **Provisioned Control Plane tier**: `controlPlaneScalingConfig.tier`
  (eksctl) / `--control-plane-scaling-config tier=...` (AWS CLI).
- **Karpenter CapacityBuffer**: separate CRD
  `autoscaling.x-k8s.io/v1alpha1/CapacityBuffer`, alpha feature gate required
  (v1.14+). The overprovisioning pattern in `warm-headroom.yaml` works on any
  Karpenter version and is what the published benchmark used.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE)
file.
