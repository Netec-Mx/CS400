#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

CONFIG="${ROOT_DIR}/manifests/eks-cluster.yaml"

case "${1:-}" in
  create)
    cat > "$CONFIG" << YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${EKS_CLUSTER}
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"

availabilityZones:
  - ${AWS_REGION}a
  - ${AWS_REGION}b
  - ${AWS_REGION}c

managedNodeGroups:
  - name: ${EKS_NODEGROUP}
    instanceType: m6i.xlarge
    minSize: 5
    desiredCapacity: 5
    maxSize: 5
    volumeSize: 80

addonsConfig:
  autoApplyPodIdentityAssociations: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: metrics-server
  - name: eks-pod-identity-agent
  - name: aws-ebs-csi-driver
YAML

    if ! eksctl get cluster \
        --name "$EKS_CLUSTER" \
        --region "$AWS_REGION" \
        >/dev/null 2>&1; then
      eksctl create cluster -f "$CONFIG"
    fi

    aws eks update-kubeconfig \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION"

    kubectl wait \
      --for=condition=Ready \
      node \
      --all \
      --timeout=10m
    ;;

  delete)
    eksctl delete cluster \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      --wait
    ;;

  status)
    kubectl get nodes \
      -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
    ;;

  *)
    echo "Uso: $0 {create|status|delete}"
    exit 2
    ;;
esac
