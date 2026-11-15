import type { Diagram } from '../types';
import gpu from '../../../assets/logos/gpu.svg?url';
import hypervisor from '../../../assets/logos/hypervisor.svg?url';
import kubernetes from '../../../assets/logos/kubernetes.svg?url';
import inference from '../../../assets/logos/inference.svg?url';
import clusterApi from '../../../assets/logos/cluster-api.svg?url';
import signature from '../../../assets/logos/signature.svg?url';

const W = 1096;

export const gpuPath: Diagram = {
  title: 'A GPU from the PCIe slot to a pod, and back to a replacement when it fails',
  layers: [
    { id: 'host', label: 'Host', x: 0, y: 0, width: W, height: 96 },
    { id: 'node', label: 'GPU node (a VM)', x: 0, y: 160, width: W, height: 96 },
    { id: 'ops', label: 'Health and lifecycle', x: 0, y: 320, width: W, height: 96 },
  ],
  nodes: [
    { id: 'card', layer: 'host', x: 24, y: 24, label: 'GPU on vfio-pci', sub: 'whole IOMMU group', logo: gpu, mono: true },
    { id: 'vmm', layer: 'host', x: 456, y: 24, label: 'VMM', sub: 'guest RAM pinned', logo: hypervisor, mono: true },
    { id: 'driver', layer: 'node', x: 24, y: 24, label: 'Vendor driver', sub: 'in the guest, pinned', logo: gpu, mono: true },
    { id: 'operator', layer: 'node', x: 456, y: 24, label: 'GPU Operator', sub: 'toolkit, device plugin', logo: kubernetes },
    { id: 'pods', layer: 'node', x: 888, y: 24, label: 'GPU pods', sub: 'time-slicing / MPS / DRA', logo: inference, mono: true },
    { id: 'dcgm', layer: 'ops', x: 888, y: 24, label: 'DCGM', sub: 'XIDs, ECC, thermals', logo: signature, mono: true },
    { id: 'remediate', layer: 'ops', x: 456, y: 24, label: 'Remediation', sub: 'cordon, drain, health', logo: kubernetes },
    { id: 'replace', layer: 'ops', x: 24, y: 24, label: 'Replace Machine', sub: 'Cluster API', logo: clusterApi },
  ],
  edges: [
    { from: 'card', to: 'vmm', label: 'passthrough', out: 'right', in: 'left' },
    { from: 'vmm', to: 'driver', label: 'PCIe device in guest', out: 'bottom', in: 'top' },
    { from: 'driver', to: 'operator', out: 'right', in: 'left' },
    { from: 'operator', to: 'pods', label: 'nvidia.com/gpu', out: 'right', in: 'left' },
    { from: 'pods', to: 'dcgm', label: 'telemetry' },
    { from: 'dcgm', to: 'remediate', label: 'fault', out: 'left', in: 'right' },
    { from: 'remediate', to: 'replace', out: 'left', in: 'right' },
    { from: 'replace', to: 'driver', label: 'new node', out: 'top', in: 'bottom', quiet: true },
  ],
};
