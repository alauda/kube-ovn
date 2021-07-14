package underlay

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/klog"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	kubeovn "github.com/kubeovn/kube-ovn/pkg/apis/kubeovn/v1"
	"github.com/kubeovn/kube-ovn/pkg/util"
	"github.com/kubeovn/kube-ovn/test/e2e/framework"
)

type nodeNetwork struct {
	Gateway             string
	IPAddress           string
	IPPrefixLen         int
	IPv6Gateway         string
	GlobalIPv6Address   string
	GlobalIPv6PrefixLen int
	MacAddress          string
}

var _ = Describe("[Provider Network]", func() {
	f := framework.NewFramework("provider-network", fmt.Sprintf("%s/.kube/config", os.Getenv("HOME")))

	nodeMac := make(map[string]string, len(nodeNetworks))
	nodeAddrs := make(map[string][]string, len(nodeNetworks))
	nodeRoutes := make(map[string][]string, len(nodeNetworks))
	for node, network := range nodeNetworks {
		var info nodeNetwork
		Expect(json.Unmarshal([]byte(network), &info)).NotTo(HaveOccurred())
		nodeMac[node] = info.MacAddress
		if info.IPAddress != "" {
			nodeAddrs[node] = append(nodeAddrs[node], fmt.Sprintf("%s/%d", info.IPAddress, info.IPPrefixLen))
		}
		if info.GlobalIPv6Address != "" {
			nodeAddrs[node] = append(nodeAddrs[node], fmt.Sprintf("%s/%d", info.GlobalIPv6Address, info.GlobalIPv6PrefixLen))
		}
		if info.Gateway != "" {
			nodeRoutes[node] = append(nodeRoutes[node], fmt.Sprintf("default via %s ", info.Gateway))
		}
		if info.IPv6Gateway != "" {
			nodeRoutes[node] = append(nodeRoutes[node], fmt.Sprintf("default via %s ", info.IPv6Gateway))
		}
		Expect(nodeAddrs[node]).NotTo(BeEmpty())
		Expect(nodeRoutes[node]).NotTo(BeEmpty())
	}

	BeforeEach(func() {
		if err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete provider network %s: %v", f.GetName(), err)
			}
		}
		time.Sleep(3 * time.Second)
	})
	AfterEach(func() {
		if err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete provider network %s: %v", f.GetName(), err)
			}
		}
		time.Sleep(3 * time.Second)
	})

	Describe("Create", func() {
		It("normal", func() {
			name := f.GetName()

			By("create provider network")
			pn := kubeovn.ProviderNetwork{
				ObjectMeta: metav1.ObjectMeta{
					Name:   name,
					Labels: map[string]string{"e2e": "true"},
				},
				Spec: kubeovn.ProviderNetworkSpec{
					DefaultInterface: providerInterface,
				},
			}
			_, err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Create(context.Background(), &pn, metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			err = f.WaitProviderNetworkReady(pn.Name)
			Expect(err).NotTo(HaveOccurred())

			By("validate node labels")
			nodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred())

			for _, node := range nodes.Items {
				Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkExcludeTemplate, pn.Name)]).To(BeEmpty())
				Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkInterfaceTemplate, pn.Name)]).To(Equal(providerInterface))
				Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkReadyTemplate, pn.Name)]).To(Equal("true"))
				Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkMtuTemplate, pn.Name)]).NotTo(BeEmpty())
			}

			By("validate provider interface and OVS bridge")
			ovsPods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=ovs"})
			Expect(err).NotTo(HaveOccurred())
			Expect(ovsPods).NotTo(BeNil())
			for _, node := range nodes.Items {
				var hostIP string
				for _, addr := range node.Status.Addresses {
					if addr.Type == corev1.NodeInternalIP {
						hostIP = addr.Address
						break
					}
				}
				Expect(hostIP).NotTo(BeEmpty())

				var ovsPod *corev1.Pod
				for _, pod := range ovsPods.Items {
					if pod.Status.HostIP == hostIP {
						ovsPod = &pod
						break
					}
				}
				Expect(ovsPod).NotTo(BeNil())

				stdout, _, err := f.ExecToPodThroughAPI("ip addr show "+providerInterface, "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())

				addrNotFound := make([]bool, len(nodeAddrs[node.Name]))
				for _, s := range strings.Split(stdout, "\n") {
					s = strings.TrimSpace(s)
					for i, addr := range nodeAddrs[node.Name] {
						if !strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) && !strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
							addrNotFound[i] = true
							break
						}
					}
				}
				for _, found := range addrNotFound {
					Expect(found).To(BeTrue())
				}

				stdout, _, err = f.ExecToPodThroughAPI("ovs-vsctl list-ports "+util.ExternalBridgeName(pn.Name), "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())

				var portFound bool
				for _, port := range strings.Split(stdout, "\n") {
					if port == providerInterface {
						portFound = true
						break
					}
				}
				Expect(portFound).To(BeTrue())

				stdout, _, err = f.ExecToPodThroughAPI("ip addr show "+util.ExternalBridgeName(pn.Name), "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())

				var isUp bool
				addrFound := make([]bool, len(nodeAddrs[node.Name]))
				for i, s := range strings.Split(stdout, "\n") {
					if i == 0 {
						idx1, idx2 := strings.IndexRune(s, '<'), strings.IndexRune(s, '>')
						if idx1 > 0 && idx2 > idx1+1 {
							for _, state := range strings.Split(s[idx1+1:idx2], ",") {
								if state == "UP" {
									isUp = true
									break
								}
							}
						}
						continue
					}
					if i == 1 {
						if mac := nodeMac[node.Name]; mac != "" {
							Expect(strings.TrimSpace(s)).To(HavePrefix("link/ether %s ", mac))
							continue
						}
					}

					s = strings.TrimSpace(s)
					for i, addr := range nodeAddrs[node.Name] {
						if strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) || strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
							addrFound[i] = true
							break
						}
					}
				}
				Expect(isUp).To(BeTrue())
				for _, found := range addrFound {
					Expect(found).To(BeTrue())
				}
			}
		})

		It("mtu", func() {
			ovsPods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=ovs"})
			Expect(err).NotTo(HaveOccurred())
			for i, pod := range ovsPods.Items {
				_, _, err := f.ExecToPodThroughAPI(fmt.Sprintf("ip link set %s mtu %d", providerInterface, 1600+i*10), "openvswitch", pod.Name, pod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())
			}

			name := f.GetName()
			By("create provider network")
			pn := kubeovn.ProviderNetwork{
				ObjectMeta: metav1.ObjectMeta{
					Name:   name,
					Labels: map[string]string{"e2e": "true"},
				},
				Spec: kubeovn.ProviderNetworkSpec{
					DefaultInterface: providerInterface,
				},
			}
			_, err = f.OvnClientSet.KubeovnV1().ProviderNetworks().Create(context.Background(), &pn, metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			err = f.WaitProviderNetworkReady(pn.Name)
			Expect(err).NotTo(HaveOccurred())

			By("validate node labels and OVS bridge MTU")
			nodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred())
			readyNodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{LabelSelector: fmt.Sprintf(util.ProviderNetworkReadyTemplate+"=true", pn.Name)})
			Expect(err).NotTo(HaveOccurred())
			Expect(len(nodes.Items)).To(Equal(len(readyNodes.Items)))

			for i, pod := range ovsPods.Items {
				mtu := 1600 + i*10

				var found bool
				for _, node := range readyNodes.Items {
					for _, addr := range node.Status.Addresses {
						if addr.Address == pod.Status.HostIP && addr.Type == corev1.NodeInternalIP {
							Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkMtuTemplate, pn.Name)]).To(Equal(strconv.Itoa(mtu)))
							found = true
							break
						}
					}
					if found {
						break
					}
				}
				Expect(found).To(BeTrue())

				output, _, err := f.ExecToPodThroughAPI("ip link show "+util.ExternalBridgeName(pn.Name), "openvswitch", pod.Name, pod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())
				Expect(output).To(ContainSubstring(" mtu %d ", mtu))
			}
		})

		It("exclude node", func() {
			name := f.GetName()

			By("create provider network")
			nodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred())

			excludedNode := nodes.Items[0].Name
			pn := kubeovn.ProviderNetwork{
				ObjectMeta: metav1.ObjectMeta{
					Name:   name,
					Labels: map[string]string{"e2e": "true"},
				},
				Spec: kubeovn.ProviderNetworkSpec{
					DefaultInterface: providerInterface,
					ExcludeNodes:     []string{excludedNode},
				},
			}
			_, err = f.OvnClientSet.KubeovnV1().ProviderNetworks().Create(context.Background(), &pn, metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			err = f.WaitProviderNetworkReady(pn.Name)
			Expect(err).NotTo(HaveOccurred())

			By("validate node labels")
			nodes, err = f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred())

			for _, node := range nodes.Items {
				if node.Name == excludedNode {
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkExcludeTemplate, pn.Name)]).To(Equal("true"))
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkInterfaceTemplate, pn.Name)]).To(BeEmpty())
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkReadyTemplate, pn.Name)]).To(BeEmpty())
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkMtuTemplate, pn.Name)]).To(BeEmpty())
				} else {
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkExcludeTemplate, pn.Name)]).To(BeEmpty())
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkInterfaceTemplate, pn.Name)]).To(Equal(providerInterface))
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkReadyTemplate, pn.Name)]).To(Equal("true"))
					Expect(node.Labels[fmt.Sprintf(util.ProviderNetworkMtuTemplate, pn.Name)]).NotTo(BeEmpty())
				}
			}

			By("validate provider interface and OVS bridge")
			ovsPods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=ovs"})
			Expect(err).NotTo(HaveOccurred())
			Expect(ovsPods).NotTo(BeNil())
			for _, node := range nodes.Items {

				var hostIP string
				for _, addr := range node.Status.Addresses {
					if addr.Type == corev1.NodeInternalIP {
						hostIP = addr.Address
						break
					}
				}
				Expect(hostIP).NotTo(BeEmpty())

				var ovsPod *corev1.Pod
				for _, pod := range ovsPods.Items {
					if pod.Status.HostIP == hostIP {
						ovsPod = &pod
						break
					}
				}
				Expect(ovsPod).NotTo(BeNil())

				if node.Name == excludedNode {
					stdout, _, err := f.ExecToPodThroughAPI("ovs-vsctl list-br", "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
					Expect(err).NotTo(HaveOccurred())

					var brFound bool
					for _, br := range strings.Split(stdout, "\n") {
						if br == util.ExternalBridgeName(pn.Name) {
							brFound = true
							break
						}
					}
					Expect(brFound).To(BeFalse())

					stdout, _, err = f.ExecToPodThroughAPI("ip addr show "+providerInterface, "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
					Expect(err).NotTo(HaveOccurred())

					addrFound := make([]bool, len(nodeAddrs[node.Name]))
					for _, s := range strings.Split(stdout, "\n") {
						s = strings.TrimSpace(s)
						for i, addr := range nodeAddrs[node.Name] {
							if strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) || strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
								addrFound[i] = true
								break
							}
						}
					}
					for _, found := range addrFound {
						Expect(found).To(BeTrue())
					}
				} else {
					stdout, _, err := f.ExecToPodThroughAPI("ip addr show "+providerInterface, "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
					Expect(err).NotTo(HaveOccurred())

					addrNotFound := make([]bool, len(nodeAddrs[node.Name]))
					for _, s := range strings.Split(stdout, "\n") {
						s = strings.TrimSpace(s)
						for i, addr := range nodeAddrs[node.Name] {
							if !strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) && !strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
								addrNotFound[i] = true
								break
							}
						}
					}
					for _, found := range addrNotFound {
						Expect(found).To(BeTrue())
					}

					stdout, _, err = f.ExecToPodThroughAPI("ovs-vsctl list-ports "+util.ExternalBridgeName(pn.Name), "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
					Expect(err).NotTo(HaveOccurred())

					var portFound bool
					for _, port := range strings.Split(stdout, "\n") {
						if port == providerInterface {
							portFound = true
							break
						}
					}
					Expect(portFound).To(BeTrue())

					stdout, _, err = f.ExecToPodThroughAPI("ip addr show "+util.ExternalBridgeName(pn.Name), "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
					Expect(err).NotTo(HaveOccurred())

					var isUp bool
					addrFound := make([]bool, len(nodeAddrs[node.Name]))
					for i, s := range strings.Split(stdout, "\n") {
						if i == 0 {
							idx1, idx2 := strings.IndexRune(s, '<'), strings.IndexRune(s, '>')
							if idx1 > 0 && idx2 > idx1+1 {
								for _, state := range strings.Split(s[idx1+1:idx2], ",") {
									if state == "UP" {
										isUp = true
										break
									}
								}
							}
							continue
						}
						if i == 1 {
							if mac := nodeMac[node.Name]; mac != "" {
								Expect(strings.TrimSpace(s)).To(HavePrefix("link/ether %s ", mac))
								continue
							}
						}

						s = strings.TrimSpace(s)
						for i, addr := range nodeAddrs[node.Name] {
							if strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) || strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
								addrFound[i] = true
								break
							}
						}
					}
					Expect(isUp).To(BeTrue())
					for _, found := range addrFound {
						Expect(found).To(BeTrue())
					}
				}
			}
		})
	})

	Describe("Delete", func() {
		It("normal", func() {
			name := f.GetName()

			By("create provider network")
			pn := kubeovn.ProviderNetwork{
				ObjectMeta: metav1.ObjectMeta{
					Name:   name,
					Labels: map[string]string{"e2e": "true"},
				},
				Spec: kubeovn.ProviderNetworkSpec{
					DefaultInterface: providerInterface,
				},
			}
			_, err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Create(context.Background(), &pn, metav1.CreateOptions{})
			Expect(err).NotTo(HaveOccurred())
			err = f.WaitProviderNetworkReady(pn.Name)
			Expect(err).NotTo(HaveOccurred())

			By("delete provider network")
			err = f.OvnClientSet.KubeovnV1().ProviderNetworks().Delete(context.Background(), pn.Name, metav1.DeleteOptions{})
			Expect(err).NotTo(HaveOccurred())
			time.Sleep(3 * time.Second)

			By("validate node labels")
			readyNodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{LabelSelector: fmt.Sprintf(util.ProviderNetworkReadyTemplate+"=true", pn.Name)})
			Expect(err).NotTo(HaveOccurred())
			Expect(len(readyNodes.Items)).To(Equal(0))

			By("validate provider interface and OVS bridge")
			ovsPods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=ovs"})
			Expect(err).NotTo(HaveOccurred())
			Expect(ovsPods).NotTo(BeNil())
			for _, node := range readyNodes.Items {
				var hostIP string
				for _, addr := range node.Status.Addresses {
					if addr.Type == corev1.NodeInternalIP {
						hostIP = addr.Address
						break
					}
				}
				Expect(hostIP).NotTo(BeEmpty())

				var ovsPod *corev1.Pod
				for _, pod := range ovsPods.Items {
					if pod.Status.HostIP == hostIP {
						ovsPod = &pod
						break
					}
				}
				Expect(ovsPod).NotTo(BeNil())

				stdout, _, err := f.ExecToPodThroughAPI("ovs-vsctl list-br", "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())

				var brFound bool
				for _, br := range strings.Split(stdout, "\n") {
					if br == util.ExternalBridgeName(pn.Name) {
						brFound = true
						break
					}
				}
				Expect(brFound).To(BeFalse())

				stdout, _, err = f.ExecToPodThroughAPI("ip addr show "+providerInterface, "openvswitch", ovsPod.Name, ovsPod.Namespace, nil)
				Expect(err).NotTo(HaveOccurred())

				addrFound := make([]bool, len(nodeAddrs[node.Name]))
				for _, s := range strings.Split(stdout, "\n") {
					s = strings.TrimSpace(s)
					for i, addr := range nodeAddrs[node.Name] {
						if strings.HasPrefix(s, fmt.Sprintf("inet %s ", addr)) || strings.HasPrefix(s, fmt.Sprintf("inet6 %s ", addr)) {
							addrFound[i] = true
							break
						}
					}
				}
				for _, found := range addrFound {
					Expect(found).To(BeTrue())
				}
			}
		})
	})
})
