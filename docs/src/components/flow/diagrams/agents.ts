import type { Diagram } from '../types';
import agent from '../../../assets/logos/agent.svg?url';
import gateway from '../../../assets/logos/gateway.svg?url';
import substrate from '../../../assets/logos/agent-substrate.svg?url';
import gvisor from '../../../assets/logos/gvisor.svg?url';
import oci from '../../../assets/logos/oci.svg?url';
import inference from '../../../assets/logos/inference.svg?url';
import signature from '../../../assets/logos/signature.svg?url';

const W = 1096;

export const agents: Diagram = {
  title: 'One agent request: resumed on demand, sandboxed, credentials added outside',
  layers: [
    { id: 'edge', label: 'In', x: 0, y: 0, width: W, height: 96 },
    { id: 'cpu', label: 'cpu node pool', x: 0, y: 160, width: W, height: 96 },
    { id: 'gpu', label: 'gpu node pool and egress', x: 0, y: 320, width: W, height: 96 },
  ],
  nodes: [
    { id: 'client', layer: 'edge', x: 24, y: 24, label: 'Caller', sub: 'user or system', logo: agent, mono: true },
    { id: 'router', layer: 'edge', x: 456, y: 24, label: 'Router', sub: 'holds request, resumes', logo: gateway, mono: true },
    { id: 'api', layer: 'edge', x: 888, y: 24, label: 'Substrate API', sub: 'actors, workers', logo: substrate },
    { id: 'actor', layer: 'cpu', x: 456, y: 24, label: 'Actor', sub: 'in a warm worker', logo: substrate },
    { id: 'sandbox', layer: 'cpu', x: 24, y: 24, label: 'gVisor sandbox', sub: 'no credentials inside', logo: gvisor },
    { id: 'snap', layer: 'cpu', x: 888, y: 24, label: 'Snapshots', sub: 'object storage', logo: oci, mono: true },
    { id: 'egress', layer: 'gpu', x: 24, y: 24, label: 'Egress gateway', sub: 'policy + credentials', logo: signature, mono: true },
    { id: 'model', layer: 'gpu', x: 456, y: 24, label: 'Inference service', sub: 'OpenAI-compatible', logo: inference, mono: true },
    { id: 'tools', layer: 'gpu', x: 888, y: 24, label: 'External APIs', sub: 'allow-listed', logo: gateway, mono: true },
  ],
  edges: [
    { from: 'client', to: 'router', label: 'request', out: 'right', in: 'left' },
    { from: 'router', to: 'api', label: 'resume?', out: 'right', in: 'left', quiet: true },
    { from: 'router', to: 'actor', label: 'route' },
    { from: 'actor', to: 'snap', label: 'suspend / restore', out: 'right', in: 'left', quiet: true },
    { from: 'actor', to: 'sandbox', out: 'left', in: 'right', quiet: true },
    { from: 'sandbox', to: 'egress', label: 'outbound only' },
    { from: 'egress', to: 'model', label: '+ API key', out: 'right', in: 'left' },
    { from: 'model', to: 'tools', out: 'right', in: 'left', quiet: true },
  ],
};
