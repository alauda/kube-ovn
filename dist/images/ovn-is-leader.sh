#!/bin/bash
set -euo pipefail
shopt -s expand_aliases

alias ovn-ctl='/usr/share/ovn/scripts/ovn-ctl'

ovn-ctl status_northd
ovn-ctl status_ovnnb
ovn-ctl status_ovnsb

# For data consistency, only store leader address in endpoint
# Store ovn-nb leader to svc kube-system/ovn-nb
if [[ "$ENABLE_SSL" == "false" ]]; then
  nb_leader=$(ovsdb-client query tcp:127.0.0.1:6641 "[\"_Server\",{\"table\":\"Database\",\"where\":[[\"name\",\"==\", \"OVN_Northbound\"]],\"columns\": [\"leader\"],\"op\":\"select\"}]")
else
  nb_leader=$(ovsdb-client -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert query ssl:127.0.0.1:6641 "[\"_Server\",{\"table\":\"Database\",\"where\":[[\"name\",\"==\", \"OVN_Northbound\"]],\"columns\": [\"leader\"],\"op\":\"select\"}]")
fi

if [[ $nb_leader =~ "true" ]]
then
   kubectl label --overwrite pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-nb-leader=true
else
  kubectl label pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-nb-leader-
fi

# Store ovn-northd leader to svc kube-system/ovn-northd
northd_status=$(ovs-appctl -t /var/run/ovn/ovn-northd.$(cat /var/run/ovn/ovn-northd.pid).ctl status)
if [[ $northd_status =~ "active" ]]
then
   kubectl label --overwrite pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-northd-leader=true
else
  kubectl label pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-northd-leader-
fi

# Store ovn-sb leader to svc kube-system/ovn-sb
if [[ "$ENABLE_SSL" == "false" ]]; then
  sb_leader=$(ovsdb-client query tcp:127.0.0.1:6642 "[\"_Server\",{\"table\":\"Database\",\"where\":[[\"name\",\"==\", \"OVN_Southbound\"]],\"columns\": [\"leader\"],\"op\":\"select\"}]")
else
  sb_leader=$(ovsdb-client -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert query ssl:127.0.0.1:6642 "[\"_Server\",{\"table\":\"Database\",\"where\":[[\"name\",\"==\", \"OVN_Southbound\"]],\"columns\": [\"leader\"],\"op\":\"select\"}]")
fi

if [[ $sb_leader =~ "true" ]]
then
   kubectl label --overwrite pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-sb-leader=true
   northd_leader=$(kubectl get ep -n kube-system ovn-northd -o jsonpath={.subsets\[0\].addresses\[0\].ip})
   if [ "$northd_leader" == "" ]; then
      # no available northd leader try to release the lock
      set +e
      if [[ "$ENABLE_SSL" == "false" ]]; then
        ovsdb-client -v -t 1 steal tcp:127.0.0.1:6642  ovn_northd
      else
        ovsdb-client -v -t 1 -p /var/run/tls/key -c /var/run/tls/cert -C /var/run/tls/cacert steal ssl:127.0.0.1:6642  ovn_northd
      fi
      set -e
    fi
else
  kubectl label pod "$POD_NAME" -n "$POD_NAMESPACE" ovn-sb-leader-
fi
