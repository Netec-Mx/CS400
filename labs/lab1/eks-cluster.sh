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
  for cmd in aws eksctl kubectl jq; do
    require_cmd "$cmd"
  done

  echo "Validando sesión AWS..."
  aws sts get-caller-identity >/dev/null

  echo "Cuenta AWS:"
  aws sts get-caller-identity \
    --query '{Account:Account,Arn:Arn}' \
    --output table
}

write_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"

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
    instanceType: m6i.large
    minSize: 3
    desiredCapacity: 3
    maxSize: 3
    volumeSize: 40
    privateNetworking: false
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

wait_for_nodes() {
  echo "Esperando que los nodos Kubernetes estén Ready..."
  kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=10m

  kubectl get nodes -o wide
}

create_cluster() {
  prerequisites

  if eksctl get cluster \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      >/dev/null 2>&1; then
    echo "El clúster ${EKS_CLUSTER} ya existe. No se creará nuevamente."
    aws eks update-kubeconfig \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION"
    wait_for_nodes
    return
  fi

  write_config

  echo "Creando Amazon EKS ${EKS_CLUSTER}..."
  eksctl create cluster -f "$CONFIG_FILE"

  echo "Actualizando kubeconfig..."
  aws eks update-kubeconfig \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"

  wait_for_nodes

  echo "Add-ons instalados:"
  eksctl get addon \
    --cluster "$EKS_CLUSTER" \
    --region "$AWS_REGION"
}

delete_cluster() {
  prerequisites

  if ! eksctl get cluster \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      >/dev/null 2>&1; then
    echo "El clúster ${EKS_CLUSTER} no existe; no hay infraestructura EKS que eliminar."
    return
  fi

  echo "Eliminando Amazon EKS ${EKS_CLUSTER} y recursos administrados..."
  eksctl delete cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION" \
    --wait

  echo "Validando eliminación..."
  if eksctl get cluster \
      --name "$EKS_CLUSTER" \
      --region "$AWS_REGION" \
      >/dev/null 2>&1; then
    echo "ERROR: el clúster todavía aparece registrado."
    exit 1
  fi

  echo "Clúster ${EKS_CLUSTER} eliminado correctamente."
}

status_cluster() {
  prerequisites

  eksctl get cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"

  aws eks update-kubeconfig \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION" \
    >/dev/null

  kubectl get nodes -o wide
  kubectl get storageclass
}

case "${1:-}" in
  create)
    create_cluster
    ;;
  delete)
    delete_cluster
    ;;
  status)
    status_cluster
    ;;
  *)
    echo "Uso: $0 {create|status|delete}"
    exit 2
    ;;
esac