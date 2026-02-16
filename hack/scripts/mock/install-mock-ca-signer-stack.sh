#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../utils/env.sh"
source "$SCRIPT_DIR/../utils/kube.sh"

CLUSTER_NAME="${CLUSTER_NAME:-external-ca-cluster}"
require_bin helm kubectl

log "installing cert-manager and trust-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
if kubectl -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
  log "cert-manager already exists in cluster; skipping helm install"
else
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true
fi
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=5m
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m

if kubectl -n cert-manager get deploy trust-manager >/dev/null 2>&1; then
  log "trust-manager already exists in cluster; skipping helm install"
else
  helm upgrade --install trust-manager jetstack/trust-manager \
    --namespace cert-manager \
    --create-namespace \
    --set app.trust.namespace=cert-manager
fi
kubectl -n cert-manager rollout status deploy/trust-manager --timeout=5m

log "deploying mock csrsigner-proxy"
kubectl -n kube-system apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: csrsigner-proxy
  labels:
    app: csrsigner-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: csrsigner-proxy
  template:
    metadata:
      labels:
        app: csrsigner-proxy
    spec:
      containers:
      - name: proxy
        image: registry.k8s.io/pause:3.10
YAML

log "deploying mock cert-manager-approver"
kubectl -n cert-manager apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-manager-approver
  labels:
    app: cert-manager-approver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cert-manager-approver
  template:
    metadata:
      labels:
        app: cert-manager-approver
    spec:
      containers:
      - name: approver
        image: registry.k8s.io/pause:3.10
YAML

log "deploying mock kms-issuer"
kubectl -n kube-system apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kms-issuer-mock
  labels:
    app: kms-issuer-mock
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kms-issuer-mock
  template:
    metadata:
      labels:
        app: kms-issuer-mock
    spec:
      containers:
      - name: issuer
        image: registry.k8s.io/pause:3.10
YAML

log "installing mock kmsissuer CRD"
kubectl apply -f - <<'YAML'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: kmsissuers.cert-manager.kmsservice.io
spec:
  group: cert-manager.kmsservice.io
  names:
    kind: KmsIssuer
    listKind: KmsIssuerList
    plural: kmsissuers
    singular: kmsissuer
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
          status:
            type: object
            properties:
              conditions:
                type: array
                items:
                  type: object
                  properties:
                    reason:
                      type: string
YAML

log "creating mock kmsissuers with Issued status"
kubectl -n kube-system apply -f - <<YAML
apiVersion: cert-manager.kmsservice.io/v1alpha1
kind: KmsIssuer
metadata:
  name: ${CLUSTER_NAME}-api
status:
  conditions:
  - reason: Issued
---
apiVersion: cert-manager.kmsservice.io/v1alpha1
kind: KmsIssuer
metadata:
  name: ${CLUSTER_NAME}-etcd
status:
  conditions:
  - reason: Issued
YAML

log "mock external signer stack installed"
