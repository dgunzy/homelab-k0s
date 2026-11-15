import type { Diagram } from '../types';
import github from '../../../assets/logos/github.svg?url';
import signature from '../../../assets/logos/signature.svg?url';
import oci from '../../../assets/logos/oci.svg?url';
import flux from '../../../assets/logos/flux.svg?url';
import certManager from '../../../assets/logos/cert-manager.svg?url';
import clusterApi from '../../../assets/logos/cluster-api.svg?url';
import k0s from '../../../assets/logos/k0s.svg?url';
import vm from '../../../assets/logos/vm.svg?url';
import git from '../../../assets/logos/git.svg?url';

const W = 1240;

export const gitops: Diagram = {
  title: 'From a pull request to a reconciled cluster',
  layers: [
    { id: 'pr', label: 'Pull request', x: 0, y: 0, width: W, height: 96 },
    { id: 'main', label: 'Merge to main', x: 0, y: 160, width: W, height: 96 },
    { id: 'cluster', label: 'Management cluster', x: 0, y: 320, width: W, height: 96 },
  ],
  nodes: [
    { id: 'change', layer: 'pr', x: 24, y: 24, label: 'Change', sub: 'manifests or a pin', logo: git, mono: true },
    { id: 'schema', layer: 'pr', x: 520, y: 24, label: 'flux-schema', sub: 'schemas + CEL rules', logo: flux },
    { id: 'lint', layer: 'pr', x: 1016, y: 24, label: 'ShellCheck', sub: 'bootstrap scripts', logo: github, mono: true },

    { id: 'push', layer: 'main', x: 1016, y: 24, label: 'flux push artifact', sub: ':<sha>, only if valid', logo: oci, mono: true },
    { id: 'sign', layer: 'main', x: 520, y: 24, label: 'cosign sign', sub: 'keyless, GitHub OIDC', logo: signature, mono: true },
    { id: 'latest', layer: 'main', x: 24, y: 24, label: 'Tag :latest', sub: 'after signing', logo: oci, mono: true },

    { id: 'source', layer: 'cluster', x: 24, y: 24, label: 'OCIRepository', sub: 'verifies signature', logo: flux },
    { id: 'certmanager', layer: 'cluster', x: 272, y: 24, label: 'cert-manager', sub: 'Kustomization', logo: certManager },
    { id: 'capi', layer: 'cluster', x: 520, y: 24, label: 'Cluster API', sub: 'Kustomization', logo: clusterApi },
    { id: 'k0smotron', layer: 'cluster', x: 768, y: 24, label: 'k0smotron', sub: 'Kustomization', logo: k0s },
    { id: 'banlieue', layer: 'cluster', x: 1016, y: 24, label: 'banlieue → hosts', sub: 'Kustomizations', logo: vm, mono: true },
  ],
  edges: [
    { from: 'change', to: 'schema', label: 'validate', out: 'right', in: 'left' },
    { from: 'schema', to: 'lint', out: 'right', in: 'left', quiet: true },
    { from: 'lint', to: 'push', label: 'green' },
    { from: 'push', to: 'sign', label: 'digest', out: 'left', in: 'right' },
    { from: 'sign', to: 'latest', out: 'left', in: 'right' },
    { from: 'latest', to: 'source', label: 'pull' },
    { from: 'source', to: 'certmanager', label: 'apply', out: 'right', in: 'left' },
    { from: 'certmanager', to: 'capi', out: 'right', in: 'left' },
    { from: 'capi', to: 'k0smotron', out: 'right', in: 'left' },
    { from: 'k0smotron', to: 'banlieue', out: 'right', in: 'left', quiet: true },
  ],
};
