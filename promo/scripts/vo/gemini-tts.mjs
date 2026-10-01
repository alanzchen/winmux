// OPTIONAL: regenerate narration takes with Google Gemini TTS on Vertex AI. The default build never
// calls this: it uses the approved masters committed in vo/. You need your own Google Cloud access.
//
// Configuration comes only from the environment (nothing is read from or written to fixed paths):
//   PROMO_TTS_KEY_FILE   path to a file that contains your API key (read in-process, never printed)
//   PROMO_TTS_BASE_URL   your Vertex AI publisher URL, ending in .../publishers/google. It must be
//                        https on aiplatform.googleapis.com or <region>-aiplatform.googleapis.com.
//   PROMO_TTS_MODEL      default gemini-3.1-flash-tts-preview
//   PROMO_TTS_VOICE      default Kore
//
// SECRET HANDLING: the key is read only after the endpoint passes the checks above, and is sent only
// as the x-goog-api-key header, with redirects refused. It is never printed, logged, written, or put
// in argv. The endpoint URL and request headers are never logged. On failure only the HTTP status
// and the API's error message are printed.
//
// Usage:
//   node scripts/vo/gemini-tts.mjs --check               # validate the configuration (booleans only)
//   node scripts/vo/gemini-tts.mjs --lines L03,L16       # synthesize the given lines
//   node scripts/vo/gemini-tts.mjs --lines all
//   node scripts/vo/gemini-tts.mjs --lines L10 --take brisk   # a retake with a brisker pace note
//   node scripts/vo/gemini-tts.mjs --dry-run --lines L03 # print the prompt text only (no key, no request)
// Output: $PROMO_BUILD_DIR/tts/<id>[.take-N].wav (native 24 kHz 16-bit mono) and a request ledger beside them.
// Review takes by ear, then copy the approved ones to vo/<id>.wav.
import fs from 'node:fs';
import path from 'node:path';
import { BUILD, ROOT as root } from '../paths.mjs';

const MODEL = process.env.PROMO_TTS_MODEL || 'gemini-3.1-flash-tts-preview';
const VOICE = process.env.PROMO_TTS_VOICE || 'Kore';
const BUDGET_TOTAL = 60;
const MAX_TAKES_PER_LINE = 4; // first take + up to 3 retakes

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };

const narration = JSON.parse(fs.readFileSync(path.join(root, 'cues/narration.json'), 'utf8'));
const outDir = path.join(BUILD, 'tts');
const ledgerPath = path.join(outDir, 'ledger.json');
const ledger = fs.existsSync(ledgerPath) ? JSON.parse(fs.readFileSync(ledgerPath, 'utf8')) : { requests: [] };

function loadConfig() {
  return { baseUrl: process.env.PROMO_TTS_BASE_URL || null, model: MODEL, voice: VOICE, keyFile: process.env.PROMO_TTS_KEY_FILE || null };
}

// The key may only go to Vertex AI over https: no other host, no credentials, query or fragment.
function vertexUrl(raw) {
  let u;
  try { u = new URL(raw); } catch { return null; }
  const vertexHost = u.hostname === 'aiplatform.googleapis.com' || /^[a-z0-9-]+-aiplatform\.googleapis\.com$/.test(u.hostname);
  return u.protocol === 'https:' && vertexHost && !u.port && !u.username && !u.password && !u.search && !u.hash ? u : null;
}

function prompt(line, take) {
  const emphasis = line.emphasis?.length ? `Lean gently on: ${line.emphasis.map((e) => `"${e}"`).join(', ')}.` : '';
  const pace = take === 'brisk'
    ? 'Pacing: a touch brisker than relaxed, about 165 words per minute, still calm and clear, with short natural pauses.'
    : 'Pacing: unhurried, about 150 words per minute, with natural pauses at periods and lighter pauses at commas.';
  return [
    '# AUDIO PROFILE: The narrator of a short product film for WinMux, a window manager for the Mac.',
    '## THE SCENE: A calm, polished product introduction, spoken over gentle music.',
    '### DIRECTOR\'S NOTES',
    'Style: warm, confident, unhurried; friendly expertise with a smile in the voice, never salesy.',
    'Accent: neutral American English.',
    pace,
    'Pronunciation: "WinMux" is said "WIN-mux", two syllables, stress on WIN; "mux" rhymes with "tux". Never spell it out.',
    emphasis,
    'Read only the transcript below, exactly as written. Do not add or read any other words.',
    '#### TRANSCRIPT',
    line.text,
  ].filter(Boolean).join('\n');
}

function wavFromPcm16(pcm, rate) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

// Gemini returns audio/L16. In practice the bytes are little-endian; verify by comparing the
// sample-to-sample smoothness of both interpretations (speech is smooth, byte-swapped audio is not).
function toLittleEndian(pcm) {
  const n = Math.floor(pcm.length / 2);
  let dLE = 0, dBE = 0, prevLE = 0, prevBE = 0;
  for (let i = 0; i < n; i++) {
    const le = pcm.readInt16LE(i * 2), be = pcm.readInt16BE(i * 2);
    dLE += Math.abs(le - prevLE); dBE += Math.abs(be - prevBE); prevLE = le; prevBE = be;
  }
  if (dBE < dLE * 0.5) { // big-endian looks far smoother: swap
    const out = Buffer.alloc(n * 2);
    for (let i = 0; i < n; i++) out.writeInt16LE(pcm.readInt16BE(i * 2), i * 2);
    return { pcm: out, swapped: true };
  }
  return { pcm, swapped: false };
}

async function synthesize(cfg, key, line, take) {
  const url = `${cfg.baseUrl.replace(/\/+$/, '')}/models/${cfg.model}:generateContent`;
  const body = {
    contents: [{ role: 'user', parts: [{ text: prompt(line, take) }] }],
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: cfg.voice } } },
    },
  };
  let res;
  try {
    res = await fetch(url, { method: 'POST', redirect: 'error', headers: { 'x-goog-api-key': key, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  } catch (e) {
    return { ok: false, status: 0, message: `network error: ${e?.cause?.code ?? e?.name ?? 'unknown'}` };
  }
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* non-JSON body */ }
  if (!res.ok) {
    const message = json?.error?.message ?? json?.[0]?.error?.message ?? `HTTP ${res.status}`;
    const statusName = json?.error?.status ?? json?.[0]?.error?.status ?? '';
    return { ok: false, status: res.status, statusName, message };
  }
  const parts = json?.candidates?.[0]?.content?.parts ?? [];
  const audio = parts.filter((p) => p.inlineData?.data);
  if (!audio.length) return { ok: false, status: res.status, message: `no audio in response (finishReason ${json?.candidates?.[0]?.finishReason ?? '?'})` };
  const mimeType = audio[0].inlineData.mimeType ?? '';
  const rate = Number(/rate=(\d+)/i.exec(mimeType)?.[1] ?? 24000);
  if (!/L16|pcm/i.test(mimeType)) return { ok: false, status: res.status, message: `unexpected audio mimeType ${mimeType}` };
  const raw = Buffer.concat(audio.map((p) => Buffer.from(p.inlineData.data, 'base64')));
  const { pcm, swapped } = toLittleEndian(raw);
  return { ok: true, status: res.status, mimeType, rate, pcm, swapped, usage: json?.usageMetadata ?? null };
}

async function main() {
  if (flag('--dry-run')) {
    const ids = (opt('--lines', 'L03')).split(',');
    for (const l of narration.lines.filter((x) => ids.includes(x.id))) console.log(`--- ${l.id}\n${prompt(l, opt('--take'))}\n`);
    return;
  }
  const cfg = loadConfig();
  const checks = {
    baseUrlPresent: !!cfg.baseUrl,
    baseUrlIsHttpsVertex: !!cfg.baseUrl && !!vertexUrl(cfg.baseUrl),
    model: cfg.model,
    voice: cfg.voice,
    keyFilePresent: !!cfg.keyFile && fs.existsSync(cfg.keyFile),
  };
  if (flag('--check')) { console.log(JSON.stringify(checks, null, 2)); return; }
  if (!checks.baseUrlPresent || !checks.keyFilePresent) {
    console.error('configuration incomplete: set PROMO_TTS_BASE_URL and PROMO_TTS_KEY_FILE'); process.exit(2);
  }
  if (!checks.baseUrlIsHttpsVertex) {
    console.error('PROMO_TTS_BASE_URL must be an https URL on aiplatform.googleapis.com or <region>-aiplatform.googleapis.com'); process.exit(2);
  }
  if (!/^[A-Za-z0-9._-]+$/.test(cfg.model)) { console.error('PROMO_TTS_MODEL has unexpected characters'); process.exit(2); }
  const want = opt('--lines', '');
  const ids = want === 'all' ? narration.lines.map((l) => l.id) : want.split(',').filter(Boolean);
  const lines = narration.lines.filter((l) => ids.includes(l.id));
  if (!lines.length) { console.error('no lines selected'); process.exit(2); }
  const take = opt('--take');
  const key = fs.readFileSync(cfg.keyFile, 'utf8').trim(); // in-process only
  fs.mkdirSync(outDir, { recursive: true });
  for (const line of lines) {
    const used = ledger.requests.length;
    if (used >= BUDGET_TOTAL) { console.error(`budget reached (${used}/${BUDGET_TOTAL} requests); stopping`); break; }
    const takes = ledger.requests.filter((r) => r.line === line.id).length;
    if (takes >= MAX_TAKES_PER_LINE) { console.error(`${line.id}: take limit reached (${takes}); skipping`); continue; }
    const t0 = Date.now();
    const r = await synthesize(cfg, key, line, take);
    const entry = { line: line.id, take: take ?? 'default', at: new Date().toISOString(), status: r.status, ms: Date.now() - t0 };
    if (!r.ok) {
      entry.error = r.message; entry.errorStatus = r.statusName ?? '';
      ledger.requests.push(entry);
      fs.writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2));
      console.error(`${line.id}: FAILED status ${r.status} ${r.statusName ?? ''}: ${r.message}`);
      if (r.status === 429 || /RESOURCE_EXHAUSTED|quota/i.test(`${r.statusName} ${r.message}`)) { console.error('quota/rate limit: stopping, no retries'); process.exit(3); }
      continue;
    }
    const n = ledger.requests.filter((x) => x.line === line.id && x.file).length;
    const file = `${line.id}${n ? `.take-${n + 1}` : ''}.wav`;
    fs.writeFileSync(path.join(outDir, file), wavFromPcm16(r.pcm, r.rate));
    Object.assign(entry, { file, mimeType: r.mimeType, rate: r.rate, bytes: r.pcm.length, seconds: +(r.pcm.length / 2 / r.rate).toFixed(3), byteSwapped: r.swapped });
    ledger.requests.push(entry);
    fs.writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2));
    console.log(`${line.id}: ok ${file} ${entry.seconds}s ${r.mimeType}${r.swapped ? ' (byte-swapped)' : ''}`);
    await new Promise((res) => setTimeout(res, 800));
  }
  console.log(`requests used: ${ledger.requests.length}/${BUDGET_TOTAL}`);
}
main().catch((e) => { console.error('tts script error:', e?.message ?? e); process.exit(1); });
