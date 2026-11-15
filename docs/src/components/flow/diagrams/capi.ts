import type { Diagram } from '../types';
import clusterApi from '../../../assets/logos/cluster-api.svg?url';
import k0s from '../../../assets/logos/k0s.svg?url';
import kubernetes from '../../../assets/logos/kubernetes.svg?url';
import vm from '../../../assets/logos/vm.svg?url';
import hypervisor from '../../../assets/logos/hypervisor.svg?url';

const W = 1180;

export const capi: Diagram = {
  title: 'How a node pool gets a node',
  layers: [
    { id: 'mgmt', label: 'Management cluster', x: 0, y: 0, width: W, height: 256 },
    { id: 'host', label: 'Hypervisor host', x: 0, y: 320, width: W, height: 96 },
  ],
  nodes: [
    { id: 'cluster', layer: 'mgmt', x: 24, y: 24, label: 'Cluster', sub: 'the workload cluster', logo: clusterApi },
    { id: 'kcp', layer: 'mgmt', x: 500, y: 24, label: 'K0smotronControlPlane', sub: 'version, feature gates', logo: k0s },
    { id: 'cp', layer: 'mgmt', x: 930, y: 24, label: 'Control plane pods', sub: 'API server + etcd', logo: kubernetes },
    { id: 'md', layer: 'mgmt', x: 24, y: 152, label: 'MachineDeployment', sub: 'one per node pool', logo: clusterApi },
    { id: 'machine', layer: 'mgmt', x: 330, y: 152, label: 'Machine', sub: '+ bootstrap config', logo: clusterApi },
    { id: 'chm', layer: 'mgmt', x: 620, y: 152, label: 'CloudHypervisorMachine', sub: 'size, image, NICs', logo: vm, mono: true },
    { id: 'provider', layer: 'host', x: 620, y: 24, label: 'Host provider', sub: 'banlieue, on the host', logo: vm, mono: true },
    { id: 'vm', layer: 'host', x: 930, y: 24, label: 'Node VM', sub: 'Cloud Hypervisor', logo: hypervisor, mono: true },
  ],
  edges: [
    { from: 'cluster', to: 'kcp', label: 'controlPlaneRef', out: 'right', in: 'left' },
    { from: 'kcp', to: 'cp', label: 'runs', out: 'right', in: 'left' },
    { from: 'cluster', to: 'md', quiet: true },
    { from: 'md', to: 'machine', label: 'replicas', out: 'right', in: 'left' },
    { from: 'machine', to: 'chm', out: 'right', in: 'left' },
    { from: 'chm', to: 'provider', label: 'watched by' },
    { from: 'provider', to: 'vm', label: 'creates', out: 'right', in: 'left' },
    { from: 'vm', to: 'cp', label: 'joins', out: 'top', in: 'bottom' },
  ],
};
