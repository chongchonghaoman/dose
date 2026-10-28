import type { HostState } from '@shared/protocol';
import { HostCallError, type Reply, type RequestOptions, type Transport } from './transport';

type DoseEditor = { invoke(op: string, args?: unknown[]): Promise<any>; request(method: string, params?: any, options?: RequestOptions): Promise<{ result: any; payload?: Uint8Array | ArrayBuffer }>; onEvent(cb: (e: any) => void): () => void };
const api = () => (window as any).doseEditor as DoseEditor;
function bytes(x: Uint8Array | ArrayBuffer | undefined) { return x instanceof Uint8Array ? x : x ? new Uint8Array(x) : new Uint8Array(); }
export function electronTransport(): Transport {
  return {
    kind: 'electron',
    async request(method, params, opts = {}): Promise<Reply> {
      try { const r = await api().request(method, params, opts); return { result: r.result ?? {}, payload: bytes(r.payload) }; }
      catch (e) { const x = e as any; throw new HostCallError(method, x?.code ?? 'internal', x?.message ?? String(e)); }
    },
    state: () => api().invoke('state') as Promise<HostState>,
    onState(cb) { return api().onEvent((e) => e?.type === 'state' && cb(e.state ?? e)); },
    onEvent(cb) { return api().onEvent((e) => e?.type !== 'state' && cb(e)); },
    restart: () => api().invoke('restart'), diagnostics: () => api().invoke('diagnostics'),
  };
}
