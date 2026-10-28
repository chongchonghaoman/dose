import type { AppPaths, FileEntry, Platform } from './index';

type DoseEditor = { invoke(op: string, args?: unknown[]): Promise<any>; onEvent(cb: (e: any) => void): () => void };
const api = () => (window as any).doseEditor as DoseEditor;
const call = <T>(op: string, ...args: unknown[]) => api().invoke(op, args) as Promise<T>;

export function electronPlatform(): Platform {
  return {
    kind: 'electron',
    listImages: (dir) => call<FileEntry[]>('listImages', dir), expandPaths: (p) => call<FileEntry[]>('expandPaths', p),
    sidecarLoad: (p) => call('sidecarLoad', p), sidecarSave: (p, v) => call('sidecarSave', p, v), sidecarPath: (p) => call('sidecarPath', p),
    pairLoad: (p) => call('pairLoad', p), pairSave: (p, v) => call('pairSave', p, v), pairCreate: (p, v) => call('pairCreate', p, v),
    storeRead: (a, n) => call('storeRead', a, n), storeWrite: (a, n, v) => call('storeWrite', a, n, v), takeLaunchPaths: () => call('takeLaunchPaths'),
    pathExists: (p) => call('pathExists', p), ensureDir: (p) => call('ensureDir', p), appPaths: () => call<AppPaths>('appPaths'),
    pickFolder: (t) => call<string | null>('pickFolder', t), pickFiles: (t) => call<string[]>('pickFiles', t), pickSave: (t, p, e) => call<string | null>('pickSave', t, p, e),
    reveal: (p) => call('reveal', p), openUrl: (u) => call('openUrl', u), message: (t, x, k) => call('message', t, x, k), confirm: (t, x) => call('confirm', t, x),
    onOpenPaths(cb) { return api().onEvent((e) => e?.type === 'openPaths' && cb(e.paths ?? [])); },
    onDrop(cb) { return api().onEvent((e) => e?.type === 'drop' && cb(e.paths ?? [])); },
    setTitle: (t) => call('setTitle', t), log: (l, m) => { void call('log', l, m).catch(() => {}); }, toggleFullscreen: () => call('toggleFullscreen'),
  };
}
