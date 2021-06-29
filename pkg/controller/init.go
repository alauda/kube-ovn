package controller

import (
	"context"
	"fmt"
	"strings"

	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog"

	kubeovnv1 "github.com/kubeovn/kube-ovn/pkg/apis/kubeovn/v1"
	"github.com/kubeovn/kube-ovn/pkg/util"
)

func (c *Controller) InitOVN() error {
	if err := c.initClusterRouter(); err != nil {
		klog.Errorf("init cluster router failed %v", err)
		return err
	}

	if c.config.EnableLb {
		if err := c.initLoadBalancer(); err != nil {
			klog.Errorf("init load balancer failed %v", err)
			return err
		}
	}

	if err := c.initDefaultVlan(); err != nil {
		klog.Errorf("init default vlan failed %v", err)
		return err
	}

	if err := c.initExtraVlans(); err != nil {
		klog.Errorf("init extra vlans failed %v", err)
		return err
	}

	if err := c.initNodeSwitch(); err != nil {
		klog.Errorf("init node switch failed %v", err)
		return err
	}

	if err := c.initDefaultLogicalSwitch(); err != nil {
		klog.Errorf("init default switch failed %v", err)
		return err
	}

	return nil
}

func (c *Controller) InitDefaultVpc() error {
	vpc, err := c.vpcsLister.Get(util.DefaultVpc)
	if err != nil {
		vpc = &kubeovnv1.Vpc{}
		vpc.Name = util.DefaultVpc
		vpc, err = c.config.KubeOvnClient.KubeovnV1().Vpcs().Create(context.Background(), vpc, metav1.CreateOptions{})
		if err != nil {
			klog.Errorf("init default vpc failed %v", err)
			return err
		}
	}

	vpc.Status.DefaultLogicalSwitch = c.config.DefaultLogicalSwitch
	vpc.Status.Router = c.config.ClusterRouter
	if c.config.EnableLb {
		vpc.Status.TcpLoadBalancer = c.config.ClusterTcpLoadBalancer
		vpc.Status.TcpSessionLoadBalancer = c.config.ClusterTcpSessionLoadBalancer
		vpc.Status.UdpLoadBalancer = c.config.ClusterUdpLoadBalancer
		vpc.Status.UdpSessionLoadBalancer = c.config.ClusterUdpSessionLoadBalancer
	}
	vpc.Status.Standby = true
	vpc.Status.Default = true

	bytes, err := vpc.Status.Bytes()
	if err != nil {
		return err
	}
	_, err = c.config.KubeOvnClient.KubeovnV1().Vpcs().Patch(context.Background(), vpc.Name, types.MergePatchType, bytes, metav1.PatchOptions{}, "status")
	if err != nil {
		klog.Errorf("init default vpc failed %v", err)
		return err
	}
	return nil
}

// InitDefaultLogicalSwitch init the default logical switch for ovn network
func (c *Controller) initDefaultLogicalSwitch() error {
	subnet, err := c.config.KubeOvnClient.KubeovnV1().Subnets().Get(context.Background(), c.config.DefaultLogicalSwitch, metav1.GetOptions{})
	if err == nil {
		if subnet != nil && util.CheckProtocol(c.config.DefaultCIDR) != util.CheckProtocol(subnet.Spec.CIDRBlock) {
			// single-stack upgrade to dual-stack
			if util.CheckProtocol(c.config.DefaultCIDR) == kubeovnv1.ProtocolDual {
				subnet.Spec.CIDRBlock = c.config.DefaultCIDR
				if err := formatSubnet(subnet, c); err != nil {
					klog.Errorf("init format subnet %s failed %v", c.config.DefaultLogicalSwitch, err)
					return err
				}
			}
		}
		return nil
	}

	if !k8serrors.IsNotFound(err) {
		klog.Errorf("get default subnet %s failed %v", c.config.DefaultLogicalSwitch, err)
		return err
	}

	defaultSubnet := kubeovnv1.Subnet{
		ObjectMeta: metav1.ObjectMeta{Name: c.config.DefaultLogicalSwitch},
		Spec: kubeovnv1.SubnetSpec{
			Vpc:         util.DefaultVpc,
			Default:     true,
			Provider:    util.OvnProvider,
			CIDRBlock:   c.config.DefaultCIDR,
			Gateway:     c.config.DefaultGateway,
			ExcludeIps:  strings.Split(c.config.DefaultExcludeIps, ","),
			NatOutgoing: true,
			GatewayType: kubeovnv1.GWDistributedType,
			Protocol:    util.CheckProtocol(c.config.DefaultCIDR),
		},
	}
	if c.config.NetworkType == util.NetworkTypeVlan {
		defaultSubnet.Spec.Vlan = c.config.DefaultVlanName
		defaultSubnet.Spec.UnderlayGateway = true
	}

	_, err = c.config.KubeOvnClient.KubeovnV1().Subnets().Create(context.Background(), &defaultSubnet, metav1.CreateOptions{})
	return err
}

// InitNodeSwitch init node switch to connect host and pod
func (c *Controller) initNodeSwitch() error {
	subnet, err := c.config.KubeOvnClient.KubeovnV1().Subnets().Get(context.Background(), c.config.NodeSwitch, metav1.GetOptions{})
	if err == nil {
		if subnet != nil && util.CheckProtocol(c.config.NodeSwitchCIDR) != util.CheckProtocol(subnet.Spec.CIDRBlock) {
			// single-stack upgrade to dual-stack
			if util.CheckProtocol(c.config.NodeSwitchCIDR) == kubeovnv1.ProtocolDual {
				subnet.Spec.CIDRBlock = c.config.NodeSwitchCIDR
				if err := formatSubnet(subnet, c); err != nil {
					klog.Errorf("init format subnet %s failed %v", c.config.NodeSwitch, err)
					return err
				}
			}
		}
		return nil
	}

	if !k8serrors.IsNotFound(err) {
		klog.Errorf("get node subnet %s failed %v", c.config.NodeSwitch, err)
		return err
	}

	nodeSubnet := kubeovnv1.Subnet{
		ObjectMeta: metav1.ObjectMeta{Name: c.config.NodeSwitch},
		Spec: kubeovnv1.SubnetSpec{
			Vpc:                    util.DefaultVpc,
			Default:                false,
			Provider:               util.OvnProvider,
			CIDRBlock:              c.config.NodeSwitchCIDR,
			Gateway:                c.config.NodeSwitchGateway,
			ExcludeIps:             strings.Split(c.config.NodeSwitchGateway, ","),
			Protocol:               util.CheckProtocol(c.config.NodeSwitchCIDR),
			DisableInterConnection: true,
		},
	}

	_, err = c.config.KubeOvnClient.KubeovnV1().Subnets().Create(context.Background(), &nodeSubnet, metav1.CreateOptions{})
	return err
}

// InitClusterRouter init cluster router to connect different logical switches
func (c *Controller) initClusterRouter() error {
	lrs, err := c.ovnClient.ListLogicalRouter()
	if err != nil {
		return err
	}
	klog.Infof("exists routers %v", lrs)
	for _, r := range lrs {
		if c.config.ClusterRouter == r {
			return nil
		}
	}
	return c.ovnClient.CreateLogicalRouter(c.config.ClusterRouter)
}

// InitLoadBalancer init the default tcp and udp cluster loadbalancer
func (c *Controller) initLoadBalancer() error {
	vpcs, err := c.vpcsLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list vpc, %v", err)
		return err
	}

	for _, vpc := range vpcs {
		vpcLb := c.GenVpcLoadBalancer(vpc.Name)

		tcpLb, err := c.ovnClient.FindLoadbalancer(vpcLb.TcpLoadBalancer)
		if err != nil {
			return fmt.Errorf("failed to find tcp lb %v", err)
		}
		if tcpLb == "" {
			klog.Infof("init cluster tcp load balancer %s", vpcLb.TcpLoadBalancer)
			err := c.ovnClient.CreateLoadBalancer(vpcLb.TcpLoadBalancer, util.ProtocolTCP, "")
			if err != nil {
				klog.Errorf("failed to crate cluster tcp load balancer %v", err)
				return err
			}
		} else {
			klog.Infof("tcp load balancer %s exists", tcpLb)
		}

		tcpSessionLb, err := c.ovnClient.FindLoadbalancer(vpcLb.TcpSessLoadBalancer)
		if err != nil {
			return fmt.Errorf("failed to find tcp session lb %v", err)
		}
		if tcpSessionLb == "" {
			klog.Infof("init cluster tcp session load balancer %s", vpcLb.TcpSessLoadBalancer)
			err := c.ovnClient.CreateLoadBalancer(vpcLb.TcpSessLoadBalancer, util.ProtocolTCP, "ip_src")
			if err != nil {
				klog.Errorf("failed to crate cluster tcp session load balancer %v", err)
				return err
			}
		} else {
			klog.Infof("tcp session load balancer %s exists", vpcLb.TcpSessLoadBalancer)
		}

		udpLb, err := c.ovnClient.FindLoadbalancer(vpcLb.UdpLoadBalancer)
		if err != nil {
			return fmt.Errorf("failed to find udp lb %v", err)
		}
		if udpLb == "" {
			klog.Infof("init cluster udp load balancer %s", vpcLb.UdpLoadBalancer)
			err := c.ovnClient.CreateLoadBalancer(vpcLb.UdpLoadBalancer, util.ProtocolUDP, "")
			if err != nil {
				klog.Errorf("failed to crate cluster udp load balancer %v", err)
				return err
			}
		} else {
			klog.Infof("udp load balancer %s exists", udpLb)
		}

		udpSessionLb, err := c.ovnClient.FindLoadbalancer(vpcLb.UdpSessLoadBalancer)
		if err != nil {
			return fmt.Errorf("failed to find udp session lb %v", err)
		}
		if udpSessionLb == "" {
			klog.Infof("init cluster udp session load balancer %s", vpcLb.UdpSessLoadBalancer)
			err := c.ovnClient.CreateLoadBalancer(vpcLb.UdpSessLoadBalancer, util.ProtocolUDP, "ip_src")
			if err != nil {
				klog.Errorf("failed to crate cluster udp session load balancer %v", err)
				return err
			}
		} else {
			klog.Infof("udp session load balancer %s exists", vpcLb.UdpSessLoadBalancer)
		}

		vpc.Status.TcpLoadBalancer = vpcLb.TcpLoadBalancer
		vpc.Status.TcpSessionLoadBalancer = vpcLb.TcpSessLoadBalancer
		vpc.Status.UdpLoadBalancer = vpcLb.UdpLoadBalancer
		vpc.Status.UdpSessionLoadBalancer = vpcLb.UdpSessLoadBalancer
		bytes, err := vpc.Status.Bytes()
		if err != nil {
			return err
		}
		_, err = c.config.KubeOvnClient.KubeovnV1().Vpcs().Patch(context.Background(), vpc.Name, types.MergePatchType, bytes, metav1.PatchOptions{}, "status")
		if err != nil {
			return err
		}
	}
	return nil
}

func (c *Controller) InitIPAM() error {
	subnets, err := c.subnetsLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list subnet, %v", err)
		return err
	}
	for _, subnet := range subnets {
		if err := c.ipam.AddOrUpdateSubnet(subnet.Name, subnet.Spec.CIDRBlock, subnet.Spec.ExcludeIps); err != nil {
			klog.Errorf("failed to init subnet %s, %v", subnet.Name, err)
		}
	}

	pods, err := c.podsLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list pods, %v", err)
		return err
	}
	for _, pod := range pods {
		if isPodAlive(pod) &&
			pod.Annotations[util.AllocatedAnnotation] == "true" &&
			pod.Annotations[util.LogicalSwitchAnnotation] != "" {
			_, _, _, err := c.ipam.GetStaticAddress(
				fmt.Sprintf("%s/%s", pod.Namespace, pod.Name),
				pod.Annotations[util.IpAddressAnnotation],
				pod.Annotations[util.MacAddressAnnotation],
				pod.Annotations[util.LogicalSwitchAnnotation])
			if err != nil {
				klog.Errorf("failed to init pod %s.%s address %s, %v", pod.Name, pod.Namespace, pod.Annotations[util.IpAddressAnnotation], err)
			}
		}
	}

	nodes, err := c.nodesLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list nodes, %v", err)
		return err
	}
	for _, node := range nodes {
		if node.Annotations[util.AllocatedAnnotation] == "true" {
			portName := fmt.Sprintf("node-%s", node.Name)
			v4IP, v6IP, _, err := c.ipam.GetStaticAddress(portName, node.Annotations[util.IpAddressAnnotation],
				node.Annotations[util.MacAddressAnnotation],
				node.Annotations[util.LogicalSwitchAnnotation])
			if err != nil {
				klog.Errorf("failed to init node %s.%s address %s, %v", node.Name, node.Namespace, node.Annotations[util.IpAddressAnnotation], err)
			}
			if v4IP != "" && v6IP != "" {
				node.Annotations[util.IpAddressAnnotation] = util.GetStringIP(v4IP, v6IP)
			}
		}
	}

	return nil
}

func (c *Controller) initVlan(name, provider, hostInterface string, id int) error {
	_, err := c.config.KubeOvnClient.KubeovnV1().Vlans().Get(context.Background(), name, metav1.GetOptions{})
	if err == nil {
		return nil
	}

	if !k8serrors.IsNotFound(err) {
		klog.Errorf("failed to get vlan %s: %v", name, err)
		return err
	}

	defaultVlan := kubeovnv1.Vlan{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: kubeovnv1.VlanSpec{
			VlanId:        id,
			Provider:      provider,
			HostInterface: hostInterface,
		},
	}

	_, err = c.config.KubeOvnClient.KubeovnV1().Vlans().Create(context.Background(), &defaultVlan, metav1.CreateOptions{})
	return err
}

//InitDefaultVlan init the default vlan when network type is vlan or vxlan
func (c *Controller) initDefaultVlan() error {
	if !util.IsNetworkVlan(c.config.NetworkType) {
		return nil
	}

	return c.initVlan(c.config.DefaultVlanName, c.config.DefaultProviderName, c.config.DefaultHostInterface, c.config.DefaultVlanID)
}

// initialize the extra vlans when network type is vlan
func (c *Controller) initExtraVlans() error {
	if !util.IsNetworkVlan(c.config.NetworkType) {
		return nil
	}

	for i, provider := range c.config.ExtraProviderNames {
		if err := c.initVlan(c.config.ExtraVlanNames[i], provider, c.config.ExtraHostInterfaces[i], c.config.ExtraVlanIDs[i]); err != nil {
			return err
		}
	}

	return nil
}

func (c *Controller) initSyncCrdIPs() error {
	klog.Info("start to sync ips")
	ips, err := c.config.KubeOvnClient.KubeovnV1().IPs().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		if k8serrors.IsNotFound(err) {
			return nil
		}
		return err
	}

	for _, ipCr := range ips.Items {
		ip := ipCr
		v4IP, v6IP := util.SplitStringIP(ip.Spec.IPAddress)
		if ip.Spec.V4IPAddress == v4IP && ip.Spec.V6IPAddress == v6IP {
			continue
		}
		ip.Spec.V4IPAddress = v4IP
		ip.Spec.V6IPAddress = v6IP

		_, err := c.config.KubeOvnClient.KubeovnV1().IPs().Update(context.Background(), &ip, metav1.UpdateOptions{})
		if err != nil {
			klog.Errorf("failed to sync crd ip %s, %v", ip.Spec.IPAddress, err)
			return err
		}
	}
	return nil
}

func (c *Controller) initSyncCrdSubnets() error {
	klog.Info("start to sync subnets")
	subnets, err := c.subnetsLister.List(labels.Everything())
	if err != nil {
		if k8serrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	for _, subnet := range subnets {
		if util.CheckProtocol(subnet.Spec.CIDRBlock) == kubeovnv1.ProtocolDual {
			err = calcDualSubnetStatusIP(subnet, c)
		} else {
			err = calcSubnetStatusIP(subnet, c)
		}
		if err != nil {
			klog.Errorf("failed to calculate subnet %s used ip, %v", subnet.Name, err)
			return err
		}
	}
	return nil
}
