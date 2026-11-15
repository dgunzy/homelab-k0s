---
title: Roadmap and status
description: The platform is built in phases, each with an exit check that has to pass before the next one starts.
---

Each phase ends with a check that proves it works. The next phase doesn't start until it passes.

| # | Phase | Status | Exit check |
|---|---|---|---|
| 1 | Hypervisor host and GPU passthrough | <span class="pill done">done</span> | The vendor tool runs in a VM on a passed-through GPU, and the GPU survives a guest power-off |
| 2 | Management cluster, GitOps, VMs on demand | <span class="pill done">done</span> | A host `Provider` reports capacity, and a `VirtualMachine` boots and takes SSH |
| 3 | Workload cluster: hosted control plane, `cpu` and `gpu` node pools | <span class="pill next">next</span> | A CUDA sample pod passes on a node Cluster API created; deleting its `Machine` brings back a working replacement |
| 4 | Node image pipeline | <span class="pill planned">planned</span> | A signed GPU node image with an SBOM and a CVE gate, rolled through a node pool |
| 5 | GPU health and remediation | <span class="pill planned">planned</span> | An injected GPU fault ends with the node replaced and its workloads rescheduled |
| 6 | GPU scheduling | <span class="pill planned">planned</span> | Time-slicing vs MPS vs DRA compared; queued batch work with Kueue / KAI Scheduler; Slurm on Kubernetes |
| 7 | Workloads | <span class="pill planned">planned</span> | An agent in a gVisor sandbox calls the inference service through the egress gateway, with no credential inside the sandbox |
| — | More clusters, more hosts | <span class="pill planned">planned</span> | Inference split into its own cluster; a second host as another failure domain |

## Phase 3 in more detail

- ~~Upgrade the management cluster to 1.37 (`bootstrap-mgmt.sh upgrade`), one minor at a time.~~
  Done: 1.35 → 1.36 → 1.37 in about 15 minutes, no workload changes.
- Workload cluster `ai-01` (`workload-clusters/ai-01/`, written; its Flux Kustomization is suspended until it's switched on in git):
  a hosted control plane (`K0smotronControlPlane`, k0s 1.37) and a `cpu` `MachineDeployment`
  of one node, created through Cluster API with its join data delivered by banlieue.
- Then the `gpu` pool: node VMs with the GPU passed through, the GPU Operator with the
  driver preinstalled in the node, and the CUDA sample pod. GPU node VMs need a PCI device on
  their machine spec, which is being added to banlieue upstream.
- Agent Substrate's API feature gates go on the control plane when Substrate lands (phase 7).

## Phase 4–6 notes

- **Node images:** driver and kernel pinned as a pair, built and tested together, signed with
  cosign, with an SBOM and a vulnerability gate; upgrades roll through the `MachineDeployment`.
- **Health:** DCGM exporter → metrics → detection (Xids, ECC, thermals, falling off the bus) →
  cordon and drain → `MachineHealthCheck` replaces the `Machine`. Compare a purpose-built
  controller with off-the-shelf remediation. VMs make fault injection cheap.
- **Scheduling:** the same GPU shared by time-slicing, MPS and DRA, measured; Kueue and KAI
  Scheduler for queues and fair share; Slurm on Kubernetes for comparison.
