package speaker

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"

	kubeovnv1 "github.com/kubeovn/kube-ovn/pkg/apis/kubeovn/v1"

	"github.com/golang/protobuf/ptypes"
	"github.com/golang/protobuf/ptypes/any"
	anypb "github.com/golang/protobuf/ptypes/any"
	bgpapiutil "github.com/kubeovn/kube-ovn/pkg/speaker/bgpapiutil"
	"github.com/kubeovn/kube-ovn/pkg/util"
	bgpapi "github.com/osrg/gobgp/api"
	"github.com/osrg/gobgp/pkg/packet/bgp"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/klog"
)

func isPodAlive(p *v1.Pod) bool {
	if p.Status.Phase == v1.PodSucceeded && p.Spec.RestartPolicy != v1.RestartPolicyAlways {
		return false
	}

	if p.Status.Phase == v1.PodFailed && p.Spec.RestartPolicy == v1.RestartPolicyNever {
		return false
	}

	if p.Status.Phase == v1.PodFailed && p.Status.Reason == "Evicted" {
		return false
	}
	return true
}

func isClusterIP(svc *v1.Service) bool {
	return svc.Spec.Type == "ClusterIP"
}

func (c *Controller) AnnounceClusterIP() error {
	if c.config.AnnounceClusterIP {
		services, err := c.servicesLister.List(labels.Everything())
		if err != nil {
			klog.Errorf("failed to list services, %v", err)
			return err
		}
		for _, svc := range services {

			if isClusterIP(svc) && svc.Annotations[util.BgpAnnotation] == "true" && svc.Spec.ClusterIP != "None" &&
				svc.Spec.ClusterIP != "" {
				c.bgpIPv4Expected = append(c.bgpIPv4Expected, fmt.Sprintf("%s/32", svc.Spec.ClusterIP))
			}

		}
	}
	return nil
}

func (c *Controller) AnnounceSubnets() error {
	subnets, err := c.subnetsLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list subnets, %v", err)
		return err
	}

	for _, subnet := range subnets {
		if subnet.Status.IsReady() && subnet.Annotations != nil && subnet.Annotations[util.BgpAnnotation] == "true" {
			if util.CheckProtocol(subnet.Spec.CIDRBlock) == kubeovnv1.ProtocolDual {
				ips := strings.Split(subnet.Spec.CIDRBlock, ",")
				c.bgpIPv4Expected = append(c.bgpIPv4Expected, ips[0])
				c.bgpIPv6Expected = append(c.bgpIPv6Expected, ips[1])
			}
			if util.CheckProtocol(subnet.Spec.CIDRBlock) == kubeovnv1.ProtocolIPv4 {
				c.bgpIPv4Expected = append(c.bgpIPv4Expected, subnet.Spec.CIDRBlock)
			}
			if util.CheckProtocol(subnet.Spec.CIDRBlock) == kubeovnv1.ProtocolIPv6 {
				c.bgpIPv6Expected = append(c.bgpIPv6Expected, subnet.Spec.CIDRBlock)
			}
		}
	}

	return nil
}

func (c *Controller) AnnouncePodIP() error {
	pods, err := c.podsLister.List(labels.Everything())
	if err != nil {
		klog.Errorf("failed to list pods, %v", err)
		return err
	}
	for _, pod := range pods {
		if isPodAlive(pod) && !pod.Spec.HostNetwork && pod.Annotations[util.BgpAnnotation] == "true" && pod.Status.PodIP != "" {
			for _, ip := range pod.Status.PodIPs {
				if util.CheckProtocol(ip.IP) == kubeovnv1.ProtocolIPv4 {
					c.bgpIPv4Expected = append(c.bgpIPv4Expected, fmt.Sprintf("%s/32", ip.IP))
				}
				if util.CheckProtocol(ip.IP) == kubeovnv1.ProtocolIPv6 {
					//ProtocolIPv6
					c.bgpIPv6Expected = append(c.bgpIPv6Expected, fmt.Sprintf("%s/64", ip.IP))
				}
			}
		}
	}

	return nil
}

func (c *Controller) getBgpIPv4Exists() error {
	listIPv4PathRequest := &bgpapi.ListPathRequest{
		TableType: bgpapi.TableType_GLOBAL,
		Family:    &bgpapi.Family{Afi: bgpapi.Family_AFI_IP, Safi: bgpapi.Family_SAFI_UNICAST},
	}

	fnIPv4 := func(d *bgpapi.Destination) {
		for _, path := range d.Paths {
			attrInterfaces, _ := bgpapiutil.UnmarshalPathAttributes(path.Pattrs)
			nextHop := getNextHopFromPathAttributes(attrInterfaces)
			klog.V(5).Infof("nexthop is %s, routerID is %s", nextHop.String(), c.config.RouterId)
			if nextHop.String() == c.config.RouterId {
				c.bgpIPv4Exists = append(c.bgpIPv4Exists, d.Prefix)
				return
			}
		}
	}
	if err := c.config.BgpServer.ListPath(context.Background(), listIPv4PathRequest, fnIPv4); err != nil {
		klog.Errorf("failed to list exist route, %v", err)
		return err
	}
	return nil
}

func (c *Controller) getBgpIPv6Exists() error {
	listIPv6PathRequest := &bgpapi.ListPathRequest{
		TableType: bgpapi.TableType_GLOBAL,
		Family:    &bgpapi.Family{Afi: bgpapi.Family_AFI_IP6, Safi: bgpapi.Family_SAFI_UNICAST},
	}

	fnIPv6 := func(d *bgpapi.Destination) {
		for _, path := range d.Paths {
			attrInterfaces, _ := bgpapiutil.UnmarshalPathAttributes(path.Pattrs)
			nextHop := getNextHopFromPathAttributes(attrInterfaces)
			klog.V(5).Infof("nexthop is %s, routerID is %s", nextHop.String(), c.config.RouterId)
			if nextHop.String() == c.config.RouterId {
				c.bgpIPv6Exists = append(c.bgpIPv6Exists, d.Prefix)
				return
			}
		}
	}

	if err := c.config.BgpServer.ListPath(context.Background(), listIPv6PathRequest, fnIPv6); err != nil {
		klog.Errorf("failed to list exist route, %v", err)
		return err
	}
	return nil
}

func (c *Controller) syncSubnetRoutes() {

	if err := c.AnnounceClusterIP(); err != nil {
		return
	}

	if err := c.AnnounceSubnets(); err != nil {
		return
	}

	if err := c.AnnouncePodIP(); err != nil {
		return
	}
	klog.V(5).Infof("expected routes IPv4 %v, IPv6 %v", c.bgpIPv4Expected, c.bgpIPv6Expected)

	if err := c.getBgpIPv4Exists(); err != nil {
		return
	}
	if err := c.getBgpIPv6Exists(); err != nil {
		return
	}

	klog.V(5).Infof("exists routes IPv4 %v, IPv6 %v", c.bgpIPv4Exists, c.bgpIPv6Expected)

	toAdd, toDel := routeDiff(c.bgpIPv4Expected, c.bgpIPv4Exists)
	toAddIPv6, toDelIPv6 := routeDiff(c.bgpIPv6Expected, c.bgpIPv6Exists)
	klog.V(5).Infof("toAdd routes IPv4 %v,IPv6 %v", toAdd, toAddIPv6)
	klog.V(5).Infof("toDel routes IPv4 %v,IPv6 %v", toDel, toDelIPv6)

	for _, route := range toAdd {
		if err := c.addRoute(route, bgpapi.Family_AFI_IP); err != nil {
			klog.Error(err)
		}
	}
	for _, route := range toDel {
		if err := c.delRoute(route, bgpapi.Family_AFI_IP); err != nil {
			klog.Error(err)
		}
	}

	for _, route := range toAddIPv6 {
		if err := c.addRoute(route, bgpapi.Family_AFI_IP6); err != nil {
			klog.Error(err)
		}
	}
	for _, route := range toDelIPv6 {
		if err := c.delRoute(route, bgpapi.Family_AFI_IP6); err != nil {
			klog.Error(err)
		}
	}

}

func routeDiff(expected, exists []string) (toAdd []string, toDel []string) {

	expectedMap, existsMap := map[string]bool{}, map[string]bool{}
	for _, e := range expected {
		expectedMap[e] = true
	}
	for _, e := range exists {
		existsMap[e] = true
	}

	for e := range expectedMap {
		if !existsMap[e] {
			toAdd = append(toAdd, e)
		}
	}

	for e := range existsMap {
		if !expectedMap[e] {
			toDel = append(toDel, e)
		}
	}
	return toAdd, toDel
}

func parseIpv6Route(route string) (string, uint32, error) {
	var prefixLen uint32 = 64
	prefix := route
	if strings.Contains(route, "/") {
		prefix = strings.Split(route, "/")[0]
		strLen := strings.Split(route, "/")[1]
		intLen, err := strconv.Atoi(strLen)
		if err != nil {
			return "", 0, err
		}
		prefixLen = uint32(intLen)
	}
	return prefix, prefixLen, nil
}

func parseRoute(route string) (string, uint32, error) {
	var prefixLen uint32 = 32
	prefix := route
	if strings.Contains(route, "/") {
		prefix = strings.Split(route, "/")[0]
		strLen := strings.Split(route, "/")[1]
		intLen, err := strconv.Atoi(strLen)
		if err != nil {
			return "", 0, err
		}
		prefixLen = uint32(intLen)
	}
	return prefix, prefixLen, nil
}

func (c *Controller) addRoute(route string, afi bgpapi.Family_Afi) error {
	if afi == bgpapi.Family_AFI_IP {
		nlri, attrs, err := c.getNlriAndAttrs(route)
		if err != nil {
			return err
		}
		_, err = c.config.BgpServer.AddPath(context.Background(), &bgpapi.AddPathRequest{
			Path: &bgpapi.Path{
				Family: &bgpapi.Family{Afi: afi, Safi: bgpapi.Family_SAFI_UNICAST},
				Nlri:   nlri,
				Pattrs: attrs,
			},
		})
		if err != nil {
			klog.Errorf("add ipv4 path failed, %v", err)
			return err
		}
		return nil
	}
	nlri, attrs, v6Family, err := c.getIPv6NlriAndAttrs(route)
	if err != nil {
		return err
	}
	_, err = c.config.BgpServer.AddPath(context.Background(), &bgpapi.AddPathRequest{
		Path: &bgpapi.Path{
			Family: v6Family,
			Nlri:   nlri,
			Pattrs: attrs,
		},
	})
	if err != nil {
		klog.Errorf("add ipv6 path failed, %v", err)
		return err
	}

	return nil
}

func (c *Controller) getNlriAndAttrs(route string) (*anypb.Any, []*any.Any, error) {
	prefix, prefixLen, err := parseRoute(route)
	if err != nil {
		return nil, nil, err
	}
	nlri, _ := ptypes.MarshalAny(&bgpapi.IPAddressPrefix{
		Prefix:    prefix,
		PrefixLen: prefixLen,
	})
	a1, _ := ptypes.MarshalAny(&bgpapi.OriginAttribute{
		Origin: 0,
	})

	a2, _ := ptypes.MarshalAny(&bgpapi.NextHopAttribute{
		NextHop: c.config.RouterId,
	})
	attrs := []*any.Any{a1, a2}
	return nlri, attrs, err
}

func (c *Controller) getIPv6NlriAndAttrs(route string) (*anypb.Any, []*any.Any, *bgpapi.Family, error) {
	v6Family := &bgpapi.Family{
		Afi:  bgpapi.Family_AFI_IP6,
		Safi: bgpapi.Family_SAFI_UNICAST,
	}
	prefix, prefixLen, err := parseIpv6Route(route)
	if err != nil {
		return nil, nil, nil, err
	}
	nlri, _ := ptypes.MarshalAny(&bgpapi.IPAddressPrefix{
		PrefixLen: prefixLen,
		Prefix:    prefix,
	})
	a1, _ := ptypes.MarshalAny(&bgpapi.OriginAttribute{
		Origin: 0,
	})
	v6Attrs, _ := ptypes.MarshalAny(&bgpapi.MpReachNLRIAttribute{
		Family:   v6Family,
		NextHops: []string{c.config.RouterId},
		Nlris:    []*any.Any{nlri},
	})
	attrs := []*any.Any{a1, v6Attrs}
	return nlri, attrs, v6Family, nil
}

func (c *Controller) delRoute(route string, afi bgpapi.Family_Afi) error {
	if afi == bgpapi.Family_AFI_IP {
		nlri, attrs, err := c.getNlriAndAttrs(route)
		if err != nil {
			return err
		}
		err = c.config.BgpServer.DeletePath(context.Background(), &bgpapi.DeletePathRequest{
			Path: &bgpapi.Path{
				Family: &bgpapi.Family{Afi: afi, Safi: bgpapi.Family_SAFI_UNICAST},
				Nlri:   nlri,
				Pattrs: attrs,
			},
		})
		if err != nil {
			klog.Errorf("del path failed, %v", err)
			return err
		}
		return nil
	}
	nlri, attrs, v6Family, err := c.getIPv6NlriAndAttrs(route)
	if err != nil {
		return err
	}
	err = c.config.BgpServer.DeletePath(context.Background(), &bgpapi.DeletePathRequest{
		Path: &bgpapi.Path{
			Family: v6Family,
			Nlri:   nlri,
			Pattrs: attrs,
		},
	})

	if err != nil {
		klog.Errorf("add ipv6 path failed, %v", err)
		return err
	}

	return nil
}

func getNextHopFromPathAttributes(attrs []bgp.PathAttributeInterface) net.IP {
	for _, attr := range attrs {
		switch a := attr.(type) {
		case *bgp.PathAttributeNextHop:
			return a.Value
		case *bgp.PathAttributeMpReachNLRI:
			return a.Nexthop
		}
	}
	return nil
}
