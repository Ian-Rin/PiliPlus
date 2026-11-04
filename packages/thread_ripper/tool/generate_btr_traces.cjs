// Runs Bilibili-thread-ripper's own downloader (src/idm-downloader.js) through the
// scripted networks in test/fixtures/btr_scenarios.json on a virtual clock, and writes
// what happened to test/fixtures/btr_traces.json. test/btr_downloader_trace_test.dart
// runs the Dart port through the same scripts and expects the same traces.
//
// Usage: node tool/generate_btr_traces.cjs <Bilibili-thread-ripper checkout>
//
// Shared rules (keep in step with test/btr_harness.dart):
// - Time is virtual, in whole milliseconds. Timers due at the same time run in the order
//   they were set; every pending microtask runs before the next timer.
// - A request to a node answers after headMs, then sends chunkBytes every chunkMs. Node
//   settings come from network.default, then network.hosts[host], then the entry of
//   network.requests for that host's nth request.
// - Byte o of the file is (o * 7 + (o >> 9)) & 255.
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');

if (!process.argv[2]) throw new Error('Pass the Bilibili-thread-ripper checkout directory');
const btr = path.resolve(process.argv[2]);
// BTR_FIXTURES points at another directory with a btr_scenarios.json (for trying scenarios out).
const fixtures = process.env.BTR_FIXTURES ? path.resolve(process.env.BTR_FIXTURES) : path.join(__dirname, '..', 'test', 'fixtures');
const input = JSON.parse(fs.readFileSync(path.join(fixtures, 'btr_scenarios.json'), 'utf8'));
const DATE_BASE = 1700000000000;

const byteAt = (o) => (o * 7 + (o >> 9)) & 255;

function merge(defaults, scenario) {
  const network = {
    default: { ...defaults.network.default, ...(scenario.network?.default || {}) },
    hosts: { ...defaults.network.hosts, ...(scenario.network?.hosts || {}) },
    requests: [...defaults.network.requests, ...(scenario.network?.requests || [])],
  };
  return {
    ...defaults,
    ...scenario,
    settings: { ...defaults.settings, ...(scenario.settings || {}) },
    network,
  };
}

async function run(scenario) {
  const events = [];
  let now = 0;
  let timerSeq = 0;
  const timers = new Map();
  const log = (event) => events.push({ t: now, ...event });

  function setTimeout(fn, ms = 0, ...args) {
    const id = ++timerSeq;
    const delay = Math.max(0, Number(ms) || 0);
    timers.set(id, { at: now + delay, seq: id, fn: () => fn(...args) });
    return id;
  }
  function clearTimeout(id) { timers.delete(id); }

  const context = vm.createContext({
    setTimeout, clearTimeout,
    performance: { now: () => now },
    URL, URLSearchParams, AbortController, DOMException, console,
  });
  vm.runInContext(`Date.now = () => ${DATE_BASE} + __virtualNow();`, Object.assign(context, { __virtualNow: () => now }));
  for (const file of ['range-core.js', 'cdn-resolver.js', 'idm-downloader.js']) {
    vm.runInContext(fs.readFileSync(path.join(btr, 'src', file), 'utf8'), context, { filename: file });
  }
  const cdn = context.__BILI_CDN_RESOLVER_FACTORY__;
  const idm = context.__BILI_IDM_DOWNLOADER_FACTORY__;
  // A browser's fetch hands out promises of the page's own realm. Awaiting a promise of
  // another realm costs two extra microtask turns (it is only a thenable there), which
  // would reorder the downloader's own steps, so the fake network uses the sandbox's.
  // eslint-disable-next-line no-shadow
  const { Promise, Uint8Array, TypeError } = vm.runInContext('({ Promise, Uint8Array, TypeError })', context);

  // The scripted network.
  const nth = new Map();
  function behaviour(host) {
    const index = nth.get(host) || 0;
    nth.set(host, index + 1);
    // Every matching entry applies, in order: one host (or "*") and its nth request, or every
    // request from fromNth on.
    const overrides = scenario.network.requests.filter((item) => (item.host === host || item.host === '*')
      && (item.nth === index || (item.fromNth != null && index >= item.fromNth)));
    return Object.assign({}, scenario.network.default, scenario.network.hosts[host] || {}, ...overrides);
  }

  function fakeFetch(url, init) {
    const host = new URL(url).hostname;
    const [, s, x] = /^bytes=(\d+)-(\d+)$/.exec(init.headers.Range).map(Number);
    const b = behaviour(host);
    const signal = init.signal;
    log({ e: 'fetch', host, s, x });
    return new Promise((resolve, reject) => {
      let finished = false;
      let responded = false;
      const own = [];
      const queue = [];
      let ended = false;
      let failure = null;
      let pending = null;
      const settle = () => {
        if (!pending) return;
        const waiter = pending;
        if (failure) { pending = null; waiter.reject(failure); }
        else if (queue.length) { pending = null; waiter.resolve({ done: false, value: queue.shift() }); }
        else if (ended) { pending = null; waiter.resolve({ done: true, value: undefined }); }
      };
      const reader = {
        read() {
          if (failure) return Promise.reject(failure);
          if (queue.length) return Promise.resolve({ done: false, value: queue.shift() });
          if (ended) return Promise.resolve({ done: true, value: undefined });
          return new Promise((res, rej) => { pending = { resolve: res, reject: rej }; });
        },
        cancel() {
          // Aborting the request already errored the body (the abort listener runs first).
          return Promise.resolve();
        },
        releaseLock() {},
      };
      const onAbort = () => {
        if (finished) return;
        finished = true;
        own.forEach(clearTimeout);
        log({ e: 'abort', host, s, x, why: signal.reason?.name || 'AbortError' });
        failure = signal.reason;
        if (!responded) reject(signal.reason);
        else settle();
      };
      if (signal.aborted) { onAbort(); return; }
      signal.addEventListener('abort', onAbort, { once: true });
      own.push(setTimeout(() => {
        responded = true;
        if (b.networkError) {
          finished = true;
          signal.removeEventListener('abort', onAbort);
          reject(new TypeError('Failed to fetch'));
          return;
        }
        const status = b.status ?? 206;
        if (status !== 206) {
          finished = true;
          ended = true;
          resolve({ status, headers: { get: () => null }, body: { getReader: () => reader } });
          return;
        }
        const first = b.badRange ? s + 1 : s;
        const contentRange = `bytes ${first}-${x}/${scenario.fileSize}`;
        const length = x - s + 1;
        const limit = Math.min(length, b.endAfter ?? Infinity, b.stallAfter ?? Infinity);
        let sent = 0;
        const send = () => {
          const size = Math.min(b.chunkBytes, limit - sent);
          const chunk = new Uint8Array(size);
          for (let i = 0; i < size; i += 1) chunk[i] = byteAt(s + sent + i);
          sent += size;
          queue.push(chunk);
          if (sent >= limit && b.stallAfter == null) { ended = true; finished = true; }
          settle();
          if (sent < limit) own.push(setTimeout(send, b.chunkMs));
        };
        if (limit > 0) own.push(setTimeout(send, b.chunkMs));
        else if (b.stallAfter == null) { ended = true; finished = true; }
        resolve({
          status,
          headers: { get: (name) => (name.toLowerCase() === 'content-range' ? contentRange : null) },
          body: { getReader: () => reader },
        });
      }, b.headMs));
    });
  }

  const settings = { ...scenario.settings };
  const downloader = idm.createDownloader({ nativeFetch: fakeFetch, getSettings: () => settings });
  const bans = cdn.createBanList();
  const resolver = cdn.createResolver(scenario.representation, () => scenario.mode, bans, () => scenario.customHosts);

  scenario.calls.forEach((call, c) => {
    const controller = new AbortController();
    setTimeout(() => {
      const range = { start: call.start, end: call.end, length: call.end - call.start + 1 };
      const progressive = call.progressive !== false && call.kind !== 'meta';
      let cursor = call.start;
      let ok = true;
      const options = {
        signal: controller.signal,
        kind: call.kind,
        startup: call.startup === true,
        parallel: call.parallel !== false,
      };
      if (call.deadlineMs != null) options.deadlineMs = call.deadlineMs;
      if (progressive) {
        options.onOrderedChunk = (bytes, piece, total) => {
          let good = piece.start === cursor && bytes.byteLength === piece.length;
          for (let i = 0; good && i < bytes.byteLength; i += 1) good = bytes[i] === byteAt(piece.start + i);
          ok = ok && good;
          cursor += bytes.byteLength;
          log({ e: 'chunk', c, s: piece.start, n: bytes.byteLength, total: total ?? null, good });
        };
      }
      downloader.downloadRange(range, resolver, options).then((result) => {
        let good = ok;
        if (result.bytes) {
          good = result.bytes.byteLength === range.length;
          for (let i = 0; good && i < result.bytes.byteLength; i += 1) good = result.bytes[i] === byteAt(call.start + i);
        } else if (progressive) {
          good = ok && cursor === call.end + 1;
        }
        log({
          e: 'done', c, good,
          byteLength: result.byteLength ?? null,
          pieceCount: result.pieceCount,
          streamed: result.streamed ?? null,
          total: result.total ?? null,
          hosts: result.hosts,
        });
      }, (error) => {
        log({ e: 'fail', c, name: error?.name || 'Error', status: error?.status ?? null });
      });
    }, call.at);
    if (call.abortAt != null) setTimeout(() => controller.abort(), call.abortAt);
  });

  // What the player tells the automatic thread count.
  const auto = idm.autoConcurrency;
  auto.subscribe(({ threads }) => log({ e: 'threads', n: threads }));
  (scenario.signals || []).forEach((signal) => setTimeout(() => {
    if (signal.stall) auto.stall();
    if (signal.buffer) auto.buffer(signal.buffer[0], signal.buffer[1]);
    if (signal.newSession) auto.newSession();
  }, signal.at));

  // Every pending microtask runs before the next timer.
  const drain = () => new Promise((resolve) => setImmediate(resolve));
  while (true) {
    await drain();
    await drain();
    if (!timers.size) break;
    let next = null;
    for (const timer of timers.values()) {
      if (!next || timer.at < next.at || (timer.at === next.at && timer.seq < next.seq)) next = timer;
    }
    if (next.at > scenario.runMs) break;
    timers.delete(next.seq);
    now = next.at;
    next.fn();
  }
  return events;
}

(async () => {
  const traces = [];
  for (const raw of input.scenarios) {
    const scenario = merge(input.defaults, raw);
    const events = await run(scenario);
    traces.push({ name: scenario.name, events });
    const done = events.filter((event) => event.e === 'done' || event.e === 'fail');
    console.log(`${scenario.name}: ${events.length} events, ${done.map((event) => `${event.e}${event.good === false ? '(BAD BYTES)' : ''}`).join(' ')}`);
  }
  fs.writeFileSync(path.join(fixtures, 'btr_traces.json'), JSON.stringify(traces, null, 1) + '\n');
})();
