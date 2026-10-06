#!/usr/bin/env bash
# create-provisioned-cluster.sh — create an EKS cluster with a Provisioned Control
# Plane tier using the CONFIRMED AWS CLI flag (verified against AWS docs 2026-09):
#   aws eks create-cluster ... --control-plane-scaling-config tier=tier-xl|tier-2xl|tier-4xl
#
# NOTE: eksctl 0.230+ also supports the tier via controlPlaneScalingConfig (see
# create-cluster.sh, the recommended path). This script is the eksctl-free
# alternative for environments that provision clusters with the AWS CLI directly;
# node groups are added separately (Karpenter, or an eksctl-managed nodegroup).
#
# Usage: create-provisioned-cluster.sh <tier-xl|tier-2xl> <cluster-name> <role-arn> <subnet-ids-csv> <sg-ids-csv>
set -euo pipefail

TIER="${1:?tier-xl | tier-2xl | tier-4xl}"
NAME="${2:?cluster name}"
ROLE_ARN="${3:?EKS cluster service role ARN}"
SUBNETS="${4:?comma-separated subnet IDs}"
SGS="${5:?comma-separated security group IDs}"
REGION="${REGION:-us-west-2}"
K8S_VERSION="${K8S_VERSION:-1.36}"

echo "Creating Provisioned Control Plane cluster '${NAME}' (tier=${TIER}) in ${REGION}..."
# endpointPublicAccess=true is for benchmark convenience on a short-lived cluster;
# for real environments restrict with publicAccessCidrs or use private-only access.
aws eks create-cluster \
  --name "$NAME" \
  --region "$REGION" \
  --kubernetes-version "$K8S_VERSION" \
  --role-arn "$ROLE_ARN" \
  --resources-vpc-config "subnetIds=${SUBNETS},securityGroupIds=${SGS},endpointPublicAccess=true,endpointPrivateAccess=true" \
  --control-plane-scaling-config "tier=${TIER}"

echo "Waiting for cluster ACTIVE..."
aws eks wait cluster-active --name "$NAME" --region "$REGION"
aws eks update-kubeconfig --name "$NAME" --region "$REGION"

echo "Verify tier:"
aws eks describe-cluster --name "$NAME" --region "$REGION" \
  --query 'cluster.controlPlaneScalingConfig' --output json

echo "Next: install Karpenter (helm) + EC2NodeClass, then apply karpenter/nodepool.yaml, then workload/."
