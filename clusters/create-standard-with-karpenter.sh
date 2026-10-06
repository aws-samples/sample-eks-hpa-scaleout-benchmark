#!/usr/bin/env bash
# create-standard-with-karpenter.sh — Standard control-plane cluster WITH Karpenter set up
# correctly at creation time (IAM CloudFormation + IRSA), per the official Karpenter
# v1.14.1 getting-started. Verified against karpenter.sh docs (2026-09).
#
# The prior approach (bolt Karpenter onto an already-created cluster) was fiddly and
# error-prone — Karpenter IAM/IRSA is meant to be wired during cluster creation.
#
# Usage: ./create-standard-with-karpenter.sh
# Override via env: REGION, K8S_VERSION, KARPENTER_VERSION, CLUSTER_NAME.
set -euo pipefail

export KARPENTER_NAMESPACE="kube-system"
export KARPENTER_VERSION="${KARPENTER_VERSION:-1.14.1}"
export K8S_VERSION="${K8S_VERSION:-1.36}"
export AWS_PARTITION="aws"
export CLUSTER_NAME="${CLUSTER_NAME:-hpa-bench-standard}"
export AWS_DEFAULT_REGION="${REGION:-us-west-2}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TEMPOUT="$(mktemp)"
# AMI alias for the EC2NodeClass (resolves the recommended AL2023 AMI for this K8s version):
ALIAS_VERSION="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" --query Parameter.Value --output text | xargs -I{} aws ec2 describe-images --image-ids {} --query 'Images[0].Name' --output text | sed -r 's/^.*(v[[:digit:]]+).*$/\1/')"
export AWS_ACCOUNT_ID TEMPOUT ALIAS_VERSION

echo "Cluster=$CLUSTER_NAME region=$AWS_DEFAULT_REGION k8s=$K8S_VERSION karpenter=$KARPENTER_VERSION ami-alias=$ALIAS_VERSION"

echo "== 1. Deploy Karpenter IAM CloudFormation (controller policies, node role, interruption queue) =="
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "$TEMPOUT"
aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "$TEMPOUT" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region "$AWS_DEFAULT_REGION"

echo "== 2. Create cluster with OIDC + Karpenter IRSA role + node-role mapping + system NG =="
cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: karpenter
        namespace: ${KARPENTER_NAMESPACE}
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
  # System NG hosts add-ons AND the isolated load generator (labeled role=system).
  - name: system
    instanceType: m6i.large
    desiredCapacity: 4
    minSize: 4
    maxSize: 8
    labels: { role: system }
addons:
  - name: eks-pod-identity-agent
EOF

echo "== 3. Install Karpenter via Helm (IRSA-annotated SA) =="
helm registry logout public.ecr.aws 2>/dev/null || true
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter" \
  --set controller.resources.requests.cpu=1 --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 --set controller.resources.limits.memory=1Gi \
  --wait

echo "== 4. Apply benchmark NodePool + EC2NodeClass (app-only taint) =="
export CLUSTER_NAME AWS_ACCOUNT_ID ALIAS_VERSION
sed -e "s|CLUSTER_PLACEHOLDER|${CLUSTER_NAME}|g" -e "s|ALIAS_PLACEHOLDER|${ALIAS_VERSION}|g" karpenter/ec2nodeclass.yaml | kubectl apply -f -
kubectl apply -f karpenter/nodepool.yaml

echo "== Done. NodePool 'benchmark' ready (taint dedicated=benchmark:NoSchedule). =="
echo "Next: kubectl apply -f workload/ ; then scripts/run-benchmark.sh standard nobuffer"
echo "IMPORTANT (VERIFY): the CFN template creates a single KarpenterControllerPolicy-<cluster> in older versions;"
echo "  v1.14 may split it into multiple policies. Check the deployed stack Outputs and adjust attachPolicyARNs if needed."
