import { useEffect, useState } from 'react';
import { exportFrame } from './export/exporter';
import { DEFAULT_RECIPES } from './export/recipes';
import { sessionStore, useSession, resolvedParams, flushPendingEdits, flushPairChanges, flushSave } from './state/session';

export interface DoseEditorApi { invoke(op: string, args?: unknown[]): Promise<any>; request(method: string, params?: any, options?: { payload?: Uint8Array; timeoutMs?: number }): Promise<{ result: any; payload?: Uint8Array | ArrayBuffer }>; onEvent(cb: (event: any) => void): () => void; onState(cb: (state: any) => void): () => void; }
declare global { interface Window { doseEditor?: DoseEditorApi } }

export function DoseReturnToolbar() {
  const electron = typeof window !== 'undefined' && !!window.doseEditor;
  const [busy, setBusy] = useState(false); const [error, setError] = useState<string | null>(null);
  const ready = useSession((s) => !!s.selection && !!s.engineSession && !!s.nativeSize && !s.developing && !s.batchExporting && !s.pairUpdating);
  useEffect(() => {
    if (!electron) return;
    const api = window.doseEditor!;
    void api.invoke('editorReady', []).catch(() => {});
    return api.onEvent((event) => {
      if (event?.type !== 'close-request') return;
      if (busy || sessionStore.getState().batchExporting) { void api.invoke('closeFailed', ['请等待显影或导出完成']).catch(() => {}); return; }
      void (async () => {
        try { await flushPendingEdits(); await flushPairChanges(false); await flushSave(true); await api.invoke('closeReady', []); }
        catch (e) { await api.invoke('closeFailed', [e instanceof Error ? e.message : String(e)]).catch(() => {}); }
      })();
    });
  }, [electron, busy]);
  if (!electron) return null;
  async function finish() {
    if (busy || !ready) return; setBusy(true); setError(null);
    let locked = false;
    try {
      await flushPendingEdits(); await flushPairChanges(false); await flushSave(true);
      const s = sessionStore.getState(); if (!s.selection || !s.engineSession || !s.nativeSize) throw new Error('No frame is ready to return.');
      if (s.batchExporting) throw new Error('请等待当前导出完成。');
      sessionStore.setState({ batchExporting: true }); locked = true;
      const prepared = await window.doseEditor!.invoke('prepareReturn', []); const dir = prepared?.path;
      if (!dir) throw new Error('Dose did not provide a return directory.');
      const recipe = { ...DEFAULT_RECIPES.find((r) => r.id === 'tiff-prophoto')!, folder: { kind: 'fixed' as const, path: dir }, existing: 'overwrite' as const };
      const outcome = await exportFrame(recipe, { path: s.selection, session: s.engineSession, params: resolvedParams(), adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry, native: s.nativeSize, pairComplete: s.pairDocument ? s.pairInfo?.can_export === true : undefined, pairDocument: s.pairDocument, pairInfo: s.pairInfo }, s.catalog, s.hello?.methods);
      if (outcome.kind !== 'written') throw new Error(outcome.kind === 'failed' ? outcome.message : 'Return export was skipped.');
      await window.doseEditor!.invoke('completeReturn', [outcome.path, s.selection, { nativeFrame: resolvedParams().filmEdge.active }]);
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { if (locked) sessionStore.setState({ batchExporting: false }); setBusy(false); }
  }
  return <div className="dose-toolbar" role="toolbar" aria-label="dose 显影室"><span className="dose-toolbar-brand">dose 显影室</span><span className="dose-toolbar-credit">Powered by SpektraLab</span><button disabled={busy || !ready} onClick={() => void finish()}>{busy ? '正在返回…' : '完成并返回 dose'}</button>{error && <span className="dose-toolbar-error" role="alert">{error}</span>}</div>;
}
