// Registry of diagrams, referenced by name from MDX: <ArchitectureFlow client:visible name="overview" />
import { overview } from './overview';
import { gitops } from './gitops';
import { capi } from './capi';
import { gpuPath } from './gpu';
import { agents } from './agents';
import { clusters } from './clusters';

export const diagrams = { overview, gitops, capi, gpu: gpuPath, agents, clusters };
