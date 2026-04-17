#!/bin/bash
# Script to patch CoreDNS for YAS local domains

set -e

echo "Waiting for CoreDNS to be ready..."
kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=300s

# Lấy ClusterIP của Keycloak service (nếu đã tồn tại) hoặc dùng IP Ingress
if kubectl get svc -n keycloak keycloak-service &>/dev/null; then
    KEYCLOAK_IP=$(kubectl get svc -n keycloak keycloak-service -o jsonpath='{.spec.clusterIP}')
    echo "Found Keycloak service IP: $KEYCLOAK_IP"
else
    # Nếu Keycloak chưa được cài, dùng IP của Ingress Controller
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
    KEYCLOAK_IP=${INGRESS_IP}
    echo "Using Ingress Controller IP: $KEYCLOAK_IP"
fi

# Tạo patch file cho CoreDNS
cat > /tmp/coredns-patch.yaml << PATCH_EOF
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        hosts {
            ${KEYCLOAK_IP} identity.yas.local.com pgoperator.yas.local.com pgadmin.yas.local.com kibana.yas.local.com
            fallthrough
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
PATCH_EOF

echo "Patching CoreDNS ConfigMap..."
kubectl patch configmap coredns -n kube-system --patch-file /tmp/coredns-patch.yaml

echo "Restarting CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system

echo "Waiting for CoreDNS to restart..."
kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=120s

echo "Testing DNS resolution..."
kubectl run test-dns --image=busybox --rm -it --restart=Never -- nslookup identity.yas.local.com || echo "DNS test completed"

echo "CoreDNS patched successfully!"