# Security Policy

## Disclaimer

This project is benchmark scaffolding provided as sample/educational code. It is **not**
intended for production use without additional security hardening. It is designed for
short-lived, dedicated test clusters that are torn down after each measurement run.
See "Production Hardening Recommendations" below.

## Reporting Vulnerabilities

If you discover a security vulnerability in this project, please report it via the
[AWS vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/).
Do not report security vulnerabilities through public GitHub issues.

## AWS Services Used

- **Amazon EKS** — hosts the benchmark cluster, including the Provisioned Control Plane
  tiers under test
- **Amazon EC2** — provides cluster nodes; the managed node group hosts add-ons and load
  generators, while Karpenter provisions the measured data-plane nodes
- **AWS Identity and Access Management (IAM)** — Karpenter controller role via IRSA, and
  the Karpenter node role
- **AWS CloudFormation** — deploys the Karpenter IAM stack (controller policies, node role,
  interruption queue)
- **AWS Systems Manager Parameter Store** — read-only lookup of the recommended EKS-optimized
  AMI ID
- **Amazon ECR Public** — source of the Karpenter Helm chart and the `pause` container image

## Prerequisites and Permissions

To deploy this solution you need:

- An AWS account with permissions to create Amazon EKS clusters, IAM roles and policies
  (via AWS CloudFormation), and Amazon EC2 instances
- A region with Provisioned Control Plane availability (default: `us-west-2`)
- Tools: `aws` CLI v2, `eksctl` >= 0.230, `kubectl`, `helm`, `jq`, `bash`, `python3`
  (plus `matplotlib` for the plot scripts)

Because the Karpenter CloudFormation stack creates named IAM resources, the deploying
principal needs IAM write permissions. Use a sandbox or development account, not a
production account.

## Known Security Considerations

These trade-offs were reviewed and accepted for this benchmark's scope. Each one must be
reconsidered before adapting this code for anything longer-lived.

| Item | Category | Rationale |
|------|----------|-----------|
| EKS API server endpoint is publicly reachable (`endpointPublicAccess=true` with no `publicAccessCidrs`) in `clusters/create-provisioned-cluster.sh` | Security Debt | EKS default behaviour; access is still authenticated by IAM. Accepted for operator convenience on short-lived, single-purpose benchmark clusters. |
| Karpenter IAM CloudFormation template is downloaded at run time and deployed with `CAPABILITY_NAMED_IAM` without checksum verification | Security Debt | Fetched over HTTPS from the official `aws/karpenter-provider-aws` repository, pinned to an immutable release tag. This mirrors the upstream Karpenter getting-started procedure. |
| No `NetworkPolicy` resources; all pod-to-pod traffic in the `benchmark` namespace is permitted | Security Debt | A network policy agent adds per-packet processing that would introduce variance into the latency measurements this benchmark exists to produce. The cluster is dedicated, short-lived, and processes no sensitive data. |
| Loadgen and pause container images are pinned by tag but not by digest | Security Debt | Explicit version tags were chosen over digests for readability in a sample meant to be read. Registries used are Docker Hub (official Fortio) and AWS-operated Amazon ECR Public. The application image (`registry.k8s.io/hpa-example`) is already pinned by digest. |
| Application container runs as root with six added Linux capabilities | Accepted (image constraint) | `registry.k8s.io/hpa-example` starts Apache as root to bind port 80 and setuids workers to `www-data`; it has no non-root mode. Mitigated by `drop: ALL` then minimal re-add, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, and `automountServiceAccountToken: false`. |
| No liveness probes on any workload | Accepted (measurement integrity) | A kubelet restart mid-run would corrupt the time-to-ready measurement. Readiness probes are present on the application. |

## Production Hardening Recommendations

Before using any of this in a production environment:

- **Restrict the cluster endpoint.** Set `endpointPublicAccess=false` (private-only;
  `endpointPrivateAccess=true` is already set) and reach the API server via a bastion,
  AWS Systems Manager Session Manager, or VPN. If public access is required, set
  `publicAccessCidrs` to a specific operator CIDR.
- **Verify the Karpenter IAM template.** Record and check the expected SHA-256 before
  deploying, or vendor the reviewed template into version control / an internal artifact
  store and deploy from there.
- **Add NetworkPolicies.** Start with default-deny in the workload namespace, then allow
  only loadgen → app:80 and app → DNS. Use the Amazon VPC CNI network policy controller.
- **Pin all images by digest** (`image:tag@sha256:...`), and mirror them into a private
  Amazon ECR repository with scan-on-push and immutable tags enabled.
- **Add liveness probes** to all long-running workloads.
- **Harden the application container further** — prefer an image with a non-root mode.
  `readOnlyRootFilesystem: true` is already enabled on the app container; Apache's only
  write paths (`/var/run/apache2`, `/var/lock/apache2`) are backed by `emptyDir` mounts.
- **Re-enable Karpenter consolidation and the interruption queue**, both of which are
  deliberately disabled here for measurement stability and are needed for cost efficiency
  and Spot handling in production.
- **Enable EKS control plane logging** (API, audit, authenticator) and consider
  Amazon GuardDuty EKS Protection.

## Resource Cleanup

Karpenter-launched nodes must be terminated **before** deleting the cluster, because
consolidation is disabled and Karpenter will not reclaim them:

1. `kubectl delete namespace benchmark --timeout=120s`
2. Terminate instances tagged `karpenter.sh/nodepool=benchmark` (see the Cleanup section
   in `README.md` for the exact AWS CLI command)
3. `eksctl delete cluster --name <cluster-name> --region <region> --disable-nodegroup-eviction --wait`
4. `aws cloudformation delete-stack --stack-name Karpenter-<cluster-name> --region <region>`
5. Verify no running instances remain tagged `karpenter.sh/nodepool=benchmark`, and no
   CloudFormation stacks are in `DELETE_FAILED` (clean up orphaned ENIs or security groups
   if one appears)

## Dependencies

| Dependency | Version | Notes |
|------------|---------|-------|
| `registry.k8s.io/hpa-example` | pinned by digest (`sha256:581697a3...`) | Canonical Kubernetes docs image for HPA demos. Runs Apache as root. |
| `fortio/fortio` | 1.75.3 | HTTP load generator. Pinned by tag; not digest-pinned. |
| `public.ecr.aws/eks-distro/kubernetes/pause` | 3.7 | AWS-distributed pause image used for warm-headroom placeholders. |
| Karpenter (Helm chart) | 1.14.1 | From `oci://public.ecr.aws/karpenter/karpenter`. Version pinned and overridable. |
| `matplotlib` | unpinned | Used only by the local plot scripts for figure rendering. Not a runtime dependency; never deployed. |
