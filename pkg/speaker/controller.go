package speaker

import (
	"time"

	kubeovnv1 "github.com/kubeovn/kube-ovn/pkg/apis/kubeovn/v1"
	kubeovninformer "github.com/kubeovn/kube-ovn/pkg/client/informers/externalversions"
	kubeovnlister "github.com/kubeovn/kube-ovn/pkg/client/listers/kubeovn/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apimachinery/pkg/util/wait"
	kubeinformers "k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes/scheme"
	typedcorev1 "k8s.io/client-go/kubernetes/typed/core/v1"

	listerv1 "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/record"
	"k8s.io/klog"
)

const controllerAgentName = "ovn-speaker"

type Controller struct {
	config *Configuration

	podsLister     listerv1.PodLister
	podsSynced     cache.InformerSynced
	subnetsLister  kubeovnlister.SubnetLister
	subnetSynced   cache.InformerSynced
	servicesLister listerv1.ServiceLister
	servicesSynced cache.InformerSynced

	informerFactory                                                kubeinformers.SharedInformerFactory
	kubeovnInformerFactory                                         kubeovninformer.SharedInformerFactory
	recorder                                                       record.EventRecorder
	bgpIPv4Expected, bgpIPv4Exists, bgpIPv6Expected, bgpIPv6Exists []string
}

func NewController(config *Configuration) *Controller {
	utilruntime.Must(kubeovnv1.AddToScheme(scheme.Scheme))
	klog.V(4).Info("Creating event broadcaster")
	eventBroadcaster := record.NewBroadcaster()
	eventBroadcaster.StartLogging(klog.Infof)
	eventBroadcaster.StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: config.KubeClient.CoreV1().Events("")})
	recorder := eventBroadcaster.NewRecorder(scheme.Scheme, corev1.EventSource{Component: controllerAgentName})

	informerFactory := kubeinformers.NewSharedInformerFactoryWithOptions(config.KubeClient, 0,
		kubeinformers.WithTweakListOptions(func(listOption *metav1.ListOptions) {
			listOption.AllowWatchBookmarks = true
		}))
	kubeovnInformerFactory := kubeovninformer.NewSharedInformerFactoryWithOptions(config.KubeOvnClient, 0,
		kubeovninformer.WithTweakListOptions(func(listOption *metav1.ListOptions) {
			listOption.AllowWatchBookmarks = true
		}))

	podInformer := informerFactory.Core().V1().Pods()
	subnetInformer := kubeovnInformerFactory.Kubeovn().V1().Subnets()
	serviceInformer := informerFactory.Core().V1().Services()

	controller := &Controller{
		config: config,

		podsLister:     podInformer.Lister(),
		podsSynced:     podInformer.Informer().HasSynced,
		subnetsLister:  subnetInformer.Lister(),
		subnetSynced:   subnetInformer.Informer().HasSynced,
		servicesLister: serviceInformer.Lister(),
		servicesSynced: serviceInformer.Informer().HasSynced,

		informerFactory:        informerFactory,
		kubeovnInformerFactory: kubeovnInformerFactory,
		recorder:               recorder,
	}

	return controller
}

func (c *Controller) Run(stopCh <-chan struct{}) {
	defer utilruntime.HandleCrash()
	c.informerFactory.Start(stopCh)
	c.kubeovnInformerFactory.Start(stopCh)

	if ok := cache.WaitForCacheSync(stopCh, c.podsSynced, c.subnetSynced); !ok {
		klog.Fatalf("failed to wait for caches to sync")
		return
	}

	klog.Info("Started workers")
	go wait.Until(c.syncSubnetRoutes, 5*time.Second, stopCh)

	<-stopCh
	klog.Info("Shutting down workers")
}
