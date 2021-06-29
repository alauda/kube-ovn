GOFILES_NOVENDOR = $(shell find . -type f -name '*.go' -not -path "./vendor/*")
GO_VERSION = 1.15

REGISTRY = kubeovn
DEV_TAG = dev
RELEASE_TAG = $(shell cat VERSION)
COMMIT = git-$(shell git rev-parse --short HEAD)
DATE = $(shell date +"%Y-%m-%d_%H:%M:%S")
GOLDFLAGS = "-w -s -X github.com/kubeovn/kube-ovn/versions.COMMIT=$(COMMIT) -X github.com/kubeovn/kube-ovn/versions.VERSION=$(RELEASE_TAG) -X github.com/kubeovn/kube-ovn/versions.BUILDDATE=$(DATE)"

# ARCH could be amd64,arm64
ARCH = amd64

.PHONY: build-go
build-go:
	go mod tidy
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o $(CURDIR)/dist/images/kube-ovn -ldflags $(GOLDFLAGS) -v ./cmd/cni
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o $(CURDIR)/dist/images/kube-ovn-cmd -ldflags $(GOLDFLAGS) -v ./cmd

.PHONY: build-go-arm
build-go-arm:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o $(CURDIR)/dist/images/kube-ovn -ldflags $(GOLDFLAGS) -v ./cmd/cni
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o $(CURDIR)/dist/images/kube-ovn-cmd -ldflags $(GOLDFLAGS) -v ./cmd

.PHONY: build-bin
build-bin:
	docker run --rm -e GOOS=linux -e GOCACHE=/tmp -e GOARCH=$(ARCH) -e GOPROXY=https://goproxy.cn \
		-u $(shell id -u):$(shell id -g) \
		-v $(CURDIR):/go/src/github.com/kubeovn/kube-ovn:ro \
		-v $(CURDIR)/dist:/go/src/github.com/kubeovn/kube-ovn/dist/ \
		golang:$(GO_VERSION) /bin/bash -c '\
		cd /go/src/github.com/kubeovn/kube-ovn && \
		make build-go '

.PHONY: build-dev-images
build-dev-images: build-bin
	docker build -t $(REGISTRY)/kube-ovn:$(DEV_TAG) --build-arg ARCH=amd64 -f dist/images/Dockerfile dist/images/

.PHONY: build-dpdk
build-dpdk:
	docker buildx build --platform linux/amd64 -t $(REGISTRY)/kube-ovn-dpdk:19.11-$(RELEASE_TAG) -o type=docker -f dist/images/Dockerfile.dpdk1911 dist/images/

.PHONY: base-amd64
base-amd64:
	docker buildx build --platform linux/amd64 --build-arg ARCH=amd64 -t $(REGISTRY)/kube-ovn-base:$(RELEASE_TAG)-amd64 -o type=docker -f dist/images/Dockerfile.base dist/images/

.PHONY: base-arm64
base-arm64:
	docker buildx build --platform linux/arm64 --build-arg ARCH=arm64 -t $(REGISTRY)/kube-ovn-base:$(RELEASE_TAG)-arm64 -o type=docker -f dist/images/Dockerfile.base dist/images/

.PHONY: release
release: lint build-go
	docker buildx build --platform linux/amd64 --build-arg ARCH=amd64 -t $(REGISTRY)/kube-ovn:$(RELEASE_TAG) -o type=docker -f dist/images/Dockerfile dist/images/
	docker buildx build --platform linux/amd64 --build-arg ARCH=amd64 -t $(REGISTRY)/vpc-nat-gateway:$(RELEASE_TAG) -o type=docker -f dist/images/vpcnatgateway/Dockerfile dist/images/vpcnatgateway

.PHONY: release-arm
release-arm: build-go-arm
	docker buildx build --platform linux/arm64 --build-arg ARCH=arm64 -t $(REGISTRY)/kube-ovn:$(RELEASE_TAG) -o type=docker -f dist/images/Dockerfile dist/images/
	docker buildx build --platform linux/arm64 --build-arg ARCH=arm64 -t $(REGISTRY)/vpc-nat-gateway:$(RELEASE_TAG) -o type=docker -f dist/images/vpcnatgateway/Dockerfile dist/images/vpcnatgateway

.PHONY: push-dev
push-dev:
	docker push $(REGISTRY)/kube-ovn:$(DEV_TAG)

.PHONY: push-release
push-release: release
	docker push $(REGISTRY)/kube-ovn:$(RELEASE_TAG)

.PHONY: tar
tar:
	docker save $(REGISTRY)/kube-ovn:$(RELEASE_TAG) > image.tar

.PHONY: base-tar-amd64
base-tar-amd64:
	docker save $(REGISTRY)/kube-ovn-base:$(RELEASE_TAG)-amd64 > image-amd64.tar

.PHONY: base-tar-arm64
base-tar-arm64:
	docker save $(REGISTRY)/kube-ovn-base:$(RELEASE_TAG)-arm64 > image-arm64.tar

.PHONY: kind-init
kind-init:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=ipvs ip_family=ipv4 ha=false single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-init-iptables
kind-init-iptables:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=iptables ip_family=ipv4 ha=false single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-init-ha
kind-init-ha:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=ipvs ip_family=ipv4 ha=true single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-init-single
kind-init-single:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=ipvs ip_family=ipv4 ha=false single=true j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-init-ipv6
kind-init-ipv6:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=iptables ip_family=ipv6 ha=false single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-init-dual
kind-init-dual:
	kind delete cluster --name=kube-ovn
	kube_proxy_mode=iptables ip_family=DualStack ha=false single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no
	docker exec kube-ovn-worker sysctl -w net.ipv6.conf.all.disable_ipv6=0
	docker exec kube-ovn-control-plane sysctl -w net.ipv6.conf.all.disable_ipv6=0

.PHONY: kind-install
kind-install:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true dist/images/install.sh
	kubectl describe no

.PHONY: kind-install-vlan
kind-install-vlan:
	$(eval SUBNET = $(shell docker network inspect kind -f "{{(index .IPAM.Config 0).Subnet}}"))
	$(eval GATEWAY = $(shell docker network inspect kind -f "{{(index .IPAM.Config 0).Gateway}}"))
	$(eval EXCLUDE_IPS = $(shell docker network inspect kind -f '{{range .Containers}},{{index (split .IPv4Address "/") 0}}{{end}}' | sed 's/^,//'))
	sed -e 's@^[[:space:]]*POD_CIDR=.*@POD_CIDR="$(SUBNET)"@' \
		-e 's@^[[:space:]]*POD_GATEWAY=.*@POD_GATEWAY="$(GATEWAY)"@' \
		-e 's@^[[:space:]]*EXCLUDE_IPS=.*@EXCLUDE_IPS="$(EXCLUDE_IPS)"@' \
		-e 's@^DEFAULT_VLAN_ID=.*@DEFAULT_VLAN_ID="0"@' \
		dist/images/install.sh > install-vlan.sh
	chmod +x install-vlan.sh
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true ENABLE_VLAN=true VLAN_NIC=eth0 ./install-vlan.sh
	kubectl describe no

.PHONY: kind-install-multiple-vlan
kind-install-multiple-vlan:
	docker network connect bridge kube-ovn-control-plane
	docker network connect bridge kube-ovn-worker
	$(eval SUBNET = $(shell docker network inspect kind -f "{{(index .IPAM.Config 0).Subnet}}"))
	$(eval GATEWAY = $(shell docker network inspect kind -f "{{(index .IPAM.Config 0).Gateway}}"))
	$(eval EXCLUDE_IPS = $(shell docker network inspect kind -f '{{range .Containers}},{{index (split .IPv4Address "/") 0}}{{end}}' | sed 's/^,//'))
	sed -e 's@^[[:space:]]*POD_CIDR=.*@POD_CIDR="$(SUBNET)"@' \
		-e 's@^[[:space:]]*POD_GATEWAY=.*@POD_GATEWAY="$(GATEWAY)"@' \
		-e 's@^[[:space:]]*EXCLUDE_IPS=.*@EXCLUDE_IPS="$(EXCLUDE_IPS)"@' \
		-e 's@^DEFAULT_VLAN_ID=.*@DEFAULT_VLAN_ID="0"@' \
		-e 's@^EXTRA_PROVIDER_NAMES=.*@EXTRA_PROVIDER_NAMES="extra"@' \
		-e 's@^EXTRA_VLAN_INTERFACE_NAMES=.*@EXTRA_VLAN_INTERFACE_NAMES="eth1"@' \
		-e 's@^EXTRA_VLAN_NAMES=.*@EXTRA_VLAN_NAMES="extra"@' \
		-e 's@^EXTRA_VLAN_IDS=.*@EXTRA_VLAN_IDS="0"@' \
		-e 's@^EXTRA_VLAN_RANGES=.*@EXTRA_VLAN_RANGES="1,4095"@' \
		dist/images/install.sh > install-vlan.sh
	chmod +x install-vlan.sh
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	# kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true ENABLE_VLAN=true VLAN_NIC=eth0 ./install-vlan.sh
	kubectl describe no

.PHONY: kind-install-single
kind-install-single:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	ENABLE_SSL=true dist/images/install.sh
	kubectl describe no

.PHONY: kind-install-ipv6
kind-install-ipv6:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true IPv6=true dist/images/install.sh

.PHONY: kind-install-ipv6-vlan
kind-install-ipv6-vlan:
	docker network inspect bridge
	docker network inspect kind
	$(eval SUBNET = $(shell docker network inspect kind -f "{{(index .IPAM.Config 1).Subnet}}"))
	$(eval GATEWAY = $(shell docker network inspect kind -f "{{(index .IPAM.Config 1).Gateway}}"))
	$(eval EXCLUDE_IPS = $(shell docker network inspect kind -f '{{range .Containers}},{{index (split .IPv6Address "/") 0}}{{end}}' | sed 's/^,//'))
ifeq ($(GATEWAY),)
	$(eval GATEWAY = $(shell docker exec kube-ovn-worker ip -6 route show default | awk '{print $$3}'))
endif
	sed -e 's@^[[:space:]]*POD_CIDR=.*@POD_CIDR="$(SUBNET)"@' \
		-e 's@^[[:space:]]*POD_GATEWAY=.*@POD_GATEWAY="$(GATEWAY)"@' \
		-e 's@^[[:space:]]*EXCLUDE_IPS=.*@EXCLUDE_IPS="$(EXCLUDE_IPS)"@' \
		-e 's@^DEFAULT_VLAN_ID=.*@DEFAULT_VLAN_ID="0"@' \
		dist/images/install.sh > install-vlan.sh
	chmod +x install-vlan.sh
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true IPv6=true ENABLE_VLAN=true VLAN_NIC=eth0 ./install-vlan.sh

.PHONY: kind-install-dual
kind-install-dual:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl taint node kube-ovn-control-plane node-role.kubernetes.io/master:NoSchedule-
	ENABLE_SSL=true DualStack=true dist/images/install.sh
	kubectl describe no

.PHONY: kind-reload
kind-reload:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)
	kubectl delete pod -n kube-system -l app=kube-ovn-controller
	kubectl delete pod -n kube-system -l app=kube-ovn-cni
	kubectl delete pod -n kube-system -l app=kube-ovn-pinger

.PHONY: kind-clean
kind-clean:
	kind delete cluster --name=kube-ovn

.PHONY: uninstall
uninstall:
	bash dist/images/cleanup.sh

.PHONY: lint
lint:
	@gofmt -d $(GOFILES_NOVENDOR)
	@gofmt -l $(GOFILES_NOVENDOR) | read && echo "Code differs from gofmt's style" 1>&2 && exit 1 || true
	@GOOS=linux go vet ./...
	@GOOS=linux gosec -exclude=G204,G601 ./...

.PHONY: scan
scan:
	trivy image --light --exit-code=1 --severity=HIGH --ignore-unfixed kubeovn/kube-ovn:$(RELEASE_TAG)

.PHONY: ut
ut:
	ginkgo -mod=mod -progress -reportPassed --slowSpecThreshold=60 test/unittest

.PHONY: e2e
e2e:
	docker pull kubeovn/pause:3.2
	kind load docker-image --name kube-ovn kubeovn/pause:3.2
	ginkgo -mod=mod -progress -reportPassed --slowSpecThreshold=60 test/e2e

.PHONY: e2e-vlan
e2e-vlan:
	printf "package node\n\nvar networkJSON = []byte(\`" > test/e2e-vlan/node/network.go
	docker inspect -f '{{json .NetworkSettings.Networks.kind}}' kube-ovn-control-plane >> test/e2e-vlan/node/network.go
	echo "\`)" >> test/e2e-vlan/node/network.go
	ginkgo -mod=mod -progress -reportPassed --slowSpecThreshold=60 test/e2e-vlan
