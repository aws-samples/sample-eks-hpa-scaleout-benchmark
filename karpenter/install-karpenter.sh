#!/usr/bin/env bash
# install-karpenter.sh — set up Karpenter on a benchmark cluster (dry-run flagged this
# as the missing piece: the cluster had OIDC disabled and no node autoscaler).
#
# This wires: IAM OIDC provider, Karpenter controller IAM (via Pod Identity or IRSA),
# the Karpenter Helm release, and an EC2NodeClass named `default`. After this, apply
# karpenter/nodepool.yaml (+ capacity-buffer.yaml for the buffer arm).
#
# Usage: install-karpenter.sh <cluster-name>
#   REGION defaults to us-west-2. KARPENTER_VERSION pinned below — VERIFY latest/compat.
#
# IMPORTANT — this is scaffolding. Karpenter install steps differ between eksctl-managed
# and CLI-created clusters, and between Karpenter versions. VERIFY each step against the
# official Karpenter "Getting Started" for your version before running:
#   https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
set -euo pipefail

CLUSTER="${1:?cluster name}"
REGION="${REGION:-us-west-2}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.14.0}"   # CapacityBuffer (alpha) needs >= 1.14
# shellcheck disable=SC2034  # referenced by the commented iamidentitymapping example below
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "== 1. Ensure IAM OIDC provider is associated (needed for IRSA) =="
# For eksctl-managed clusters this is the simplest path:
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER" --region "$REGION" --approve

echo "== 2. Create Karpenter controller IAM + node role + interruption queue =="
# The Karpenter getting-started provides a CloudFormation template that creates the
# KarpenterController policy, KarpenterNodeRole, and the SQS interruption queue.
# Download + deploy it (URL/params are version-specific — VERIFY):
#   curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml -o /tmp/karpenter-cfn.yaml
#   aws cloudformation deploy --stack-name Karpenter-${CLUSTER} --template-file /tmp/karpenter-cfn.yaml \
#     --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ClusterName=${CLUSTER} --region ${REGION}
echo "   (VERIFY: deploy the version-matched Karpenter CloudFormation for IAM + interruption queue)"

echo "== 3. Map the Karpenter node role into aws-auth / access entries =="
#   eksctl create iamidentitymapping --cluster ${CLUSTER} --region ${REGION} \
#     --arn arn:aws:iam::${ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER} \
#     --group system:bootstrappers --group system:nodes --username system:node:{{EC2PrivateDNSName}}
echo "   (VERIFY: node role mapped so Karpenter-launched nodes can join)"

echo "== 4. Install Karpenter via Helm =="
helm registry logout public.ecr.aws 2>/dev/null || true
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set "settings.clusterName=${CLUSTER}" \
  --wait
# NOTE: deliberately NOT setting settings.interruptionQueue here. The interruption
# controller reacts to EC2 state-change noise (including your own cleanup between runs)
# and will drain healthy benchmark nodes mid-measurement — see the "No Karpenter
# interruption queue on benchmark clusters" rule in README.md. Only set it if you are
# using this script outside of a measured benchmark run.
# For the buffer arm, enable the CapacityBuffer alpha feature gate (VERIFY exact flag):
#   --set-string "controller.env[0].name=FEATURE_GATES" \
#   --set-string "controller.env[0].value=CapacityBuffers=true"

echo "== 5. Apply EC2NodeClass 'default' =="
cat <<'EOF' | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest      # VERIFY alias for your K8s version
  role: "KarpenterNodeRole-CLUSTER_PLACEHOLDER"   # replace with actual node role
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: "CLUSTER_PLACEHOLDER" }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: "CLUSTER_PLACEHOLDER" }
EOF

echo "== Done. Next: kubectl apply -f karpenter/nodepool.yaml  (+ capacity-buffer.yaml for buffer arm) =="
echo "NOTE: replace CLUSTER_PLACEHOLDER with '${CLUSTER}' and verify subnet/SG discovery tags exist."
