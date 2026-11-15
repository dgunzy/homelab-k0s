// Docs site: Astro Starlight, with interactive architecture diagrams (React Flow islands).
// Built and deployed to GitHub Pages by .github/workflows/docs.yaml.
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';

export default defineConfig({
  site: 'https://dgunzy.github.io',
  base: '/homelab-k0s',
  integrations: [
    starlight({
      title: 'GPU Platform Blueprint',
      description:
        'A reference architecture for GPU inference and sandboxed AI agents on Kubernetes: hypervisor hosts, Cluster API, hosted control planes and GitOps.',
      logo: { src: './src/assets/mark.svg', replacesTitle: false },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/dgunzy/homelab-k0s' }],
      editLink: { baseUrl: 'https://github.com/dgunzy/homelab-k0s/edit/main/docs/' },
      lastUpdated: true,
      customCss: [
        '@fontsource-variable/inter',
        '@fontsource-variable/space-grotesk',
        '@fontsource-variable/jetbrains-mono',
        './src/styles/theme.css',
      ],
      sidebar: [
        {
          label: 'Architecture',
          items: [
            { label: 'Overview', slug: 'architecture/overview' },
            { label: 'Hypervisor hosts', slug: 'architecture/hosts' },
            { label: 'Management plane', slug: 'architecture/management-plane' },
            { label: 'Workload clusters', slug: 'architecture/workload-clusters' },
            { label: 'GPUs, done properly', slug: 'architecture/gpu' },
            { label: 'Sandboxed agents', slug: 'architecture/agents' },
            { label: 'GitOps and supply chain', slug: 'architecture/gitops' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Prepare a host', slug: 'guides/prepare-a-host' },
            { label: 'Prove GPU passthrough', slug: 'guides/gpu-passthrough' },
            { label: 'Bootstrap the management cluster', slug: 'guides/management-cluster' },
            { label: 'Run virtual machines', slug: 'guides/virtual-machines' },
            { label: 'Day 2', slug: 'guides/day-2' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Roadmap and status', slug: 'reference/roadmap' },
            { label: 'Repository layout', slug: 'reference/repository-layout' },
            { label: 'Versions', slug: 'reference/versions' },
            { label: 'Lessons learned', slug: 'reference/lessons-learned' },
          ],
        },
        {
          label: 'Example deployment',
          items: [
            { label: 'A single desktop host', slug: 'example/desktop-host' },
            { label: 'OS install helper', slug: 'example/os-install' },
          ],
        },
      ],
    }),
    react(),
  ],
});
