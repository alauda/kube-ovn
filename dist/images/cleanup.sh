#!/bin/bash
set -eu

for subnet in $(kubectl get subnet -o name); do
  kubectl patch "$subnet" --type='json' -p '[{"op": "remove", "path": "/metadata/finalizers"}]'
done

# Delete Kube-OVN components
kubectl delete -f https://raw.githubusercontent.com/alauda/kube-ovn/master/yamls/kube-ovn.yaml --ignore-not-found=true
kubectl delete -f https://raw.githubusercontent.com/alauda/kube-ovn/master/yamls/ovn.yaml --ignore-not-found=true
kubectl delete -f https://raw.githubusercontent.com/alauda/kube-ovn/master/yamls/crd.yaml --ignore-not-found=true

# Remove annotations in all pods of all namespaces
for ns in $(kubectl get ns -o name |cut -c 11-); do
  echo "annotating pods in  ns:$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/cidr- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/gateway- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/ip_address- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/logical_switch- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/mac_address- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/port_name- -n "$ns"
  kubectl annotate pod  --all ovn.kubernetes.io/allocated- -n "$ns"
done
  
# Remove annotations in namespaces and nodes
kubectl annotate no --all ovn.kubernetes.io/cidr-
kubectl annotate no --all ovn.kubernetes.io/gateway-
kubectl annotate no --all ovn.kubernetes.io/ip_address-
kubectl annotate no --all ovn.kubernetes.io/logical_switch-
kubectl annotate no --all ovn.kubernetes.io/mac_address-
kubectl annotate no --all ovn.kubernetes.io/port_name-
kubectl annotate ns --all ovn.kubernetes.io/cidr-
kubectl annotate ns --all ovn.kubernetes.io/exclude_ips-
kubectl annotate ns --all ovn.kubernetes.io/gateway-
kubectl annotate ns --all ovn.kubernetes.io/logical_switch-
kubectl annotate ns --all ovn.kubernetes.io/private-
kubectl annotate ns --all ovn.kubernetes.io/allow-
