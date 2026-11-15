import type { Diagram } from '../types';
import github from '../../../assets/logos/github.svg?url';
import signature from '../../../assets/logos/signature.svg?url';
import oci from '../../../assets/logos/oci.svg?url';
import flux from '../../../assets/logos/flux.svg?url';
import clusterApi from '../../../assets/logos/cluster-api.svg?url';
import k0s from '../../../assets/logos/k0s.svg?url';
import vm from '../../../assets/logos/vm.svg?url';
import kubernetes from '../../../assets/logos/kubernetes.svg?url';
import hypervisor from '../../../assets/logos/hypervisor.svg?url';
import gpu from '../../../assets/logos/gpu.svg?url';
import inference from '../../../assets/logos/inference.svg?url';
import gateway from '../../../assets/logos/gateway.svg?url';
import substrate from '../../../assets/logos/agent-substrate.svg?url';
import gvisor from '../../../assets/logos/gvisor.svg?url';

// Four layers, one row each. Columns at x = 24 / 240 / 456 / 672 / 888; cards are 184 wide.
const W = 1096;

export const overview: Diagram = {
  title: 'The platform: from a Git push to GPU inference and sandboxed agents',
  layers: [
    { id: 'source', label: 'Source of truth', x: 0, y: 0, width: W, height: 96 },
    { id: 'mgmt', label: 'Management cluster', x: 0, y: 160, width: W, height: 96 },
    { id: 'hosts', label: 'Hypervisor hosts', x: 0, y: 320, width: W, height: 96 },
    { id: 'workload', label: 'Workload clusters (one combined, or inference and agents split)', x: 0, y: 480, width: W, height: 96 },
  ],
  nodes: [
    { id: 'repo', layer: 'source', x: 24, y: 24, label: 'Git repo', sub: 'manifests + pins', logo: github, mono: true, href: 'reference/repository-layout/' },
    { id: 'ci', layer: 'source', x: 456, y: 24, label: 'CI', sub: 'validate · sign', logo: signature, mono: true, href: 'architecture/gitops/' },
    { id: 'artifact', layer: 'source', x: 888, y: 24, label: 'OCI artifact', sub: 'ghcr.io, signed', logo: oci, mono: true, href: 'architecture/gitops/' },

    { id: 'flux', layer: 'mgmt', x: 888, y: 24, label: 'Flux', sub: 'Flux Operator', logo: flux, href: 'architecture/gitops/' },
    { id: 'capi', layer: 'mgmt', x: 672, y: 24, label: 'Cluster API', sub: 'machine pools', logo: clusterApi, href: 'architecture/management-plane/' },
    { id: 'k0smotron', layer: 'mgmt', x: 456, y: 24, label: 'k0smotron', sub: 'hosted CPs', logo: k0s, href: 'architecture/workload-clusters/' },
    { id: 'cp', layer: 'mgmt', x: 240, y: 24, label: 'Control planes', sub: 'pods per cluster', logo: kubernetes, href: 'architecture/workload-clusters/' },
    { id: 'banlieue', layer: 'mgmt', x: 24, y: 24, label: 'banlieue', sub: 'VM API', logo: vm, mono: true, href: 'architecture/management-plane/' },

    { id: 'provider', layer: 'hosts', x: 24, y: 24, label: 'Host provider', sub: 'one per host', logo: vm, mono: true, href: 'architecture/hosts/' },
    { id: 'vmm', layer: 'hosts', x: 456, y: 24, label: 'Cloud Hypervisor', sub: 'a VMM per VM', logo: hypervisor, mono: true, href: 'architecture/hosts/' },
    { id: 'gpu', layer: 'hosts', x: 888, y: 24, label: 'GPU', sub: 'VFIO passthrough', logo: gpu, mono: true, href: 'architecture/gpu/' },

    { id: 'agents', layer: 'workload', x: 24, y: 24, label: 'Substrate', sub: 'cpu pool', logo: substrate, href: 'architecture/agents/' },
    { id: 'gvisor', layer: 'workload', x: 240, y: 24, label: 'gVisor', sub: 'actor sandbox', logo: gvisor, href: 'architecture/agents/' },
    { id: 'egress', layer: 'workload', x: 456, y: 24, label: 'Egress', sub: 'adds credentials', logo: gateway, mono: true, href: 'architecture/agents/' },
    { id: 'inference', layer: 'workload', x: 888, y: 24, label: 'Inference', sub: 'gpu pool', logo: inference, mono: true, href: 'architecture/gpu/' },
  ],
  edges: [
    { from: 'repo', to: 'ci', label: 'git push', out: 'right', in: 'left' },
    { from: 'ci', to: 'artifact', label: 'publish + sign', out: 'right', in: 'left' },
    { from: 'artifact', to: 'flux', label: 'pull + verify' },
    { from: 'flux', to: 'capi', out: 'left', in: 'right' },
    { from: 'capi', to: 'k0smotron', out: 'left', in: 'right' },
    { from: 'k0smotron', to: 'cp', out: 'left', in: 'right' },
    { from: 'cp', to: 'banlieue', out: 'left', in: 'right' },
    { from: 'banlieue', to: 'provider', label: 'VMs to create' },
    { from: 'provider', to: 'vmm', label: 'start', out: 'right', in: 'left' },
    { from: 'gpu', to: 'inference', label: 'passthrough' },
    { from: 'vmm', to: 'workload', label: 'VMs join as nodes' },
    { from: 'agents', to: 'gvisor', out: 'right', in: 'left', quiet: true },
    { from: 'gvisor', to: 'egress', out: 'right', in: 'left' },
    { from: 'egress', to: 'inference', label: 'OpenAI API', out: 'right', in: 'left' },
  ],
};
