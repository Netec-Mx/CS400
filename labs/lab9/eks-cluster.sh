#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

CONFIG="${ROOT_DIR}/manifests/eks-cluster.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: falta '$1' en PATH."
    exit 1
  }
}

precheck() {
  for cmd in aws eksctl kubectl helm curl jq python; do
    require_cmd "$cmd"
  done
  aws sts get-caller-identity --output table
}

write_config() {
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
    minSize: 4
    desiredCapacity: 4
    maxSize: 4
    volumeSize: 80
    labels:
      workload: couchbase

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
}

case "${1:-}" in
  create)
    precheck

    if ! eksctl get cluster \
        --name "$EKS_CLUSTER" \
        --region "$AWS_REGION" \
        >/dev/null 2>&1; then
      write_config
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

    kubectl get nodes \
      -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
    ;;

  status)
    precheck

    aws eks update-kubeconfig \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      >/dev/null

    kubectl get nodes \
      -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
    ;;

  delete)
    precheck

    if eksctl get cluster \
        --name "$EKS_CLUSTER" \
        --region "$AWS_REGION" \
        >/dev/null 2>&1; then
      eksctl delete cluster \
        --name "$EKS_CLUSTER" \
        --region "$AWS_REGION" \
        --wait
    fi
    ;;

  *)
    echo "Uso: $0 {create|status|delete}"
    exit 2
    ;;
esac