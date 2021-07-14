#!/usr/bin/env bash
set -euo pipefail

IPv6=${IPv6:-false}
DualStack=${DualStack:-false}
ENABLE_SSL=${ENABLE_SSL:-false}
ENABLE_VLAN=${ENABLE_VLAN:-false}
ENABLE_MIRROR=${ENABLE_MIRROR:-false}
VLAN_NIC=${VLAN_NIC:-}
HW_OFFLOAD=${HW_OFFLOAD:-false}
ENABLE_LB=${ENABLE_LB:-true}
# The nic to support container network can be a nic name or a group of regex
# separated by comma, if empty will use the nic that the default route use
IFACE=""

CNI_CONF_DIR="/etc/cni/net.d"
CNI_BIN_DIR="/opt/cni/bin"

REGISTRY="kubeovn"
VERSION="v1.8.0"
IMAGE_PULL_POLICY="IfNotPresent"
POD_CIDR="10.16.0.0/16"                # Do NOT overlap with NODE/SVC/JOIN CIDR
POD_GATEWAY="10.16.0.1"
SVC_CIDR="10.96.0.0/12"                # Do NOT overlap with NODE/POD/JOIN CIDR
JOIN_CIDR="100.64.0.0/16"              # Do NOT overlap with NODE/POD/SVC CIDR
PINGER_EXTERNAL_ADDRESS="114.114.114.114"  # Pinger check external ip probe
PINGER_EXTERNAL_DOMAIN="alauda.cn"         # Pinger check external domain probe
if [ "$IPv6" = "true" ]; then
  POD_CIDR="fd00:10:16::/64"                # Do NOT overlap with NODE/SVC/JOIN CIDR
  POD_GATEWAY="fd00:10:16::1"
  SVC_CIDR="fd00:10:96::/112"               # Do NOT overlap with NODE/POD/JOIN CIDR
  JOIN_CIDR="fd00:100:64::/64"              # Do NOT overlap with NODE/POD/SVC CIDR
  PINGER_EXTERNAL_ADDRESS="2400:3200::1"
  PINGER_EXTERNAL_DOMAIN="google.com"
fi
if [ "$DualStack" = "true" ]; then
  POD_CIDR="10.16.0.0/16,fd00:10:16::/64"                # Do NOT overlap with NODE/SVC/JOIN CIDR
  POD_GATEWAY="10.16.0.1,fd00:10:16::1"
  SVC_CIDR="10.96.0.0/12"                                # Do NOT overlap with NODE/POD/JOIN CIDR
  JOIN_CIDR="100.64.0.0/16,fd00:100:64::/64"             # Do NOT overlap with NODE/POD/SVC CIDR
  PINGER_EXTERNAL_ADDRESS="114.114.114.114"
  PINGER_EXTERNAL_DOMAIN="google.com"
fi

EXCLUDE_IPS=""                         # EXCLUDE_IPS for default subnet
LABEL="node-role.kubernetes.io/master" # The node label to deploy OVN DB
NETWORK_TYPE="geneve"                  # geneve or vlan
TUNNEL_TYPE="geneve"                   # geneve or vxlan
POD_NIC_TYPE="veth-pair"               # veth-pair or internal-port

# VLAN Config only take effect when NETWORK_TYPE is vlan
PROVIDER_NAME="provider"
VLAN_INTERFACE_NAME=""
VLAN_NAME="ovn-vlan"
VLAN_ID="100"

if [ "$ENABLE_VLAN" = "true" ]; then
  NETWORK_TYPE="vlan"
  if [ "$VLAN_NIC" != "" ]; then
    VLAN_INTERFACE_NAME="$VLAN_NIC"
  fi
fi

# DPDK
DPDK="false"
DPDK_SUPPORTED_VERSIONS=("19.11")
DPDK_VERSION=""
DPDK_CPU="1000m"                        # Default CPU configuration for if --dpdk-cpu flag is not included
DPDK_MEMORY="2Gi"                       # Default Memory configuration for it --dpdk-memory flag is not included

display_help() {
    echo "Usage: $0 [option...]"
    echo
    echo "  -h, --help               Print Help (this message) and exit"
    echo "  --with-dpdk=<version>    Install Kube-OVN with OVS-DPDK instead of kernel OVS"
    echo "  --dpdk-cpu=<amount>m     Configure DPDK to use a specific amount of CPU"
    echo "  --dpdk-memory=<amount>Gi Configure DPDK to use a specific amount of memory"
    echo
    exit 0
}

if [ -n "${1-}" ]
then
  set +u
  while :; do
    case $1 in
      -h|--help)
        display_help
      ;;
      --with-dpdk=*)
        DPDK=true
        DPDK_VERSION="${1#*=}"
        if [[ ! "${DPDK_SUPPORTED_VERSIONS[@]}" = "${DPDK_VERSION}" ]] || [[ -z "${DPDK_VERSION}" ]]; then
          echo "Unsupported DPDK version: ${DPDK_VERSION}"
          echo "Supported DPDK versions: ${DPDK_SUPPORTED_VERSIONS[*]}"
          exit 1
        fi
      ;;
      --dpdk-cpu=*)
        DPDK_CPU="${1#*=}"
        if [[ $DPDK_CPU =~ ^[0-9]+(m)$ ]]
        then
           echo "CPU $DPDK_CPU"
        else
           echo "$DPDK_CPU is not valid, please use the format --dpdk-cpu=<amount>m"
           exit 1
        fi
      ;;
      --dpdk-memory=*)
        DPDK_MEMORY="${1#*=}"
        if [[ $DPDK_MEMORY =~ ^[0-9]+(Gi)$ ]]
        then
           echo "MEMORY $DPDK_MEMORY"
        else
           echo "$DPDK_MEMORY is not valid, please use the format --dpdk-memory=<amount>Gi"
           exit 1
        fi
      ;;
      -?*)
        echo "Unknown argument $1"
        exit 1
      ;;
      *) break
    esac
    shift
  done
  set -u
fi

if [[ $ENABLE_SSL = "true" ]];then
  echo "[Step 0] Generate SSL key and cert"
  exist=$(kubectl get secret -n kube-system kube-ovn-tls --ignore-not-found)
  if [[ $exist == "" ]];then
    docker run --rm -v "$PWD":/etc/ovn $REGISTRY/kube-ovn:$VERSION bash generate-ssl.sh
    kubectl create secret generic -n kube-system kube-ovn-tls --from-file=cacert=cacert.pem --from-file=cert=ovn-cert.pem --from-file=key=ovn-privkey.pem
    rm -rf cacert.pem ovn-cert.pem ovn-privkey.pem ovn-req.pem
  fi
  echo "-------------------------------"
  echo ""
fi

echo "[Step 1] Label kube-ovn-master node"
count=$(kubectl get no -l$LABEL --no-headers -o wide | wc -l | sed 's/ //g')
if [ "$count" = "0" ]; then
  echo "ERROR: No node with label $LABEL"
  exit 1
fi
kubectl label no -lbeta.kubernetes.io/os=linux kubernetes.io/os=linux --overwrite
kubectl label no -l$LABEL kube-ovn/role=master --overwrite
echo "-------------------------------"
echo ""

echo "[Step 2] Install OVN components"
addresses=$(kubectl get no -lkube-ovn/role=master --no-headers -o wide | awk '{print $6}' | tr \\n ',')
echo "Install OVN DB in $addresses"

cat <<EOF > kube-ovn-crd.yaml
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vpc-nat-gateways.kubeovn.io
spec:
  group: kubeovn.io
  names:
    plural: vpc-nat-gateways
    singular: vpc-nat-gateway
    shortNames:
      - vpc-nat-gw
    kind: VpcNatGateway
    listKind: VpcNatGatewayList
  scope: Cluster
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                dnatRules:
                  type: array
                  items:
                    type: object
                    properties:
                      eip:
                        type: string
                      externalPort:
                        type: string
                      internalIp:
                        type: string
                      internalPort:
                        type: string
                      protocol:
                        type: string
                eips:
                  type: array
                  items:
                    type: object
                    properties:
                      eipCIDR:
                        type: string
                      gateway:
                        type: string
                floatingIpRules:
                  type: array
                  items:
                    type: object
                    properties:
                      eip:
                        type: string
                      internalIp:
                        type: string
                lanIp:
                  type: string
                snatRules:
                  type: array
                  items:
                    type: object
                    properties:
                      eip:
                        type: string
                      internalCIDR:
                        type: string
                subnet:
                  type: string
                vpc:
                  type: string
      subresources:
        status: {}
  conversion:
    strategy: None
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vpcs.kubeovn.io
spec:
  group: kubeovn.io
  versions:
    - additionalPrinterColumns:
        - jsonPath: .status.standby
          name: Standby
          type: boolean
        - jsonPath: .status.subnets
          name: Subnets
          type: string
      name: v1
      schema:
        openAPIV3Schema:
          properties:
            spec:
              properties:
                namespaces:
                  items:
                    type: string
                  type: array
                staticRoutes:
                  items:
                    properties:
                      policy:
                        type: string
                      cidr:
                        type: string
                      nextHopIP:
                        type: string
                    type: object
                  type: array
              type: object
            status:
              properties:
                conditions:
                  items:
                    properties:
                      lastTransitionTime:
                        type: string
                      lastUpdateTime:
                        type: string
                      message:
                        type: string
                      reason:
                        type: string
                      status:
                        type: string
                      type:
                        type: string
                    type: object
                  type: array
                default:
                  type: boolean
                defaultLogicalSwitch:
                  type: string
                router:
                  type: string
                standby:
                  type: boolean
                subnets:
                  items:
                    type: string
                  type: array
                tcpLoadBalancer:
                  type: string
                tcpSessionLoadBalancer:
                  type: string
                udpLoadBalancer:
                  type: string
                udpSessionLoadBalancer:
                  type: string
              type: object
          type: object
      served: true
      storage: true
      subresources:
        status: {}
  names:
    kind: Vpc
    listKind: VpcList
    plural: vpcs
    shortNames:
      - vpc
    singular: vpc
  scope: Cluster
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ips.kubeovn.io
spec:
  group: kubeovn.io
  versions:
    - name: v1
      served: true
      storage: true
      additionalPrinterColumns:
      - name: V4IP
        type: string
        jsonPath: .spec.v4IpAddress
      - name: V6IP
        type: string
        jsonPath: .spec.v6IpAddress
      - name: Mac
        type: string
        jsonPath: .spec.macAddress
      - name: Node
        type: string
        jsonPath: .spec.nodeName
      - name: Subnet
        type: string
        jsonPath: .spec.subnet
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                podName:
                  type: string
                namespace:
                  type: string
                subnet:
                  type: string
                attachSubnets:
                  type: array
                  items:
                    type: string
                nodeName:
                  type: string
                ipAddress:
                  type: string
                v4IpAddress:
                  type: string
                v6IpAddress:
                  type: string
                attachIps:
                  type: array
                  items:
                    type: string
                macAddress:
                  type: string
                attachMacs:
                  type: array
                  items:
                    type: string
                containerID:
                  type: string
  scope: Cluster
  names:
    plural: ips
    singular: ip
    kind: IP
    shortNames:
      - ip
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: subnets.kubeovn.io
spec:
  group: kubeovn.io
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
      - name: Provider
        type: string
        jsonPath: .spec.provider
      - name: Vpc
        type: string
        jsonPath: .spec.vpc
      - name: Protocol
        type: string
        jsonPath: .spec.protocol
      - name: CIDR
        type: string
        jsonPath: .spec.cidrBlock
      - name: Private
        type: boolean
        jsonPath: .spec.private
      - name: NAT
        type: boolean
        jsonPath: .spec.natOutgoing
      - name: ExternalEgressGateway
        type: string
        jsonPath: .spec.externalEgressGateway
      - name: PolicyRoutingPriority
        type: integer
        jsonPath: .spec.policyRoutingPriority
      - name: PolicyRoutingTableID
        type: integer
        jsonPath: .spec.policyRoutingTableID
      - name: Default
        type: boolean
        jsonPath: .spec.default
      - name: GatewayType
        type: string
        jsonPath: .spec.gatewayType
      - name: V4Used
        type: number
        jsonPath: .status.v4usingIPs
      - name: V4Available
        type: number
        jsonPath: .status.v4availableIPs
      - name: V6Used
        type: number
        jsonPath: .status.v6usingIPs
      - name: V6Available
        type: number
        jsonPath: .status.v6availableIPs
      schema:
        openAPIV3Schema:
          type: object
          properties:
            status:
              type: object
              properties:
                v4availableIPs:
                  type: number
                v4usingIPs:
                  type: number
                v6availableIPs:
                  type: number
                v6usingIPs:
                  type: number
                activateGateway:
                  type: string
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type:
                        type: string
                      status:
                        type: string
                      reason:
                        type: string
                      message:
                        type: string
                      lastUpdateTime:
                        type: string
                      lastTransitionTime:
                        type: string
            spec:
              type: object
              properties:
                vpc:
                  type: string
                default:
                  type: boolean
                protocol:
                  type: string
                cidrBlock:
                  type: string
                namespaces:
                  type: array
                  items:
                    type: string
                gateway:
                  type: string
                provider:
                  type: string
                excludeIps:
                  type: array
                  items:
                    type: string
                gatewayType:
                  type: string
                allowSubnets:
                  type: array
                  items:
                    type: string
                gatewayNode:
                  type: string
                natOutgoing:
                  type: boolean
                externalEgressGateway:
                  type: string
                policyRoutingPriority:
                  type: integer
                  minimum: 1
                  maximum: 32765
                policyRoutingTableID:
                  type: integer
                  minimum: 1
                  maximum: 2147483647
                  not:
                    enum:
                      - 252 # compat
                      - 253 # default
                      - 254 # main
                      - 255 # local
                private:
                  type: boolean
                vlan:
                  type: string
                underlayGateway:
                  type: boolean
                disableInterConnection:
                  type: boolean
  scope: Cluster
  names:
    plural: subnets
    singular: subnet
    kind: Subnet
    shortNames:
      - subnet
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: vlans.kubeovn.io
spec:
  group: kubeovn.io
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                id:
                  type: integer
                  minimum: 0
                  maximum: 4095
                provider:
                  type: string
                vlanId:
                  type: integer
                  description: Deprecated in favor of id
                providerInterfaceName:
                  type: string
                  description: Deprecated in favor of provider
              required:
                - provider
            status:
              type: object
              properties:
                subnets:
                  type: array
                  items:
                    type: string
      additionalPrinterColumns:
      - name: ID
        type: string
        jsonPath: .spec.id
      - name: Provider
        type: string
        jsonPath: .spec.provider
  scope: Cluster
  names:
    plural: vlans
    singular: vlan
    kind: Vlan
    shortNames:
      - vlan
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: provider-networks.kubeovn.io
spec:
  group: kubeovn.io
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                defaultInterface:
                  type: string
                customInterfaces:
                  type: array
                  items:
                    type: object
                    properties:
                      interface:
                        type: string
                      nodes:
                        type: array
                        items:
                          type: string
                excludeNodes:
                  type: array
                  items:
                    type: string
              required:
                - defaultInterface
            status:
              type: object
              properties:
                readyNodes:
                  type: array
                  items:
                    type: string
                vlans:
                  type: array
                  items:
                    type: string
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      node:
                        type: string
                      type:
                        type: string
                      status:
                        type: string
                      reason:
                        type: string
                      message:
                        type: string
                      lastUpdateTime:
                        type: string
                      lastTransitionTime:
                        type: string
      additionalPrinterColumns:
      - name: DefaultInterface
        type: string
        jsonPath: .spec.defaultInterface
  scope: Cluster
  names:
    plural: provider-networks
    singular: provider-network
    kind: ProviderNetwork
    listKind: ProviderNetworkList
EOF

if $DPDK; then
  cat <<EOF > ovn.yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: kube-ovn
  annotations:
    seccomp.security.alpha.kubernetes.io/allowedProfileNames: '*'
spec:
  privileged: true
  allowPrivilegeEscalation: true
  allowedCapabilities:
    - '*'
  volumes:
    - '*'
  hostNetwork: true
  hostPorts:
    - min: 0
      max: 65535
  hostIPC: true
  hostPID: true
  runAsUser:
    rule: 'RunAsAny'
  seLinux:
    rule: 'RunAsAny'
  supplementalGroups:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'

---

apiVersion: v1
kind: ConfigMap
metadata:
  name: ovn-config
  namespace: kube-system

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovn
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.k8s.io/system-only: "true"
  name: system:ovn
rules:
  - apiGroups: ['policy']
    resources: ['podsecuritypolicies']
    verbs:     ['use']
    resourceNames:
      - kube-ovn
  - apiGroups:
      - "kubeovn.io"
    resources:
      - subnets
      - subnets/status
      - ips
      - vlans
      - provider-networks
      - provider-networks/status
    verbs:
      - "*"
  - apiGroups:
      - ""
    resources:
      - pods
      - namespaces
      - nodes
      - configmaps
    verbs:
      - create
      - get
      - list
      - watch
      - patch
      - update
  - apiGroups:
      - "k8s.cni.cncf.io"
    resources:
      - network-attachment-definitions
    verbs:
      - create
      - delete
      - get
      - list
      - update
  - apiGroups:
      - ""
      - networking.k8s.io
      - apps
      - extensions
    resources:
      - networkpolicies
      - services
      - endpoints
      - statefulsets
      - daemonsets
      - deployments
    verbs:
      - create
      - delete
      - update
      - patch
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
      - update

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovn
roleRef:
  name: system:ovn
  kind: ClusterRole
  apiGroup: rbac.authorization.k8s.io
subjects:
  - kind: ServiceAccount
    name: ovn
    namespace: kube-system

---
kind: Service
apiVersion: v1
metadata:
  name: ovn-nb
  namespace: kube-system
spec:
  ports:
    - name: ovn-nb
      protocol: TCP
      port: 6641
      targetPort: 6641
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-nb-leader: "true"
  sessionAffinity: None

---
kind: Service
apiVersion: v1
metadata:
  name: ovn-sb
  namespace: kube-system
spec:
  ports:
    - name: ovn-sb
      protocol: TCP
      port: 6642
      targetPort: 6642
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-sb-leader: "true"
  sessionAffinity: None

---
kind: Service
apiVersion: v1
metadata:
  name: ovn-northd
  namespace: kube-system
spec:
  ports:
    - name: ovn-northd
      protocol: TCP
      port: 6643
      targetPort: 6643
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-northd-leader: "true"
  sessionAffinity: None
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: ovn-central
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      OVN components: northd, nb and sb.
spec:
  replicas: $count
  strategy:
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
    type: RollingUpdate
  selector:
    matchLabels:
      app: ovn-central
  template:
    metadata:
      labels:
        app: ovn-central
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: ovn-central
              topologyKey: kubernetes.io/hostname
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      containers:
        - name: ovn-central
          image: "$REGISTRY/kube-ovn:$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command: ["/kube-ovn/start-db.sh"]
          securityContext:
            capabilities:
              add: ["SYS_NICE"]
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: NODE_IPS
              value: $addresses
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          resources:
            requests:
              cpu: 300m
              memory: 300Mi
            limits:
              cpu: 3
              memory: 3Gi
          volumeMounts:
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /etc/ovn
              name: host-config-ovn
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovn-is-leader.sh
            periodSeconds: 3
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovn-healthcheck.sh
            initialDelaySeconds: 30
            periodSeconds: 7
            failureThreshold: 5
            timeoutSeconds: 45
      nodeSelector:
        kubernetes.io/os: "linux"
        kube-ovn/role: "master"
      volumes:
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-config-ovn
          hostPath:
            path: /etc/origin/ovn
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls

---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: ovs-ovn
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      This daemon set launches the openvswitch daemon.
spec:
  selector:
    matchLabels:
      app: ovs
  updateStrategy:
    type: OnDelete
  template:
    metadata:
      labels:
        app: ovs
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      hostPID: true
      containers:
        - name: openvswitch
          image: "kubeovn/kube-ovn-dpdk:$DPDK_VERSION-$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command: ["/kube-ovn/start-ovs-dpdk.sh"]
          securityContext:
            runAsUser: 0
            privileged: true
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OVN_DB_IPS
              value: $addresses
          volumeMounts:
            - mountPath: /lib/modules
              name: host-modules
              readOnly: true
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/cni/net.d
              name: cni-conf
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /etc/ovn
              name: host-config-ovn
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /opt/ovs-config
              name: host-config-ovs
            - mountPath: /dev/hugepages
              name: hugepage
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovs-dpdk-healthcheck.sh
            periodSeconds: 5
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovs-dpdk-healthcheck.sh
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 5
            timeoutSeconds: 45
          resources:
            requests:
              cpu: $DPDK_CPU
              memory: $DPDK_MEMORY
            limits:
              cpu: $DPDK_CPU
              memory: $DPDK_MEMORY
              hugepages-1Gi: 1Gi
      nodeSelector:
        kubernetes.io/os: "linux"
      volumes:
        - name: host-modules
          hostPath:
            path: /lib/modules
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: cni-conf
          hostPath:
            path: /etc/cni/net.d
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-config-ovn
          hostPath:
            path: /etc/origin/ovn
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: host-config-ovs
          hostPath:
            path: /opt/ovs-config
            type: DirectoryOrCreate
        - name: hugepage
          emptyDir:
            medium: HugePages
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls
EOF

else
  cat <<EOF > ovn.yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: kube-ovn
  annotations:
    seccomp.security.alpha.kubernetes.io/allowedProfileNames: '*'
spec:
  privileged: true
  allowPrivilegeEscalation: true
  allowedCapabilities:
    - '*'
  volumes:
    - '*'
  hostNetwork: true
  hostPorts:
    - min: 0
      max: 65535
  hostIPC: true
  hostPID: true
  runAsUser:
    rule: 'RunAsAny'
  seLinux:
    rule: 'RunAsAny'
  supplementalGroups:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'

---

apiVersion: v1
kind: ConfigMap
metadata:
  name: ovn-config
  namespace: kube-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovn
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.k8s.io/system-only: "true"
  name: system:ovn
rules:
  - apiGroups: ['policy']
    resources: ['podsecuritypolicies']
    verbs:     ['use']
    resourceNames:
      - kube-ovn
  - apiGroups:
      - "kubeovn.io"
    resources:
      - vpcs
      - vpcs/status
      - vpc-nat-gateways
      - subnets
      - subnets/status
      - ips
      - vlans
      - provider-networks
      - provider-networks/status
      - networks
    verbs:
      - "*"
  - apiGroups:
      - ""
    resources:
      - pods
      - namespaces
      - nodes
      - configmaps
    verbs:
      - create
      - get
      - list
      - watch
      - patch
      - update
  - apiGroups:
      - ""
      - networking.k8s.io
      - apps
      - extensions
    resources:
      - networkpolicies
      - services
      - endpoints
      - statefulsets
      - daemonsets
      - deployments
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
      - update
  - apiGroups:
      - "k8s.cni.cncf.io"
    resources:
      - network-attachment-definitions
    verbs:
      - create
      - delete
      - get
      - list
      - update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovn
roleRef:
  name: system:ovn
  kind: ClusterRole
  apiGroup: rbac.authorization.k8s.io
subjects:
  - kind: ServiceAccount
    name: ovn
    namespace: kube-system
---
kind: Service
apiVersion: v1
metadata:
  name: ovn-nb
  namespace: kube-system
spec:
  ports:
    - name: ovn-nb
      protocol: TCP
      port: 6641
      targetPort: 6641
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-nb-leader: "true"
  sessionAffinity: None
---
kind: Service
apiVersion: v1
metadata:
  name: ovn-sb
  namespace: kube-system
spec:
  ports:
    - name: ovn-sb
      protocol: TCP
      port: 6642
      targetPort: 6642
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-sb-leader: "true"
  sessionAffinity: None
---
kind: Service
apiVersion: v1
metadata:
  name: ovn-northd
  namespace: kube-system
spec:
  ports:
    - name: ovn-northd
      protocol: TCP
      port: 6643
      targetPort: 6643
  type: ClusterIP
  selector:
    app: ovn-central
    ovn-northd-leader: "true"
  sessionAffinity: None
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: ovn-central
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      OVN components: northd, nb and sb.
spec:
  replicas: $count
  strategy:
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
    type: RollingUpdate
  selector:
    matchLabels:
      app: ovn-central
  template:
    metadata:
      labels:
        app: ovn-central
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: ovn-central
              topologyKey: kubernetes.io/hostname
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      containers:
        - name: ovn-central
          image: "$REGISTRY/kube-ovn:$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command: ["/kube-ovn/start-db.sh"]
          securityContext:
            capabilities:
              add: ["SYS_NICE"]
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: NODE_IPS
              value: $addresses
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          resources:
            requests:
              cpu: 300m
              memory: 200Mi
            limits:
              cpu: 3
              memory: 3Gi
          volumeMounts:
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /etc/ovn
              name: host-config-ovn
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovn-is-leader.sh
            periodSeconds: 3
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovn-healthcheck.sh
            initialDelaySeconds: 30
            periodSeconds: 7
            failureThreshold: 5
            timeoutSeconds: 45
      nodeSelector:
        kubernetes.io/os: "linux"
        kube-ovn/role: "master"
      volumes:
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-config-ovn
          hostPath:
            path: /etc/origin/ovn
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls
---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: ovs-ovn
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      This daemon set launches the openvswitch daemon.
spec:
  selector:
    matchLabels:
      app: ovs
  updateStrategy:
    type: OnDelete
  template:
    metadata:
      labels:
        app: ovs
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      hostPID: true
      containers:
        - name: openvswitch
          image: "$REGISTRY/kube-ovn:$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command: ["/kube-ovn/start-ovs.sh"]
          securityContext:
            runAsUser: 0
            privileged: true
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: HW_OFFLOAD
              value: "$HW_OFFLOAD"
            - name: TUNNEL_TYPE
              value: "$TUNNEL_TYPE"
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OVN_DB_IPS
              value: $addresses
          volumeMounts:
            - mountPath: /lib/modules
              name: host-modules
              readOnly: true
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/cni/net.d
              name: cni-conf
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /etc/ovn
              name: host-config-ovn
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
                - bash
                - -c
                - LOG_ROTATE=true /kube-ovn/ovs-healthcheck.sh
            periodSeconds: 5
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/ovs-healthcheck.sh
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 5
            timeoutSeconds: 45
          resources:
            requests:
              cpu: 200m
              memory: 200Mi
            limits:
              cpu: 1000m
              memory: 800Mi
      nodeSelector:
        kubernetes.io/os: "linux"
      volumes:
        - name: host-modules
          hostPath:
            path: /lib/modules
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: cni-conf
          hostPath:
            path: /etc/cni/net.d
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-config-ovn
          hostPath:
            path: /etc/origin/ovn
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls
EOF
fi

kubectl apply -f kube-ovn-crd.yaml
kubectl apply -f ovn.yaml
kubectl rollout status deployment/ovn-central -n kube-system
echo "-------------------------------"
echo ""

echo "[Step 3] Install Kube-OVN"

cat <<EOF > kube-ovn.yaml
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: kube-ovn-controller
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      kube-ovn controller
spec:
  replicas: $count
  selector:
    matchLabels:
      app: kube-ovn-controller
  strategy:
    rollingUpdate:
      maxSurge: 0%
      maxUnavailable: 100%
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: kube-ovn-controller
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: kube-ovn-controller
              topologyKey: kubernetes.io/hostname
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      containers:
        - name: kube-ovn-controller
          image: "$REGISTRY/kube-ovn:$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command:
          - /kube-ovn/start-controller.sh
          args:
          - --default-cidr=$POD_CIDR
          - --default-gateway=$POD_GATEWAY
          - --default-exclude-ips=$EXCLUDE_IPS
          - --node-switch-cidr=$JOIN_CIDR
          - --network-type=$NETWORK_TYPE
          - --default-interface-name=$VLAN_INTERFACE_NAME
          - --default-vlan-id=$VLAN_ID
          - --pod-nic-type=$POD_NIC_TYPE
          - --enable-lb=$ENABLE_LB
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: KUBE_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: OVN_DB_IPS
              value: $addresses
          volumeMounts:
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/kube-ovn-controller-healthcheck.sh
            periodSeconds: 3
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
                - bash
                - /kube-ovn/kube-ovn-controller-healthcheck.sh
            initialDelaySeconds: 300
            periodSeconds: 7
            failureThreshold: 5
            timeoutSeconds: 45
          resources:
            requests:
              cpu: 200m
              memory: 200Mi
            limits:
              cpu: 1000m
              memory: 1Gi
      nodeSelector:
        kubernetes.io/os: "linux"
      volumes:
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls

---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: kube-ovn-cni
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      This daemon set launches the kube-ovn cni daemon.
spec:
  selector:
    matchLabels:
      app: kube-ovn-cni
  template:
    metadata:
      labels:
        app: kube-ovn-cni
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      hostNetwork: true
      hostPID: true
      initContainers:
      - name: install-cni
        image: "$REGISTRY/kube-ovn:$VERSION"
        imagePullPolicy: $IMAGE_PULL_POLICY
        command: ["/kube-ovn/install-cni.sh"]
        securityContext:
          runAsUser: 0
          privileged: true
        volumeMounts:
          - mountPath: /opt/cni/bin
            name: cni-bin
      containers:
      - name: cni-server
        image: "$REGISTRY/kube-ovn:$VERSION"
        imagePullPolicy: $IMAGE_PULL_POLICY
        command:
          - bash
          - /kube-ovn/start-cniserver.sh
        args:
          - --enable-mirror=$ENABLE_MIRROR
          - --encap-checksum=false
          - --service-cluster-ip-range=$SVC_CIDR
          - --iface=${IFACE}
          - --network-type=$NETWORK_TYPE
          - --default-interface-name=$VLAN_INTERFACE_NAME
        securityContext:
          runAsUser: 0
          privileged: true
        env:
          - name: ENABLE_SSL
            value: "$ENABLE_SSL"
          - name: POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
          - name: KUBE_NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
        volumeMounts:
          - mountPath: /etc/openvswitch
            name: systemid
          - mountPath: /etc/cni/net.d
            name: cni-conf
          - mountPath: /run/openvswitch
            name: host-run-ovs
          - mountPath: /run/ovn
            name: host-run-ovn
          - mountPath: /var/run/netns
            name: host-ns
            mountPropagation: HostToContainer
          - mountPath: /etc/localtime
            name: localtime
        readinessProbe:
          exec:
            command:
              - nc
              - -z
              - -w3
              - 127.0.0.1
              - "10665"
          periodSeconds: 3
        livenessProbe:
          exec:
            command:
              - nc
              - -z
              - -w3
              - 127.0.0.1
              - "10665"
          initialDelaySeconds: 30
          periodSeconds: 7
          failureThreshold: 5
        resources:
          requests:
            cpu: 100m
            memory: 100Mi
          limits:
            cpu: 1000m
            memory: 1Gi
      nodeSelector:
        kubernetes.io/os: "linux"
      volumes:
        - name: systemid
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: cni-conf
          hostPath:
            path: $CNI_CONF_DIR
        - name: cni-bin
          hostPath:
            path: $CNI_BIN_DIR
        - name: host-ns
          hostPath:
            path: /var/run/netns
        - name: localtime
          hostPath:
            path: /etc/localtime

---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: kube-ovn-pinger
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      This daemon set launches the openvswitch daemon.
spec:
  selector:
    matchLabels:
      app: kube-ovn-pinger
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: kube-ovn-pinger
        component: network
        type: infra
    spec:
      tolerations:
        - operator: Exists
      serviceAccountName: ovn
      hostPID: true
      containers:
        - name: pinger
          image: "$REGISTRY/kube-ovn:$VERSION"
          command: ["/kube-ovn/kube-ovn-pinger", "--external-address=$PINGER_EXTERNAL_ADDRESS", "--external-dns=$PINGER_EXTERNAL_DOMAIN"]
          imagePullPolicy: $IMAGE_PULL_POLICY
          securityContext:
            runAsUser: 0
            privileged: false
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: HOST_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - mountPath: /lib/modules
              name: host-modules
              readOnly: true
            - mountPath: /run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          resources:
            requests:
              cpu: 100m
              memory: 100Mi
            limits:
              cpu: 200m
              memory: 400Mi
      nodeSelector:
        kubernetes.io/os: "linux"
      volumes:
        - name: host-modules
          hostPath:
            path: /lib/modules
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: kube-ovn-monitor
  namespace: kube-system
  annotations:
    kubernetes.io/description: |
      Metrics for OVN components: northd, nb and sb.
spec:
  replicas: $count
  strategy:
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
    type: RollingUpdate
  selector:
    matchLabels:
      app: kube-ovn-monitor
  template:
    metadata:
      labels:
        app: kube-ovn-monitor
        component: network
        type: infra
    spec:
      tolerations:
      - operator: Exists
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: kube-ovn-monitor
              topologyKey: kubernetes.io/hostname
      priorityClassName: system-cluster-critical
      serviceAccountName: ovn
      containers:
        - name: kube-ovn-monitor
          image: "$REGISTRY/kube-ovn:$VERSION"
          imagePullPolicy: $IMAGE_PULL_POLICY
          command: ["/kube-ovn/start-ovn-monitor.sh"]
          securityContext:
            runAsUser: 0
            privileged: false
          env:
            - name: ENABLE_SSL
              value: "$ENABLE_SSL"
            - name: NODE_IPS
              value: $addresses
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          resources:
            requests:
              cpu: 200m
              memory: 200Mi
            limits:
              cpu: 200m
              memory: 200Mi
          volumeMounts:
            - mountPath: /var/run/openvswitch
              name: host-run-ovs
            - mountPath: /var/run/ovn
              name: host-run-ovn
            - mountPath: /sys
              name: host-sys
              readOnly: true
            - mountPath: /etc/openvswitch
              name: host-config-openvswitch
            - mountPath: /etc/ovn
              name: host-config-ovn
            - mountPath: /var/log/openvswitch
              name: host-log-ovs
            - mountPath: /var/log/ovn
              name: host-log-ovn
            - mountPath: /etc/localtime
              name: localtime
            - mountPath: /var/run/tls
              name: kube-ovn-tls
          readinessProbe:
            exec:
              command:
              - cat
              - /var/run/ovn/ovnnb_db.pid
            periodSeconds: 3
            timeoutSeconds: 45
          livenessProbe:
            exec:
              command:
              - cat
              - /var/run/ovn/ovn-nbctl.pid
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 5
            timeoutSeconds: 45
      nodeSelector:
        kubernetes.io/os: "linux"
        kube-ovn/role: "master"
      volumes:
        - name: host-run-ovs
          hostPath:
            path: /run/openvswitch
        - name: host-run-ovn
          hostPath:
            path: /run/ovn
        - name: host-sys
          hostPath:
            path: /sys
        - name: host-config-openvswitch
          hostPath:
            path: /etc/origin/openvswitch
        - name: host-config-ovn
          hostPath:
            path: /etc/origin/ovn
        - name: host-log-ovs
          hostPath:
            path: /var/log/openvswitch
        - name: host-log-ovn
          hostPath:
            path: /var/log/ovn
        - name: localtime
          hostPath:
            path: /etc/localtime
        - name: kube-ovn-tls
          secret:
            optional: true
            secretName: kube-ovn-tls
---
kind: Service
apiVersion: v1
metadata:
  name: kube-ovn-monitor
  namespace: kube-system
  labels:
    app: kube-ovn-monitor
spec:
  ports:
    - name: metrics
      port: 10661
  type: ClusterIP
  selector:
    app: kube-ovn-monitor
  sessionAffinity: None
---
kind: Service
apiVersion: v1
metadata:
  name: kube-ovn-pinger
  namespace: kube-system
  labels:
    app: kube-ovn-pinger
spec:
  selector:
    app: kube-ovn-pinger
  ports:
    - port: 8080
      name: metrics
---
kind: Service
apiVersion: v1
metadata:
  name: kube-ovn-controller
  namespace: kube-system
  labels:
    app: kube-ovn-controller
spec:
  selector:
    app: kube-ovn-controller
  ports:
    - port: 10660
      name: metrics
---
kind: Service
apiVersion: v1
metadata:
  name: kube-ovn-cni
  namespace: kube-system
  labels:
    app: kube-ovn-cni
spec:
  selector:
    app: kube-ovn-cni
  ports:
    - port: 10665
      name: metrics
EOF

kubectl apply -f kube-ovn.yaml
kubectl rollout status deployment/kube-ovn-controller -n kube-system
kubectl rollout status daemonset/kube-ovn-cni -n kube-system
echo "-------------------------------"
echo ""

echo "[Step 4] Delete pod that not in host network mode"
for ns in $(kubectl get ns --no-headers -o  custom-columns=NAME:.metadata.name); do
  for pod in $(kubectl get pod --no-headers -n "$ns" --field-selector spec.restartPolicy=Always -o custom-columns=NAME:.metadata.name,HOST:spec.hostNetwork | awk '{if ($2!="true") print $1}'); do
    kubectl delete pod "$pod" -n "$ns" --ignore-not-found
  done
done

kubectl rollout status daemonset/kube-ovn-pinger -n kube-system
kubectl rollout status deployment/coredns -n kube-system
echo "-------------------------------"
echo ""

echo "[Step 5] Install kubectl plugin"
mkdir -p /usr/local/bin
cat <<\EOF > /usr/local/bin/kubectl-ko
#!/bin/bash
set -euo pipefail

KUBE_OVN_NS=kube-system
OVN_NB_POD=
OVN_SB_POD=

showHelp(){
  echo "kubectl ko {subcommand} [option...]"
  echo "Available Subcommands:"
  echo "  [nb|sb] [status|kick|backup]     ovn-db operations show cluster status, kick stale server or backup database"
  echo "  nbctl [ovn-nbctl options ...]    invoke ovn-nbctl"
  echo "  sbctl [ovn-sbctl options ...]    invoke ovn-sbctl"
  echo "  vsctl {nodeName} [ovs-vsctl options ...]   invoke ovs-vsctl on selected node"
  echo "  ofctl {nodeName} [ovs-ofctl options ...]   invoke ovs-ofctl on selected node"
  echo "  dpctl {nodeName} [ovs-dpctl options ...]   invoke ovs-dpctl on selected node"
  echo "  appctl {nodeName} [ovs-appctl options ...]   invoke ovs-appctl on selected node"
  echo "  tcpdump {namespace/podname} [tcpdump options ...]     capture pod traffic"
  echo "  trace {namespace/podname} {target ip address} {icmp|tcp|udp} [target tcp or udp port]    trace ovn microflow of specific packet"
  echo "  diagnose {all|node} [nodename]    diagnose connectivity of all nodes or a specific node"
}

tcpdump(){
  namespacedPod="$1"; shift
  namespace=$(echo "$namespacedPod" | cut -d "/" -f1)
  podName=$(echo "$namespacedPod" | cut -d "/" -f2)
  if [ "$podName" = "$namespacedPod" ]; then
    namespace="default"
  fi

  nodeName=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.spec.nodeName})
  hostNetwork=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.spec.hostNetwork})

  if [ -z "$nodeName" ]; then
    echo "Pod $namespacedPod not exists on any node"
    exit 1
  fi

  ovnCni=$(kubectl get pod -n $KUBE_OVN_NS -o wide| grep kube-ovn-cni| grep " $nodeName " | awk '{print $1}')
  if [ -z "$ovnCni" ]; then
    echo "kube-ovn-cni not exist on node $nodeName"
    exit 1
  fi

  if [ "$hostNetwork" = "true" ]; then
    set -x
    kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- tcpdump -nn "$@"
  else
    nicName=$(kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ovs-vsctl --data=bare --no-heading --columns=name find interface external-ids:iface-id="$podName"."$namespace" | tr -d '\r')
    if [ -z "$nicName" ]; then
      echo "nic doesn't exist on node $nodeName"
      exit 1
    fi
    podNicType=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.metadata.annotations.ovn\\.kubernetes\\.io/pod_nic_type})
    podNetNs=$(kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ovs-vsctl --data=bare --no-heading get interface "$nicName" external-ids:pod_netns | tr -d '\r')
    set -x
    if [ "$podNicType" = "internal-port" ]; then
      kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ip netns exec "$podNetNs" tcpdump -nn -i "$nicName" "$@"
    else
      kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ip netns exec "$podNetNs" tcpdump -nn -i eth0 "$@"
    fi
  fi
}

trace(){
  namespacedPod="$1"
  namespace=$(echo "$1" | cut -d "/" -f1)
  podName=$(echo "$1" | cut -d "/" -f2)
  if [ "$podName" = "$1" ]; then
    namespace="default"
  fi

  podIP=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.metadata.annotations.ovn\\.kubernetes\\.io/ip_address})
  mac=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.metadata.annotations.ovn\\.kubernetes\\.io/mac_address})
  ls=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.metadata.annotations.ovn\\.kubernetes\\.io/logical_switch})
  hostNetwork=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.spec.hostNetwork})
  nodeName=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.spec.nodeName})

  if [ "$hostNetwork" = "true" ]; then
    echo "Can not trace host network pod"
    exit 1
  fi

  if [ -z "$ls" ]; then
    echo "pod address not ready"
    exit 1
  fi

  vlan=$(kubectl get subnet "$ls" -o jsonpath={.spec.vlan})
  underlayGateway=$(kubectl get subnet "$ls" -o jsonpath={.spec.underlayGateway})

  gwMac=""
  if [ ! -z "$vlan" -a "$underlayGateway" = "true" ]; then
    ovnCni=$(kubectl get pod -n $KUBE_OVN_NS -o wide | grep -w kube-ovn-cni | grep " $nodeName " | awk '{print $1}')
    if [ -z "$ovnCni" ]; then
      echo "No kube-ovn-cni Pod running on node $nodeName"
      exit 1
    fi

    nicName=$(kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ovs-vsctl --data=bare --no-heading --columns=name find interface external-ids:iface-id="$podName"."$namespace" | tr -d '\r')
    if [ -z "$nicName" ]; then
      echo "nic doesn't exist on node $nodeName"
      exit 1
    fi

    gateway=$(kubectl get subnet "$ls" -o jsonpath={.spec.gateway})
    podNetNs=$(kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- ovs-vsctl --data=bare --no-heading get interface "$nicName" external-ids:pod_netns | tr -d '\r')

    podNicType=$(kubectl get pod "$podName" -n "$namespace" -o jsonpath={.metadata.annotations.ovn\\.kubernetes\\.io/pod_nic_type})
    if [ "$podNicType" != "internal-port" ]; then
      nicName="eth0"
    fi

    cmd="arping -c1 -i $nicName $gateway"
    if [ "$gateway" != "${1#*:[0-9a-fA-F]}" ]; then
      cmd="ndisc6 $gateway $nicName"
    fi
    output=$(kubectl exec "$ovnCni" -n $KUBE_OVN_NS -- nsenter --net="/var/run/netns/$podNetNs" sh -c "eval $cmd")
    if [ $? -ne 0 ]; then
      echo "failed to run 'arping -c1 -i $nicName $gateway' in Pod netns"
      exit 1
    fi
    gwMac=$(echo "$output" | grep -o -E grep -o -E '([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}')
  else
    gwMac=$(kubectl exec $OVN_NB_POD -n $KUBE_OVN_NS -c ovn-central -- ovn-nbctl --data=bare --no-heading --columns=mac find logical_router_port name=ovn-cluster-"$ls" | tr -d '\r')
  fi

  if [ -z "$gwMac" ]; then
    echo "get gw mac failed"
    exit 1
  fi

  dst="$2"
  if [ -z "$dst" ]; then
    echo "need a target ip address"
    exit 1
  fi

  type="$3"

  case $type in
    icmp)
      set -x
      kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovn-trace --ct=new "$ls" "inport == \"$podName.$namespace\" && ip.ttl == 64 && icmp && eth.src == $mac && ip4.src == $podIP && eth.dst == $gwMac && ip4.dst == $dst"
      ;;
    tcp|udp)
      set -x
      kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovn-trace --ct=new "$ls" "inport == \"$podName.$namespace\" && ip.ttl == 64 && eth.src == $mac && ip4.src == $podIP && eth.dst == $gwMac && ip4.dst == $dst && $type.src == 10000 && $type.dst == $4"
      ;;
    *)
      echo "type $type not supported"
      echo "kubectl ko trace {namespace/podname} {target ip address} {icmp|tcp|udp} [target tcp or udp port]"
      exit 1
      ;;
  esac

  set +x
  echo "--------"
  echo "Start OVS Tracing"
  echo ""
  echo ""

  ovsPod=$(kubectl get pod -n $KUBE_OVN_NS -o wide | grep " $nodeName " | grep ovs-ovn | awk '{print $1}')
  if [ -z "$ovsPod" ]; then
      echo "ovs pod  doesn't exist on node $nodeName"
      exit 1
  fi

  inPort=$(kubectl exec "$ovsPod" -n $KUBE_OVN_NS -- ovs-vsctl --format=csv --data=bare --no-heading --columns=ofport find interface external_id:iface-id="$podName"."$namespace")
    case $type in
    icmp)
      set -x
      kubectl exec "$ovsPod" -n $KUBE_OVN_NS -- ovs-appctl ofproto/trace br-int in_port="$inPort",icmp,nw_src="$podIP",nw_dst="$dst",dl_src="$mac",dl_dst="$gwMac"
      ;;
    tcp|udp)
      set -x
      kubectl exec "$ovsPod" -n $KUBE_OVN_NS -- ovs-appctl ofproto/trace br-int in_port="$inPort","$type",nw_src="$podIP",nw_dst="$dst",dl_src="$mac",dl_dst="$gwMac","$type"_src=1000,"$type"_dst="$4"
      ;;
    *)
      echo "type $type not supported"
      echo "kubectl ko trace {namespace/podname} {target ip address} {icmp|tcp|udp} [target tcp or udp port]"
      exit 1
      ;;
  esac
}

xxctl(){
  subcommand="$1"; shift
  nodeName="$1"; shift
  kubectl get no "$nodeName" > /dev/null
  ovsPod=$(kubectl get pod -n $KUBE_OVN_NS -o wide | grep " $nodeName " | grep ovs-ovn | awk '{print $1}')
  if [ -z "$ovsPod" ]; then
      echo "ovs pod  doesn't exist on node $nodeName"
      exit 1
  fi
  kubectl exec "$ovsPod" -n $KUBE_OVN_NS -- ovs-$subcommand "$@"
}

checkLeader(){
  component="$1"; shift
  count=$(kubectl get ep ovn-$component -n $KUBE_OVN_NS -o yaml | grep ip | wc -l)
  if [ $count -eq 0 ]; then
    echo "no ovn-$component exists !!"
    exit 1
  fi

  if [ $count -gt 1 ]; then
    echo "ovn-$component has more than one leader !!"
    exit 1
  fi

  echo "ovn-$component leader check ok"
}

diagnose(){
  kubectl get crd vpcs.kubeovn.io
  kubectl get crd vpc-nat-gateways.kubeovn.io
  kubectl get crd subnets.kubeovn.io
  kubectl get crd ips.kubeovn.io
  kubectl get crd vlans.kubeovn.io
  kubectl get crd provider-networks.kubeovn.io
  kubectl get svc kube-dns -n kube-system
  kubectl get svc kubernetes -n default
  kubectl get sa -n kube-system ovn
  kubectl get clusterrole system:ovn
  kubectl get clusterrolebinding ovn

  kubectl get no -o wide
  kubectl ko nbctl show
  kubectl ko nbctl lr-route-list ovn-cluster
  kubectl ko nbctl ls-lb-list ovn-default
  kubectl ko nbctl list acl
  kubectl ko sbctl show

  checkKubeProxy
  checkDeployment ovn-central
  checkDeployment kube-ovn-controller
  checkDaemonSet kube-ovn-cni
  checkDaemonSet ovs-ovn
  checkDeployment coredns

  checkLeader nb
  checkLeader sb
  checkLeader northd

  type="$1"
  case $type in
    all)
      echo "### kube-ovn-controller recent log"
      set +e
      kubectl logs -n $KUBE_OVN_NS -l app=kube-ovn-controller --tail=100 | grep E$(date +%m%d)
      set -e
      echo ""
      pingers=$(kubectl get pod -n $KUBE_OVN_NS | grep kube-ovn-pinger | awk '{print $1}')
      for pinger in $pingers
      do
        nodeName=$(kubectl get pod "$pinger" -n "$KUBE_OVN_NS" -o jsonpath={.spec.nodeName})
        echo "### start to diagnose node $nodeName"
        echo "#### ovn-controller log:"
        kubectl exec -n $KUBE_OVN_NS "$pinger" -- tail /var/log/ovn/ovn-controller.log
        echo ""
        echo "#### ovs-vswitchd log:"
        kubectl exec -n $KUBE_OVN_NS "$pinger" -- tail /var/log/openvswitch/ovs-vswitchd.log
        echo ""
        echo "#### ovs-vsctl show results:"
        kubectl exec -n $KUBE_OVN_NS "$pinger" -- ovs-vsctl show
        echo ""
        echo "#### pinger diagnose results:"
        kubectl exec -n $KUBE_OVN_NS "$pinger" -- /kube-ovn/kube-ovn-pinger --mode=job
        echo "### finish diagnose node $nodeName"
        echo ""
      done
      ;;
    node)
      nodeName="$2"
      kubectl get no "$nodeName" > /dev/null
      pinger=$(kubectl get pod -n $KUBE_OVN_NS -o wide | grep kube-ovn-pinger | grep " $nodeName " | awk '{print $1}')
      echo "### start to diagnose node nodeName"
      echo "#### ovn-controller log:"
      kubectl exec -n $KUBE_OVN_NS "$pinger" -- tail /var/log/ovn/ovn-controller.log
      echo ""
      echo "#### ovs-vswitchd log:"
      kubectl exec -n $KUBE_OVN_NS "$pinger" -- tail /var/log/openvswitch/ovs-vswitchd.log
      echo ""
      kubectl exec -n $KUBE_OVN_NS "$pinger" -- /kube-ovn/kube-ovn-pinger --mode=job
      echo "### finish diagnose node nodeName"
      echo ""
      ;;
    *)
      echo "type $type not supported"
      echo "kubectl ko diagnose {all|node} [nodename]"
      ;;
    esac
}

getOvnCentralPod(){
    NB_POD=$(kubectl get pod -n $KUBE_OVN_NS -l ovn-nb-leader=true | grep ovn-central | head -n 1 | awk '{print $1}')
    if [ -z "$NB_POD" ]; then
      echo "nb leader not exists"
      exit 1
    fi
    OVN_NB_POD=$NB_POD
    SB_POD=$(kubectl get pod -n $KUBE_OVN_NS -l ovn-sb-leader=true | grep ovn-central | head -n 1 | awk '{print $1}')
    if [ -z "$SB_POD" ]; then
      echo "nb leader not exists"
      exit 1
    fi
    OVN_SB_POD=$SB_POD
}

checkDaemonSet(){
  name="$1"
  currentScheduled=$(kubectl get ds -n $KUBE_OVN_NS "$name" -o jsonpath={.status.currentNumberScheduled})
  desiredScheduled=$(kubectl get ds -n $KUBE_OVN_NS "$name" -o jsonpath={.status.desiredNumberScheduled})
  available=$(kubectl get ds -n $KUBE_OVN_NS "$name" -o jsonpath={.status.numberAvailable})
  ready=$(kubectl get ds -n $KUBE_OVN_NS "$name" -o jsonpath={.status.numberReady})
  if [ "$currentScheduled" = "$desiredScheduled" ] && [ "$desiredScheduled" = "$available" ] && [ "$available" = "$ready" ]; then
    echo "ds $name ready"
  else
    echo "Error ds $name not ready"
    exit 1
  fi
}

checkDeployment(){
  name="$1"
  ready=$(kubectl get deployment -n $KUBE_OVN_NS "$name" -o jsonpath={.status.readyReplicas})
  updated=$(kubectl get deployment -n $KUBE_OVN_NS "$name" -o jsonpath={.status.updatedReplicas})
  desire=$(kubectl get deployment -n $KUBE_OVN_NS "$name" -o jsonpath={.status.replicas})
  available=$(kubectl get deployment -n $KUBE_OVN_NS "$name" -o jsonpath={.status.availableReplicas})
  if [ "$ready" = "$updated" ] && [ "$updated" = "$desire" ] && [ "$desire" = "$available" ]; then
    echo "deployment $name ready"
  else
    echo "Error deployment $name not ready"
    exit 1
  fi
}

checkKubeProxy(){
  dsMode=`kubectl get ds -n kube-system | grep kube-proxy || true`
  if [ -z "$dsMode" ]; then
    nodeIps=`kubectl get node -o wide | grep -v "INTERNAL-IP" | awk '{print $6}'`
    for node in $nodeIps
    do
      healthResult=`curl -g -6 -sL -w %{http_code} http://[$node]:10256/healthz -o /dev/null | grep -v 200 || true`
      if [ -n "$healthResult" ]; then
        echo "$node kube-proxy's health check failed"
        exit 1
      fi
    done
  else
    checkDaemonSet kube-proxy
  fi
  echo "kube-proxy ready"
}

dbtool(){
  suffix=$(date +%m%d%H%M%s)
  component="$1"; shift
  action="$1"; shift
  case $component in
    nb)
      case $action in
        status)
          kubectl exec "$OVN_NB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound
          ;;
        kick)
          kubectl exec "$OVN_NB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/kick OVN_Northbound "$1"
          ;;
        backup)
          kubectl exec "$OVN_NB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovsdb-tool cluster-to-standalone /etc/ovn/ovnnb_db.$suffix.backup /etc/ovn/ovnnb_db.db
          kubectl cp $KUBE_OVN_NS/$OVN_NB_POD:/etc/ovn/ovnnb_db.$suffix.backup $(pwd)/ovnnb_db.$suffix.backup
          kubectl exec "$OVN_NB_POD" -n $KUBE_OVN_NS -c ovn-central -- rm -f /etc/ovn/ovnnb_db.$suffix.backup
          echo "backup $component to $(pwd)/ovnnb_db.$suffix.backup"
          ;;
        *)
          echo "unknown action $action"
      esac
      ;;
    sb)
      case $action in
        status)
          kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound
          ;;
        kick)
          kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/kick OVN_Southbound "$1"
          ;;
        backup)
          kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovsdb-tool cluster-to-standalone /etc/ovn/ovnsb_db.$suffix.backup /etc/ovn/ovnsb_db.db
          kubectl cp $KUBE_OVN_NS/$OVN_SB_POD:/etc/ovn/ovnsb_db.$suffix.backup $(pwd)/ovnsb_db.$suffix.backup
          kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- rm -f /etc/ovn/ovnsb_db.$suffix.backup
          echo "backup $component to $(pwd)/ovnsb_db.$suffix.backup"
          ;;
        *)
          echo "unknown action $action"
      esac
      ;;
    *)
      echo "unknown subcommand $component"
  esac
}

if [ $# -lt 1 ]; then
  showHelp
  exit 0
else
  subcommand="$1"; shift
fi

getOvnCentralPod

case $subcommand in
  nbctl)
    kubectl exec "$OVN_NB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovn-nbctl "$@"
    ;;
  sbctl)
    kubectl exec "$OVN_SB_POD" -n $KUBE_OVN_NS -c ovn-central -- ovn-sbctl "$@"
    ;;
  vsctl|ofctl|dpctl|appctl)
    xxctl "$subcommand" "$@"
    ;;
  nb|sb)
    dbtool "$subcommand" "$@"
    ;;
  tcpdump)
    tcpdump "$@"
    ;;
  trace)
    trace "$@"
    ;;
  diagnose)
    diagnose "$@"
    ;;
  *)
    showHelp
    ;;
esac

EOF

chmod +x /usr/local/bin/kubectl-ko
echo "-------------------------------"
echo ""

echo ":$PATH:" | grep -q ":/usr/local/bin:"
if [  $? != 0  ]; then
  echo "Tips:Please join the /usr/local/bin to your PATH. Temporarily, we do it for this execution."
  export PATH=/usr/local/bin:$PATH
  echo "-------------------------------"
  echo ""
fi

echo "[Step 6] Run network diagnose"
kubectl ko diagnose all

echo "-------------------------------"
echo ""
