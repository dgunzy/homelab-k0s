import { useCallback, useMemo, useState } from 'react';
import {
  BaseEdge,
  Controls,
  EdgeLabelRenderer,
  Handle,
  Position,
  ReactFlow,
  ReactFlowProvider,
  getSmoothStepPath,
  type Edge,
  type EdgeProps,
  type Node,
  type NodeProps,
} from '@xyflow/react';
import '@xyflow/react/dist/base.css';
import './flow.css';
import { diagrams } from './diagrams';
import type { Diagram, NodeSpec, Side } from './types';

const SIDES: Record<Side, Position> = {
  top: Position.Top,
  right: Position.Right,
  bottom: Position.Bottom,
  left: Position.Left,
};

// Cards size to their content (React Flow measures them); this keeps columns even.
const NODE_WIDTH = 176;

type FlowData = { label?: string; quiet?: boolean };

function LogoNode({ data }: NodeProps<Node<NodeSpec>>) {
  const cls = ['flow-node', data.href && 'is-link']
    .filter(Boolean)
    .join(' ');
  return (
    <div className={cls} style={{ minWidth: NODE_WIDTH }} title={data.href ? `Open: ${data.label}` : undefined}>
      {(Object.keys(SIDES) as Side[]).map((side) => (
        <span key={side}>
          <Handle type="target" id={`in-${side}`} position={SIDES[side]} className="flow-handle" />
          <Handle type="source" id={`out-${side}`} position={SIDES[side]} className="flow-handle" />
        </span>
      ))}
      {data.mono ? (
        <span className="flow-logo flow-logo-mono" style={{ maskImage: `url("${data.logo}")`, WebkitMaskImage: `url("${data.logo}")` }} />
      ) : (
        <img className="flow-logo" src={data.logo} alt="" loading="lazy" />
      )}
      <span className="flow-text">
        <span className="flow-label">{data.label}</span>
        {data.sub && <span className="flow-sub">{data.sub}</span>}
      </span>
    </div>
  );
}

function LayerNode({ data }: NodeProps<Node<{ label: string }>>) {
  return (
    <div className="flow-layer">
      <Handle type="target" id="in-top" position={Position.Top} className="flow-handle" />
      <Handle type="source" id="out-bottom" position={Position.Bottom} className="flow-handle" />
      <span className="flow-layer-label">{data.label}</span>
    </div>
  );
}

function FlowEdge({ id, source, target, sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, markerEnd, data }: EdgeProps<Edge<FlowData>>) {
  const [path, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    borderRadius: 14,
  });
  const cls = ['flow-edge', data?.quiet && 'is-quiet']
    .filter(Boolean)
    .join(' ');
  return (
    <g className={cls}>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} className="flow-edge-path" />
      {!data?.quiet && (
        <circle r={4} className="flow-edge-dot">
          <animateMotion dur="2.8s" repeatCount="indefinite" path={path} />
        </circle>
      )}
      {data?.label && (
        <EdgeLabelRenderer>
          <div className={`flow-edge-label nodrag nopan l-from-${source} l-to-${target}`} style={{ transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)` }}>
            {data.label}
          </div>
        </EdgeLabelRenderer>
      )}
    </g>
  );
}

const nodeTypes = { logo: LogoNode, layer: LayerNode };
const edgeTypes = { flow: FlowEdge };

// Nodes and edges are built once per diagram and never replaced: React Flow
// hides nodes until it has measured them, and fresh node objects lose those
// measurements. Hover highlighting is a generated stylesheet instead.
function buildNodes(diagram: Diagram): Node[] {
  return [
    ...diagram.layers.map((l) => ({
      id: l.id,
      type: 'layer',
      position: { x: l.x, y: l.y },
      data: { label: l.label },
      style: { width: l.width, height: l.height },
      selectable: false,
      draggable: false,
      zIndex: -1,
    })),
    ...diagram.nodes.map((n) => ({
      id: n.id,
      type: 'logo',
      className: `n-${n.id}`,
      position: { x: n.x, y: n.y },
      parentId: n.layer,
      extent: n.layer ? ('parent' as const) : undefined,
      draggable: false,
      data: n,
    })),
  ];
}

function buildEdges(diagram: Diagram): Edge[] {
  return diagram.edges.map((e, i) => ({
    id: `e${i}`,
    type: 'flow',
    className: `e-from-${e.from} e-to-${e.to}`,
    source: e.from,
    target: e.to,
    sourceHandle: `out-${e.out ?? 'bottom'}`,
    targetHandle: `in-${e.in ?? 'top'}`,
    markerEnd: { type: 'arrowclosed' as const, width: 16, height: 16, color: 'var(--sl-color-accent)' },
    data: { label: e.label, quiet: e.quiet },
  }));
}

function hoverStyles(scope: string, diagram: Diagram, hovered: string | null): string {
  if (!hovered) return '';
  const near = new Set<string>([hovered]);
  for (const e of diagram.edges) {
    if (e.from === hovered) near.add(e.to);
    if (e.to === hovered) near.add(e.from);
  }
  const s = `[data-flow="${scope}"]`;
  const keep = [...near].map((id) => `.n-${id}`).join(',');
  const touch = `.e-from-${hovered},.e-to-${hovered}`;
  return [
    `${s} .react-flow__node-logo:not(${keep}) .flow-node{opacity:.3}`,
    `${s} .react-flow__node-logo.n-${hovered} .flow-node{border-color:var(--sl-color-accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--sl-color-accent) 25%,transparent)}`,
    `${s} .react-flow__edge:not(${touch}){opacity:.15}`,
    `${s} .flow-edge-label:not(.l-from-${hovered},.l-to-${hovered}){opacity:.25}`,
    `${s} .react-flow__edge:is(${touch}) .flow-edge-path{stroke:var(--sl-color-accent);stroke-width:3}`,
  ].join('\n');
}

function Flow({ diagram, scope }: { diagram: Diagram; scope: string }) {
  const [hovered, setHovered] = useState<string | null>(null);
  const nodes = useMemo(() => buildNodes(diagram), [diagram]);
  const edges = useMemo(() => buildEdges(diagram), [diagram]);

  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  const onNodeClick = useCallback(
    (_: unknown, node: Node) => {
      const href = (node.data as Partial<NodeSpec>).href;
      if (href) window.location.href = `${base}/${href.replace(/^\//, '')}`;
    },
    [base],
  );

  return (
    <>
      <style>{hoverStyles(scope, diagram, hovered)}</style>
      <ReactFlow
        defaultNodes={nodes}
        defaultEdges={edges}
        nodeTypes={nodeTypes}
        edgeTypes={edgeTypes}
        onNodeMouseEnter={(_, n) => n.type === 'logo' && setHovered(n.id)}
        onNodeMouseLeave={() => setHovered(null)}
        onNodeClick={onNodeClick}
        fitView
        fitViewOptions={{ padding: 0.06 }}
        minZoom={0.4}
        maxZoom={2}
        zoomOnScroll={false}
        zoomOnPinch
        panOnScroll={false}
        preventScrolling={false}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        proOptions={{ hideAttribution: true }}
      >
        <Controls showInteractive={false} orientation="horizontal" position="bottom-right" />
      </ReactFlow>
    </>
  );
}

// The canvas takes the diagram's own aspect ratio (plus a strip for the zoom
// controls), so fitView fills the width on any screen without dead space.
function aspectRatio(diagram: Diagram): string {
  const right = Math.max(...diagram.layers.map((l) => l.x + l.width));
  const bottom = Math.max(...diagram.layers.map((l) => l.y + l.height));
  const pad = 0.12;
  return `${right * (1 + pad)} / ${bottom * (1 + pad) + 96}`;
}

export default function ArchitectureFlow({ name }: { name: keyof typeof diagrams }) {
  const diagram = diagrams[name];
  return (
    <figure className="flow-figure not-content">
      <div className="flow-canvas" data-flow={name} style={{ aspectRatio: aspectRatio(diagram), minHeight: 320 }}>
        <ReactFlowProvider>
          <Flow diagram={diagram} scope={name} />
        </ReactFlowProvider>
      </div>
      <figcaption className="flow-caption">
        {diagram.title}
        <span className="flow-hint">Hover to trace connections · click a component to open its page · drag to pan</span>
      </figcaption>
    </figure>
  );
}
