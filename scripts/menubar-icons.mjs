// Makes the README's menu bar icon clips: each state of the A in a slice of the menu bar,
// light and dark. Same glyph and timing as App.swift and Brand.swift, rendered in headless
// Chrome. The moving states become looping AVIFs, the still ones PNGs, in docs/guide/.
// Needs Chrome and ffmpeg built with libsvtav1.
// Usage: node scripts/menubar-icons.mjs
import { execFile, execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const chrome = [process.env.CHROME_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
  .filter(Boolean).find(existsSync);
if (!chrome) throw new Error('Chrome not found; set CHROME_PATH');

const WIDTH = 190, HEIGHT = 34, SCALE = 3, FPS = 30;
// Headless Chrome hangs on very small windows, so it renders into a bigger one and ffmpeg crops.
const WINDOW = [600, 300];
const CROP = `crop=${WIDTH * SCALE}:${HEIGHT * SCALE}:0:0`;
// The page behind the image on GitHub, and the menu bar on top of it.
const THEMES = {
  light: { page: '#ffffff', bar: '#ececef', ink: '#111114' },
  dark: { page: '#0d1117', bar: '#25252b', ink: '#ffffff' },
};
const LEGS = 'M6 26.5 16 5.5l10 21', BAR = 'M9.5 20.5h13';

/** The glyph in a 32 box: legs, and the crossbar at `bar` opacity. */
const glyph = (color, bar) => `<svg width="18" height="18" viewBox="0 0 32 32">
  <path d="${LEGS}" fill="none" stroke="${color}" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/>
  ${bar > 0 ? `<path d="${BAR}" fill="none" stroke="${color}" stroke-opacity="${bar}" stroke-width="4.6" stroke-linecap="round"/>` : ''}</svg>`;

/** Counting down: a 10 px glyph inside a ring that empties clockwise (Brand.swift). */
function ring(color, left) {
  const a = -Math.PI / 2 + 2 * Math.PI * left;
  const arc = left >= 0.9999 ? 'M9 1a8 8 0 1 1 -0.001 0'
    : `M9 1A8 8 0 ${left > 0.5 ? 1 : 0} 1 ${(9 + 8 * Math.cos(a)).toFixed(3)} ${(9 + 8 * Math.sin(a)).toFixed(3)}`;
  return `<svg width="18" height="18" viewBox="0 0 18 18">
    <circle cx="9" cy="9" r="8" fill="none" stroke="${color}" stroke-opacity=".3" stroke-width="1.6"/>
    ${left > 0 ? `<path d="${arc}" fill="none" stroke="${color}" stroke-width="1.6" stroke-linecap="round"/>` : ''}
    <g transform="translate(4 4) scale(${10 / 32})"><path d="${LEGS}" fill="none" stroke="${color}" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="${BAR}" fill="none" stroke="${color}" stroke-width="4.6" stroke-linecap="round"/></g></svg>`;
}

/** Each state: how long one loop lasts (0 for a still), and the icon and text at time t.
 * The text beside the A is off by default (Settings), so the clips leave it out. */
const STATES = {
  // App.swift: 72 frames over 2.4 s, crossbar 0.6 + 0.4 cos.
  working: { loop: 2.4, at: (c, t) => [glyph(c.ink, 0.6 + 0.4 * Math.cos((Math.round(t * FPS) % 72) / 72 * 2 * Math.PI)), ''] },
  // Brand.swift waitingBadge: a red badge with a white A and "Needs you", full then dim, 0.6 s each.
  // It has words in it, so there is one clip per language.
  ...Object.fromEntries(Object.entries({ en: 'Needs you', th: 'รอคุณ' }).map(([lang, text]) => [`waiting-${lang}`, {
    loop: 1.2, at: () => [''],
    badge: (t) => `<span class="badge" style="opacity:${Math.floor(t / 0.6 + 1e-6) % 2 === 0 ? 1 : 0.55}">${glyph('#ffffff', 1)}<b>${text}</b></span>`,
  }])),
  // Five minutes shown in six seconds.
  countdown: {
    loop: 6, at: (c, t) => {
      return [ring(c.ink, 1 - t / 6), ''];
    },
  },
  on: { loop: 0, at: (c) => [glyph(c.ink, 1), ''] },
  off: { loop: 0, at: (c) => [glyph(c.ink, 0), ''] },
};

const wifi = (color) => `<svg width="15" height="15" viewBox="0 0 24 24"><path d="M2 9a15 15 0 0 1 20 0M5.5 12.5a10 10 0 0 1 13 0M9 16a5 5 0 0 1 6 0" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="19.5" r="1.5" fill="${color}"/></svg>`;

function page(c, icon, text = '') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;overflow:hidden;background:${c.page}} .slice{position:relative;width:${WIDTH}px;height:${HEIGHT}px}
  .bar{position:absolute;inset:4px 4px;border-radius:7px;background:${c.bar};display:flex;align-items:center;justify-content:flex-end;gap:12px;padding:0 11px;
    color:${c.ink};font:500 13px -apple-system,system-ui,sans-serif;font-variant-numeric:tabular-nums}
  .a{display:flex;align-items:center;gap:4px}
  .badge{flex:none;white-space:nowrap;display:inline-flex;align-items:center;gap:4px;height:18px;padding:0 6px;border-radius:5px;background:#e5141f;color:#fff;font:600 12px -apple-system,"Thonburi",system-ui,sans-serif}
  .badge svg{flex:none;width:12px;height:12px} .w{opacity:.85;display:flex}
  </style></head><body><div class="slice"><div class="bar"><span class="w">${wifi(c.ink)}</span><span class="a">${icon}<span>${text}</span></span><span>9:41</span></div></div></body></html>`;
}

async function shoot(html, png, tmp, index, worker) {
  const file = join(tmp, `${index}.html`);
  writeFileSync(file, html);
  for (let attempt = 1; ; attempt++) {
    try { return await shootOnce(file, png, tmp, worker); } catch (error) {
      if (attempt >= 3) throw error;
    }
  }
}

function shootOnce(file, png, tmp, worker) {
  return new Promise((done, fail) => {
    execFile(chrome, ['--headless=new', '--hide-scrollbars', `--force-device-scale-factor=${SCALE}`,
      `--user-data-dir=${join(tmp, `profile-${worker}`)}`, `--window-size=${WINDOW.join(',')}`, `--screenshot=${png}`, `file://${file}`],
    { timeout: 30_000, killSignal: 'SIGKILL' }, (error) => (error ? fail(error) : done()));
  });
}

const WORKERS = 6;
for (const [theme, colors] of Object.entries(THEMES)) {
  for (const [name, state] of Object.entries(STATES)) {
    const tmp = mkdtempSync(join(tmpdir(), 'afkpug-menubar-'));
    const out = `docs/guide/menu-${name}-${theme}`;
    if (!state.loop) {
      await shoot(page(colors, ...state.at(colors, 0)), join(tmp, 'still.png'), tmp, 0, 0);
      execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', join(tmp, 'still.png'), '-vf', CROP, `${out}.png`]);
    } else {
      const total = Math.round(state.loop * FPS);
      let next = 0;
      await Promise.all(Array.from({ length: WORKERS }, async (_, worker) => {
        while (next < total) {
          const i = next++;
          const html = state.badge ? page(colors, state.badge(i / FPS)) : page(colors, ...state.at(colors, i / FPS));
          await shoot(html, join(tmp, `f${String(i).padStart(4, '0')}.png`), tmp, i, worker);
        }
      }));
      execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', join(tmp, 'f%04d.png'),
        '-vf', `${CROP},scale=out_color_matrix=bt709,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv`, '-c:v', 'libsvtav1', '-crf', '24', '-preset', '6', '-loop', '0', `${out}.avif`]);
    }
    rmSync(tmp, { recursive: true, force: true });
    console.log(out);
  }
}
