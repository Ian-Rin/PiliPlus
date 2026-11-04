// Usage: node tool/generate_ripper_resolver_fixture.cjs <Bilibili-thread-ripper checkout>
// The checkout may be a relative path. Fixtures are written to this package's test/fixtures.
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');
if (!process.argv[2]) throw new Error('Pass the Bilibili-thread-ripper checkout directory');
const root = path.resolve(process.argv[2]);
const out = (name) => path.join(__dirname, '..', 'test', 'fixtures', name);
let now = 100000;
Date.now = () => now;
require(path.join(root, 'src/range-core.js'));
require(path.join(root, 'src/cdn-resolver.js'));
const factory = globalThis.__BILI_CDN_RESOLVER_FACTORY__;
const representation = {
  baseUrl: 'https://video.akamaized.net/v.m4s?sign=a%2Bb',
  backupUrl: ['https://upos-sz-mirroraliov.bilivideo.com/v.m4s?sign=a%2Bb'],
};
const fixtures = [];
// The custom mode keeps to the picked servers: more of them than a segment uses, so its
// warm-up and its startup candidates show.
const picked = ['upos-sz-mirrorcos.bilivideo.com', 'upos-sz-mirrorhw.bilivideo.com', 'upos-sz-mirrorbos.bilivideo.com',
  'cn-hk-eq-01-03.bilivideo.com', 'upos-sz-mirror08c.bilivideo.com', 'upos-sz-mirrorbd.bilivideo.com',
  'upos-sz-mirror14b.bilivideo.com'];
for (const [mode, customHosts] of [['overseas', []], ['mainland', []], ['custom', picked]]) {
  const bans = factory.createBanList();
  const resolver = factory.createResolver(representation, () => mode, bans, () => customHosts);
  const urls = factory.representationUrls(representation, mode, customHosts);
  const steps = [];
  function record(op, args=[]) {
    const result = resolver[op](...args);
    steps.push({op,args,...(result === undefined ? {} : {expected:result})});
  }
  record('startupCandidates');
  record('rangeCandidates');
  record('success', [urls.at(-1), 900000]);
  record('success', [urls[0], 400000]);
  record('rescueCandidates');
  for(let i=0;i<7;i++) record('rangeCandidates');
  for(let i=0;i<5;i++) record('ordered',[i]);
  record('failure',[urls[0], {status:403}, 0]);
  record('failure',[urls[0], {status:403}, 0]);
  record('rescueCandidates');
  record('rangeCandidates');
  record('startupCandidates');
  record('sample', [urls.at(-1), 1500000]);
  record('speed', [urls.at(-1)]);
  steps.push({op:'advance',args:[90001]});
  now += 90001;
  record('speed', [urls.at(-1)]);
  record('rangeCandidates');
  fixtures.push({mode, customHosts, representation, urls, steps});
}
fs.writeFileSync(out('ripper_resolver.json'), JSON.stringify(fixtures,null,2)+'\n');

// Candidate lists for many address mixes: ordinary, akamaized.net, relays (mcdn hosts,
// /v1/resource/ paths, os=mcdn), peer ports, duplicates and addresses that are not media.
const signed = '/upgcxcode/12/34/567/567-1-30080.m4s?e=ig8euxZM&os=upos&sign=a%2Bb';
const relayMcdn = 'https://xy1x2x3x4xy.mcdn.bilivideo.cn:4483/upgcxcode/12/34/567/567-1-30080.m4s?e=r&os=mcdn&sign=r1';
const relayPath = 'https://ab12.mountaintoys.cn/v1/resource/abcdef/567-1-30080.m4s?sign=r2';
const relayQuery = 'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/12/34/567/567-1-30080.m4s?os=MCDN&sign=r3';
// Each relay rule alone: an mcdn host without os=mcdn and without a /v1/resource/ path.
const relayHostOnly = 'https://xy5x6x7x8xy.mcdn.bilivideo.cn:4483/upgcxcode/12/34/567/567-1-30080.m4s?e=r&sign=r4';
const addressMixes = {
  ordinary: [`https://upos-sz-mirrorali.bilivideo.com${signed}`, `https://upos-sz-mirroraliov.bilivideo.com${signed}`],
  akamaiOnly: [`https://upos-hz-mirrorakam.akamaized.net${signed}`, `https://upos-sz-mirrorakam2.akamaized.net${signed}`],
  relayThenOrdinary: [relayMcdn, `https://upos-sz-mirrorcos.bilivideo.com${signed}`],
  relaysOnly: [relayMcdn, relayPath],
  relayByQueryOnly: [relayQuery],
  relayByHostThenOrdinary: [relayHostOnly, `https://upos-sz-mirrorcos.bilivideo.com${signed}`],
  akamaiAndRelay: [`https://upos-hz-mirrorakam.akamaized.net${signed}`, relayMcdn],
  peerPortAndNewMainland: [`https://xy1.szbdyd.com:4483${signed}`, `https://upos-sz-mirrorcoso1.bilivideo.com${signed}`],
  duplicatesAndJunk: [`https://upos-sz-mirrorali.bilivideo.com${signed}`, `https://upos-sz-mirrorali.bilivideo.com${signed}`,
    'https://example.com/v.m4s', `http://upos-sz-mirrorhw.bilivideo.com${signed}`, 'https://upos-sz-mirrorhw.bilivideo.com/x.json'],
  upperCaseHost: [`https://UPOS-SZ-MIRRORALI.bilivideo.com${signed}`],
};
const regions = [
  { mode: 'overseas', customHosts: [] },
  { mode: 'mainland', customHosts: [] },
  { mode: 'custom', customHosts: ['upos-sz-mirrorcos.bilivideo.com', 'cn-hk-eq-01-03.bilivideo.com'] },
];
const candidates = [];
for (const [name, originals] of Object.entries(addressMixes)) {
  for (const { mode, customHosts } of regions) {
    const [baseUrl, ...backupUrl] = originals;
    const expected = factory.representationUrls({ baseUrl, backupUrl }, mode, customHosts);
    candidates.push({ name, mode, customHosts, originals, expected });
  }
}
fs.writeFileSync(out('ripper_candidates.json'), JSON.stringify(candidates,null,2)+'\n');

// Expose the unchanged upstream assignment function only in this test VM.
const source = fs.readFileSync(path.join(root, 'src/idm-downloader.js'), 'utf8');
const marker = 'return Object.freeze({ downloadRange, applySettings, getConcurrency: () => semaphore.limit });';
if (!source.includes(marker)) throw new Error('Upstream downloader shape changed: review fixture generator');
vm.runInThisContext(source.replace(marker, 'return { assignPrimaries };'));
const downloader = globalThis.__BILI_IDM_DOWNLOADER_FACTORY__.createDownloader({getSettings:()=>({concurrency:8})});
const weighted = [];
// The last two put nodes between a twelfth and a tenth of the fastest (still assigned).
for (const speeds of [[0,0,0,0], [1200000,600000,10000,0], [900000,300000,0,0], [100000,100000,100000,100000],
  [1100000,100000,0,500000], [1200000,110000,105000,0,0]]) {
  const urls = speeds.map((_,i)=>`https://node${i}.bilivideo.com/v.m4s`);
  const resolver = {speed: url => speeds[urls.indexOf(url)]};
  const steps = [2,2,2,2,8,16].map(count=>({count,expected:downloader.assignPrimaries(urls,resolver,count)}));
  weighted.push({urls,speeds,steps});
}
fs.writeFileSync(out('ripper_assignments.json'), JSON.stringify(weighted,null,2)+'\n');

const autoScenarios = [];
function scenario(name, run) {
  let clock = 5000;
  const auto = globalThis.__BILI_IDM_DOWNLOADER_FACTORY__.createAutoConcurrency({now:()=>clock});
  const steps = [];
  function act(op, args=[], advance=0) {
    clock += advance;
    auto[op](...args);
    steps.push({at:clock,op,args,threads:auto.threads()});
  }
  run(act, auto);
  autoScenarios.push({name,steps});
}
scenario('trials, pressure and rate limits', (act, auto) => {
  function flow(bps, duration) {
    act('demand',[auto.threads(), auto.threads(), 12]);
    for (let i=0;i<duration;i+=250) {
      act('activity',[],250);
      act('delivered',[bps/4]);
    }
  }
  flow(1000000,5000);
  act('stall');
  flow(950000,11000); // Fruitless trial returns to eight and rests twelve.
  act('stall',[],3000); // A stall can skip the resting level.
  flow(1500000,11000);
  act('pushback',[429]);
  act('stall',[],3000); // A refusal cannot be skipped.
  act('stall',[],180001);
  act('newSession');
  for (let i=0;i<12;i++) {
    act('activity',[],250);
    act('buffer',[4-i*.1,true]);
  }
});
scenario('a start runs at 16 threads and steps back once ahead', (act) => {
  act('newSession');
  for (let i=0;i<4;i++) act('buffer',[3+i,true],500);
  act('buffer',[16,true],400); // Still within the cooldown of the start.
  act('buffer',[16,true],200);
  act('buffer',[16,true],1000);
  act('buffer',[14,true],1600); // Not ahead enough.
  act('buffer',[15,true],100);
  act('buffer',[20,true],2500); // Already back at its base.
  act('newSession');
});
scenario('a stall during the start climbs and ends it', (act) => {
  act('newSession');
  act('stall',[],2600);
  act('buffer',[20,true],2600);
  act('buffer',[20,true],2600);
});
scenario('a start that never catches up keeps its threads', (act) => {
  act('newSession');
  for (let i=0;i<31;i++) act('buffer',[5,true],1000);
  act('buffer',[20,true],1000);
  act('newSession');
});
scenario('refusals cap the start and a restart keeps its base', (act) => {
  act('pushback',[429]);
  act('newSession'); // Eight itself was refused.
  act('newSession',[],180001);
  act('pushback',[429],2600);
  act('buffer',[20,true],2600);
  act('newSession'); // Sixteen is refused for a while; twelve is not.
  act('newSession',[],1000);
  act('buffer',[20,true],2000);
  act('buffer',[20,true],600);
});
scenario('stalls climb the ladder to 64 and stop there', (act) => {
  for (let i=0;i<8;i++) act('stall',[],3000);
});
fs.writeFileSync(out('ripper_auto.json'),JSON.stringify(autoScenarios,null,2)+'\n');
