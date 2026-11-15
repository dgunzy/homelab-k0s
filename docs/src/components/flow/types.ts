// A diagram is plain data: layers (frames), nodes placed inside them, and edges.
// Coordinates are pixels; node positions are relative to their layer.

export type Side = 'top' | 'right' | 'bottom' | 'left';

export interface LayerSpec {
  id: string;
  label: string;
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface NodeSpec {
  id: string;
  layer?: string;
  x: number;
  y: number;
  label: string;
  sub?: string;
  /** Logo URL (import with `?url`). */
  logo: string;
  /** Single-colour icon drawn in the accent colour instead of a full-colour logo. */
  mono?: boolean;
  /** Docs page (relative to the site root) opened on click. */
  href?: string;
}

export interface EdgeSpec {
  from: string;
  to: string;
  label?: string;
  /** Which side of each node the edge leaves / enters. Defaults: bottom → top. */
  out?: Side;
  in?: Side;
  /** Dashed, no moving dot: a relationship rather than a flow. */
  quiet?: boolean;
}

export interface Diagram {
  title: string;
  layers: LayerSpec[];
  nodes: NodeSpec[];
  edges: EdgeSpec[];
}
