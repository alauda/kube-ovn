package kubectl_ko

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	"github.com/kubeovn/kube-ovn/test/e2e/framework"
)

var _ = Describe("[kubectl-ko]", func() {
	f := framework.NewFramework("kubectl-ko", fmt.Sprintf("%s/.kube/config", os.Getenv("HOME")))

	It("trace", func() {
		pods, err := f.KubeClientSet.CoreV1().Pods("kube-system").List(context.Background(), metav1.ListOptions{LabelSelector: "app=kube-ovn-pinger"})
		Expect(err).NotTo(HaveOccurred())
		pod := pods.Items[0]

		output, err := exec.Command("kubectl", "ko", "trace", fmt.Sprintf("kube-system/%s", pod.Name), "114.114.114.114", "icmp").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))

		output, err = exec.Command("kubectl", "ko", "trace", fmt.Sprintf("kube-system/%s", pod.Name), "114.114.114.114", "tcp", "80").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))

		output, err = exec.Command("kubectl", "ko", "trace", fmt.Sprintf("kube-system/%s", pod.Name), "114.114.114.114", "udp", "53").CombinedOutput()
		Expect(err).NotTo(HaveOccurred(), string(output))
	})
})
