import type { Diagram } from '../types';
import k0s from '../../../assets/logos/k0s.svg?url';
import flux from '../../../assets/logos/flux.svg?url';
import inference from '../../../assets/logos/inference.svg?url';
import substrate from '../../../assets/logos/agent-substrate.svg?url';
import gpu from '../../../assets/logos/gpu.svg?url';
import hypervisor from '../../../assets/logos/hypervisor.svg?url';
import gateway from '../../../assets/logos/gateway.svg?url';

const W = 1096;

export const clusters: Diagram = {
  title: 'One management plane, many workload clusters: inference split out from agent clusters',
  layers: [
    { id: 'mgmt', label: 'Management cluster', x: 0, y: 0, width: W, height: 96 },
    { id: 'inf', label: 'Inference cluster', x: 0, y: 160, width: 480, height: 96 },
    { id: 'agA', label: 'Agents cluster: team A', x: 520, y: 160, width: 276, height: 96 },
    { id: 'agB', label: 'Agents cluster: team B', x: 820, y: 160, width: 276, height: 96 },
    { id: 'hosts', label: 'Hypervisor hosts (shared)', x: 0, y: 320, width: W, height: 96 },
  ],
  nodes: [
    { id: 'gitops', layer: 'mgmt', x: 24, y: 24, label: 'Flux + Cluster API', sub: 'one repo, many clusters', logo: flux },
    { id: 'cpInf', layer: 'mgmt', x: 456, y: 24, label: 'Inference CP', sub: 'pods', logo: k0s },
    { id: 'cpA', layer: 'mgmt', x: 672, y: 24, label: 'Team A CP', sub: 'pods', logo: k0s },
    { id: 'cpB', layer: 'mgmt', x: 888, y: 24, label: 'Team B CP', sub: 'pods', logo: k0s },

    { id: 'models', layer: 'inf', x: 24, y: 24, label: 'Model servers', sub: 'GPU pools', logo: inference, mono: true },
    { id: 'infgw', layer: 'inf', x: 252, y: 24, label: 'Inference gateway', sub: 'authenticated', logo: gateway, mono: true },
    { id: 'agentsA', layer: 'agA', x: 24, y: 24, label: 'Agents', sub: 'CPU pools', logo: substrate },
    { id: 'agentsB', layer: 'agB', x: 24, y: 24, label: 'Agents', sub: 'CPU pools', logo: substrate },

    { id: 'gpuHosts', layer: 'hosts', x: 24, y: 24, label: 'GPU hosts', sub: 'VFIO node VMs', logo: gpu, mono: true },
    { id: 'cpuHosts', layer: 'hosts', x: 672, y: 24, label: 'CPU hosts', sub: 'node VMs', logo: hypervisor, mono: true },
  ],
  edges: [
    { from: 'gitops', to: 'cpInf', out: 'right', in: 'left', quiet: true },
    { from: 'cpInf', to: 'cpA', out: 'right', in: 'left', quiet: true },
    { from: 'cpA', to: 'cpB', out: 'right', in: 'left', quiet: true },
    { from: 'cpInf', to: 'inf', label: 'API server' },
    { from: 'cpA', to: 'agA' },
    { from: 'cpB', to: 'agB' },
    { from: 'models', to: 'infgw', out: 'right', in: 'left', quiet: true },
    { from: 'agentsA', to: 'infgw', label: 'model calls', out: 'left', in: 'right' },
    { from: 'agentsB', to: 'infgw', out: 'bottom', in: 'bottom' },
    { from: 'gpuHosts', to: 'models', label: 'GPU nodes', out: 'top', in: 'bottom' },
    { from: 'cpuHosts', to: 'agentsA', label: 'CPU nodes', out: 'top', in: 'bottom' },
  ],
};
