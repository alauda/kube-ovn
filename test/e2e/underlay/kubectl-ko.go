package underlay

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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

var _ = Describe("[kubectl-ko]", func() {
	f := framework.NewFramework("kubectl-ko", fmt.Sprintf("%s/.kube/config", os.Getenv("HOME")))

	var cidr, gateway string
	var nodeIPs []string
	for _, network := range nodeNetworks {
		var info nodeNetwork
		Expect(json.Unmarshal([]byte(network), &info)).NotTo(HaveOccurred())

		if info.IPAddress != "" {
			nodeIPs = append(nodeIPs, info.IPAddress)
			if cidr == "" {
				cidr = fmt.Sprintf("%s/%d", info.IPAddress, info.IPPrefixLen)
			}
		}
		if gateway == "" && info.Gateway != "" {
			gateway = info.Gateway
		}
	}
	Expect(cidr).NotTo(BeEmpty())
	Expect(gateway).NotTo(BeEmpty())
	Expect(nodeIPs).NotTo(BeEmpty())

	namespace := "default"
	BeforeEach(func() {
		if err := f.KubeClientSet.CoreV1().Pods(namespace).Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete pod %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().Subnets().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete subnet %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().Vlans().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete vlan %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete provider network %s: %v", f.GetName(), err)
			}
		}
		time.Sleep(3 * time.Second)
	})

	AfterEach(func() {
		if err := f.KubeClientSet.CoreV1().Pods(namespace).Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete pod %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().Subnets().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete subnet %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().Vlans().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete vlan %s: %v", f.GetName(), err)
			}
		}
		if err := f.OvnClientSet.KubeovnV1().ProviderNetworks().Delete(context.Background(), f.GetName(), metav1.DeleteOptions{}); err != nil {
			if !k8serrors.IsNotFound(err) {
				klog.Fatalf("failed to delete provider network %s, %v", f.GetName(), err)
			}
		}
		time.Sleep(3 * time.Second)
	})

	It("trace", func() {
		name := f.GetName()

		By("get cni pod")
		nodes, err := f.KubeClientSet.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
		Expect(err).NotTo(HaveOccurred())
		Expect(nodes.Items).NotTo(BeEmpty())

		cniPods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=kube-ovn-cni"})
		Expect(err).NotTo(HaveOccurred())
		Expect(cniPods).NotTo(BeNil())
		Expect(len(cniPods.Items)).To(Equal(len(nodes.Items)))

		var nodeIP string
		for _, addr := range nodes.Items[0].Status.Addresses {
			if addr.Type == corev1.NodeInternalIP {
				nodeIP = addr.Address
				break
			}
		}
		Expect(nodeIP).NotTo(BeEmpty())

		var cniPod *corev1.Pod
		for _, pod := range cniPods.Items {
			if pod.Status.HostIP == nodeIP {
				cniPod = &pod
				break
			}
		}
		Expect(cniPod).NotTo(BeNil())

		By("change nic mtu")
		mtu := 1499
		_, _, err = f.ExecToPodThroughAPI(fmt.Sprintf("ip link set %s mtu %d", providerInterface, mtu), "cni-server", cniPod.Name, cniPod.Namespace, nil)
		Expect(err).NotTo(HaveOccurred())

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

		By("create vlan")
		vlan := kubeovn.Vlan{
			ObjectMeta: metav1.ObjectMeta{
				Name:   name,
				Labels: map[string]string{"e2e": "true"},
			},
			Spec: kubeovn.VlanSpec{
				ID:       0,
				Provider: pn.Name,
			},
		}
		_, err = f.OvnClientSet.KubeovnV1().Vlans().Create(context.Background(), &vlan, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())

		By("create subnet")
		subnet := kubeovn.Subnet{
			ObjectMeta: metav1.ObjectMeta{
				Name:   name,
				Labels: map[string]string{"e2e": "true"},
			},
			Spec: kubeovn.SubnetSpec{
				CIDRBlock:       cidr,
				Gateway:         gateway,
				ExcludeIps:      append(nodeIPs, gateway),
				Vlan:            vlan.Name,
				UnderlayGateway: true,
			},
		}
		_, err = f.OvnClientSet.KubeovnV1().Subnets().Create(context.Background(), &subnet, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())
		err = f.WaitSubnetReady(subnet.Name)
		Expect(err).NotTo(HaveOccurred())

		By("create pod")
		var autoMount bool
		pod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:        name,
				Namespace:   namespace,
				Labels:      map[string]string{"e2e": "true"},
				Annotations: map[string]string{util.LogicalSwitchAnnotation: subnet.Name},
			},
			Spec: corev1.PodSpec{
				NodeName: nodes.Items[0].Name,
				Containers: []corev1.Container{
					{
						Name:            name,
						Image:           testImage,
						ImagePullPolicy: corev1.PullIfNotPresent,
					},
				},
				AutomountServiceAccountToken: &autoMount,
			},
		}
		_, err = f.KubeClientSet.CoreV1().Pods(namespace).Create(context.Background(), pod, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())
		pod, err = f.WaitPodReady(pod.Name, namespace)
		Expect(err).NotTo(HaveOccurred())

		output, err := exec.Command("kubectl", "ko", "trace", fmt.Sprintf("%s/%s", namespace, pod.Name), "114.114.114.114", "icmp").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))

		output, err = exec.Command("kubectl", "ko", "trace", fmt.Sprintf("%s/%s", namespace, pod.Name), "114.114.114.114", "tcp", "80").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))

		output, err = exec.Command("kubectl", "ko", "trace", fmt.Sprintf("%s/%s", namespace, pod.Name), "114.114.114.114", "udp", "53").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))
	})
})
