// host.js — the generic host, embedded into the server binary at build time. It
// instantiates the wasm, wires the reactive runtime's DOM ops, seeds the target
// count, hydrates, and forwards "Backup now" clicks. App logic lives in the MFL.
const dec = new TextDecoder();
let mem;
const cstr = (p) => { const b = new Uint8Array(mem.buffer); let e = p; while (b[e]) e++; return dec.decode(b.subarray(p, e)); };

const env = {
  // reactive runtime -> DOM
  dom_mount: (r, h) => { document.getElementById(cstr(r)).innerHTML = cstr(h); },
  dom_patch: (s, v) => { const el = document.querySelector('[data-s="' + cstr(s) + '"]'); if (el) el.textContent = cstr(v); },
  list_insert: (c, k, h) => { const li = document.createElement('li'); li.dataset.k = cstr(k); li.innerHTML = cstr(h); document.getElementById(cstr(c)).appendChild(li); },
  list_remove: (c, k) => { const el = document.querySelector('#' + cstr(c) + ' > [data-k="' + cstr(k) + '"]'); if (el) el.remove(); },
  list_order: (c, csv) => { const cont = document.getElementById(cstr(c)); for (const k of cstr(csv).split(',').filter(Boolean)) { const el = cont.querySelector('[data-k="' + k + '"]'); if (el) cont.appendChild(el); } },
  // app effect: POST the backup for target i (URL comes from the SSR'd button), then
  // report the result back into the wasm so the status slot reacts.
  api_backup: (i) => {
    i = Number(i);
    const btn = document.querySelector('[data-opt="' + i + '"] [data-backup]');
    if (!btn) { instance.exports.done(BigInt(i), BigInt(0)); return; }
    fetch(btn.dataset.backup, { method: 'POST' })
      .then((r) => r.json())
      .then((j) => instance.exports.done(BigInt(i), BigInt(j && j.ok ? 1 : 0)))
      .catch(() => instance.exports.done(BigInt(i), BigInt(0)));
  },
};
// no-op WASI shim (imported but never called)
const wasi = { fd_write: () => 0, fd_seek: () => 0, fd_close: () => 0, fd_fdstat_get: () => 0 };

const { instance } = await WebAssembly.instantiateStreaming(fetch('/app.wasm'), { env, wasi_snapshot_preview1: wasi });
mem = instance.exports.memory;
instance.exports._initialize?.();

instance.exports.set_n(BigInt(window.__NTARGETS || 0));
instance.exports.start();

// delegate clicks: a "Backup now" button kicks off its target's backup.
document.getElementById('app').addEventListener('click', (e) => {
  const btn = e.target.closest('[data-backup]');
  if (!btn) return;
  const row = btn.closest('[data-opt]');
  if (row) instance.exports.kick(BigInt(row.dataset.opt));
});
