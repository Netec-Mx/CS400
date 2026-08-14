#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"
CONFIG_FILE="${ROOT_DIR}/manifests/eks-cluster.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: no se encontró '$1' en PATH."
    exit 1
  }
}

prerequisites() {
  for cmd in aws eksctl kubectl jq helm curl; do
    require_cmd "$cmd"
  done
  aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
}

write_config() {
  cat > "$CONFIG_FILE" << YAML
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
    minSize: 3
    desiredCapacity: 3
    maxSize: 3
    volumeSize: 60
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

create_cluster() {
  prerequisites
  if eksctl get cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "El clúster ya existe."
    aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION"
  else
    write_config
    eksctl create cluster -f "$CONFIG_FILE"
    aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION"
  fi
  kubectl wait --for=condition=Ready node --all --timeout=10m
  kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
}

status_cluster() {
  prerequisites
  aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null
  kubectl get nodes -o wide
  kubectl get storageclass
}

delete_cluster() {
  prerequisites
  if ! eksctl get cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "El clúster no existe."
    return
  fi
  eksctl delete cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" --wait
  echo "Clúster eliminado."
}

case "${1:-}" in
  create) create_cluster ;;
  status) status_cluster ;;
  delete) delete_cluster ;;
  *) echo "Uso: $0 {create|status|delete}"; exit 2 ;;
esac