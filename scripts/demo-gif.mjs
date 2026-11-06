// Makes the README's demo animation from the real app screens in docs/screens/:
// an agent works, the lid closes, the work goes on, the lid opens, a summary waits.
// It's composed, not a screen recording. Needs Chrome and ffmpeg, and
// scripts/screenshots.sh run first. Usage: node scripts/demo-gif.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const chrome = [process.env.CHROME_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
  .filter(Boolean).find(existsSync);
if (!chrome) throw new Error('Chrome not found; set CHROME_PATH');

const WIDTH = 760, HEIGHT = 430;
const CAPTIONS = {
  en: { work: 'Your agent is working', closing: 'Close the lid', away: 'Screen off. Work keeps running', tasks: (n) => `${n} of 3 tasks done`, opening: 'Open the lid', back: 'Everything is back, with a summary' },
  th: { work: 'agent กำลังทำงาน', closing: 'พับจอได้เลย', away: 'จอดับ แต่งานยังเดินต่อ', tasks: (n) => `เสร็จแล้ว ${n} จาก 3 งาน`, opening: 'เปิดจอกลับมา', back: 'ทุกอย่างกลับเหมือนเดิม พร้อมสรุปงาน' },
};
const LINES = ['$ claude "refactor the auth module"', '> Reading src/auth/session.ts', '> Editing 4 files', '> Running the tests…'];

function laptop(angle, done) {
  const lit = angle < 8;
  const terminal = LINES.map((line, i) => `<div style="opacity:${i <= done + 1 ? 1 : 0.25}">${line}</div>`).join('');
  const base = '<div style="position:absolute;left:0;bottom:0;width:340px;height:14px;border-radius:2px 2px 9px 9px;background:linear-gradient(#3a3b40,#222327);box-shadow:0 14px 30px rgba(0,0,0,.6)"></div>';
  // Seen from the front, a closing lid just gets shorter, then lies flat on the base.
  const lid = angle >= 90
    ? '<div style="position:absolute;left:2px;bottom:14px;width:336px;height:7px;border-radius:4px 4px 0 0;background:#44454b"></div>'
    : `<div style="position:absolute;left:20px;bottom:14px;width:300px;height:196px;transform-origin:bottom center;transform:scaleY(${Math.cos((angle * Math.PI) / 180).toFixed(3)});border-radius:10px 10px 2px 2px;background:#26272b;padding:8px;box-shadow:0 0 0 1px rgba(255,255,255,.12)">
      <div style="height:100%;border-radius:4px;background:${lit ? '#0b0d10' : '#050506'};color:#8fe3ab;font:10.5px/1.7 Menlo,monospace;padding:10px 12px;overflow:hidden">${lit ? terminal : ''}</div>
      <div style="position:absolute;top:0;left:50%;margin-left:-22px;width:44px;height:7px;border-radius:0 0 4px 4px;background:#000"></div>
    </div>`;
  return `<div style="position:relative;width:340px;height:236px">${lid}${base}</div>`;
}

function frame({ lang, angle = 0, caption, shot, done = 0, tag = '' }) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    *{box-sizing:border-box} html,body{margin:0;background:#0c0c0e}
    body{width:${WIDTH}px;height:${HEIGHT}px;font:600 19px -apple-system,"Thonburi",sans-serif;color:#fff;overflow:hidden;background:radial-gradient(110% 90% at 30% 0%,#2a2118 0%,#121214 60%,#0c0c0e 100%)}
  </style></head><body>
    <div style="height:64px;display:flex;align-items:center;padding:0 30px;gap:12px"><span>${caption}</span>${tag ? `<span style="font-weight:500;font-size:14px;color:#faa159">${tag}</span>` : ''}</div>
    <div style="display:flex;align-items:center;justify-content:${shot ? 'space-between' : 'center'};height:${HEIGHT - 64}px;padding:0 34px 18px 30px">
      ${laptop(angle, done)}
      ${shot ? `<img src="file://${resolve(`docs/screens/${lang}/${shot}.png`)}" style="height:335px;border-radius:12px;border:1px solid rgba(255,255,255,.1);box-shadow:0 18px 44px rgba(0,0,0,.6)">` : ''}
    </div>
  </body></html>`;
}

for (const lang of ['en', 'th']) {
  const c = CAPTIONS[lang];
  const scenes = [
    { caption: c.work, shot: 'working', done: 0, seconds: 1.1 },
    { caption: c.work, shot: 'working', done: 2, seconds: 1.3 },
    ...[12, 28, 44, 60, 74, 84].map((angle) => ({ caption: c.closing, shot: null, angle, seconds: 0.09 })),
    ...[1, 2, 3].map((n) => ({ caption: c.away, tag: c.tasks(n), shot: null, angle: 90, seconds: 0.9 })),
    ...[84, 74, 60, 44, 28, 12].map((angle) => ({ caption: c.opening, shot: null, angle, seconds: 0.09 })),
    { caption: c.back, shot: 'away', done: 3, seconds: 3.2 },
  ];
  const tmp = mkdtempSync(join(tmpdir(), 'afkpug-demo-'));
  let list = '';
  scenes.forEach((scene, i) => {
    const html = join(tmp, `${i}.html`), png = join(tmp, `${i}.png`);
    writeFileSync(html, frame({ lang, ...scene }));
    execFileSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', '--force-device-scale-factor=1',
      `--window-size=${WIDTH},${HEIGHT}`, `--screenshot=${png}`, `file://${html}`], { stdio: 'ignore' });
    list += `file '${png}'\nduration ${scene.seconds}\n`;
  });
  list += `file '${join(tmp, `${scenes.length - 1}.png`)}'\n`;
  const listFile = join(tmp, 'list.txt');
  writeFileSync(listFile, list);
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', listFile, '-filter_complex',
    '[0:v]fps=12,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4', '-loop', '0', `docs/demo-${lang}.gif`]);
}
console.log('docs/demo-en.gif, docs/demo-th.gif');
