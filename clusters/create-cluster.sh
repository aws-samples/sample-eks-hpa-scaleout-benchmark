#!/usr/bin/env bash
# create-cluster.sh — parameterized cluster create with Karpenter (reuses the validated
# Standard flow) and an optional Provisioned Control Plane tier.
#
# Usage:
#   ./create-cluster.sh <cluster-name> [tier]
#     tier: (omit)=Standard | tier-xl | tier-2xl | tier-4xl
#
# eksctl 0.230+ supports controlPlaneScalingConfig.tier in the config schema (verified).
set -euo pipefail

export CLUSTER_NAME="${1:?cluster name}"
export TIER="${2:-}"                       # empty = Standard control plane
export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.14.1}"
export K8S_VERSION="${K8S_VERSION:-1.36}"
export AWS_PARTITION="aws"
export AWS_DEFAULT_REGION="${REGION:-us-west-2}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"
ALIAS_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value --output text | xargs -I{} aws ec2 describe-images --image-ids {} --query 'Images[0].Name' --output text | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"
export AWS_ACCOUNT_ID TEMPOUT ALIAS_VERSION

# Karpenter IAM stack is per-cluster-name; deploy if absent.
echo "Cluster=$CLUSTER_NAME tier=${TIER:-standard} region=$AWS_DEFAULT_REGION"
echo "== Karpenter IAM CloudFormation =="
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "$TEMPOUT"
aws cloudformation deploy --stack-name "Karpenter-${CLUSTER_NAME}" --template-file "$TEMPOUT" \
  --capabilities CAPABILITY_NAMED_IAM --parameter-overrides "ClusterName=${CLUSTER_NAME}" --region "$AWS_DEFAULT_REGION"

# Build optional tier block.
TIER_BLOCK=""
[ -n "$TIER" ] && TIER_BLOCK=$(printf 'controlPlaneScalingConfig:\n  tier: %s' "$TIER")

echo "== Create cluster (with Karpenter IRSA + system NG)${TIER:+ [tier=$TIER]} =="
cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
${TIER_BLOCK}
iam:
  withOIDC: true
  serviceAccounts:
    - metadata: { name: karpenter, namespace: ${KARPENTER_NAMESPACE} }
      roleName: ${CLUSTER_NAME}-karpenter
      attachPolicyARNs:
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}
        - arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerZonalShiftPolicy-${CLUSTER_NAME}
      roleOnly: true
iamIdentityMappings:
  - arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
    username: system:node:{{EC2PrivateDNSName}}
    groups: [system:bootstrappers, system:nodes]
managedNodeGroups:
  - name: system
    instanceType: m6i.large
    desiredCapacity: 4
    minSize: 4
    maxSize: 8
    labels: { role: system }
addons:
  - name: eks-pod-identity-agent
  - name: metrics-server   # required by the HPA; EKS community addon
EOF

echo "== Install Karpenter =="
helm registry logout public.ecr.aws 2>/dev/null || true
# NOTE: interruptionQueue intentionally NOT set. On these short-lived, on-demand
# benchmark clusters the interruption controller reacts to EC2 state-change noise
# (including out-of-band terminations during cell resets) and drains healthy
# benchmark nodes mid-run, invalidating the TTR data. Verified live on 1.36.
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter" \
  --set controller.resources.requests.cpu=1 --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 --set controller.resources.limits.memory=1Gi --wait

echo "== Apply NodePool + EC2NodeClass =="
sed -e "s|CLUSTER_PLACEHOLDER|${CLUSTER_NAME}|g" -e "s|ALIAS_PLACEHOLDER|${ALIAS_VERSION}|g" karpenter/ec2nodeclass.yaml | kubectl apply -f -
kubectl apply -f karpenter/nodepool.yaml
echo "== Done: ${CLUSTER_NAME} (tier=${TIER:-standard}) =="
