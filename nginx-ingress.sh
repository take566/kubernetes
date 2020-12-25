#!/bin/bash
 
CHART_NAME="center/stable/nginx-ingress"
CHART_VERSION="1.41.2"
RELEASE=nginx-ingress
NAMESPACE=nginx-ingress
VALUES_FILE=nginx-ingress.yaml
LB_STATIC_IP=35.197.192.35
 
generateValues() {
   cat << EOF > "${VALUES_FILE}"
# Override values for nginx-ingress
 
controller:
 
 ## Use host ports 80 and 443
 daemonset:
   useHostPort: true
 
 kind: DaemonSet
 
 service:
 
   ## Set static IP for LoadBalancer
   loadBalancerIP: ${LB_STATIC_IP}
 
   externalTrafficPolicy: Local
 
 stats:
   enabled: true
 
 metrics:
   enabled: true
EOF
}
 
generateValues
kubectl create ns nginx-ingress || true
echo
helm upgrade --install ${RELEASE} -n ${NAMESPACE} ${CHART_NAME} --version ${CHART_VERSION} -f ${VALUES_FILE}
echo
kubectl -n ${NAMESPACE} get all