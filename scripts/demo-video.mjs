// Makes the README's demo video: a MacBook drawn in CSS 3D showing the real app screens
// from docs/screens/. It's an animation, not a screen recording. Every frame is a pure
// function of time, rendered in headless Chrome, then encoded with ffmpeg.
// Needs Chrome, ffmpeg and img2webp (brew install webp), and scripts/screenshots.sh run first.
// Usage: node scripts/demo-video.mjs [en|th] [--still <seconds>]
import { execFile, execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { cpus, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const chrome = [process.env.CHROME_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
  .filter(Boolean).find(existsSync);
if (!chrome) throw new Error('Chrome not found; set CHROME_PATH');

const WIDTH = 1280, HEIGHT = 720, FPS = 60, DURATION = 21;
const WEBP_FPS = 30, WEBP_WIDTH = 960;
const CAPTIONS = {
  en: {
    start: 'Your agents are working', watch: 'See every job and its current step', close: 'Close the lid',
    away: 'Screen off. Work keeps running', done: (n) => `${n} of 3 jobs done`, open: 'Open it when you’re ready',
    back: 'Everything is back, with a summary', tag: 'Close the lid. Your agents keep running.',
    note: 'Animation made from the app’s screens',
  },
  th: {
    start: 'agent กำลังทำงาน', watch: 'เห็นทุกงานและขั้นตอนปัจจุบัน', close: 'พับจอได้เลย',
    away: 'จอดับ แต่งานยังเดินต่อ', done: (n) => `เสร็จแล้ว ${n} จาก 3 งาน`, open: 'กลับมาเปิดเมื่อพร้อม',
    back: 'ทุกอย่างกลับมา พร้อมสรุปงาน', tag: 'พับจอได้เลย agent ยังทำงานต่อ',
    note: 'แอนิเมชันจากหน้าจอจริงของแอป',
  },
};
const TERMINAL = ['$ claude "fix the failing payment tests"', '> Reading src/checkout.ts', '> Editing 4 files', '> Running the tests…', '✓ 128 passed'];

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const smooth = (v) => { const x = clamp(v); return x * x * x * (x * (x * 6 - 15) + 10); };
/** 0 before `a`, 1 after `b`, eased between. */
const span = (t, a, b) => smooth((t - a) / (b - a));
const lerp = (a, b, k) => a + (b - a) * k;

function frame(lang, t) {
  const c = CAPTIONS[lang];
  const shot = (name) => `file://${resolve(`docs/screens/${lang}/${name}.png`)}`;
  const icon = `file://${resolve('docs/icon.png')}`;

  // Lid: 0 is open, 1 is shut. Closes at 7.6-9.2 s, opens at 13.2-14.8 s.
  const lid = span(t, 7.6, 9.2) * (1 - span(t, 13.2, 14.8));
  // CSS: a positive angle leans the lid back, -90 lays it flat on the base.
  const hinge = lerp(16, -89.5, lid);
  const screenOn = (1 - span(lid, 0.25, 0.75));

  // Camera: pushes in on the panel, pulls back for the lid, drifts on the closed Mac.
  const zoomIn = span(t, 2.6, 3.6) * (1 - span(t, 6.6, 7.6)) + 0.75 * span(t, 15.2, 16.1) * (1 - span(t, 18.0, 18.8));
  const scale = lerp(0.74, 1.3, zoomIn);
  const shiftX = lerp(0, -350, zoomIn);
  const shiftY = lerp(30, 185, zoomIn) - 175 * lid;
  const tilt = lerp(-13, -3, zoomIn) - 27 * lid;
  const spin = Math.sin(t * 0.33) * (1 - zoomIn) * 3.5;

  // What's on the screen.
  const panelIn = span(t, 1.5, 2.1) * (1 - span(t, 6.9, 7.3));
  const awayIn = span(t, 14.7, 15.2);
  const panelOpacity = Math.max(panelIn, awayIn);
  const panelSrc = t > 10 ? shot('away') : shot('working');
  const typed = Math.floor(clamp((t - 0.3) / 1.1) * 3) + (t > 8 ? 2 : 0);
  const terminal = TERMINAL.map((line, i) => `<div style="opacity:${i < typed ? 1 : 0}">${line}</div>`).join('');

  // Under the closed lid: a soft pulse, and jobs finishing one by one.
  const doneCount = t < 10.4 ? 0 : t < 11.3 ? 1 : t < 12.2 ? 2 : 3;
  const statusIn = span(t, 9.5, 10) * (1 - span(t, 12.9, 13.2));
  const pulse = 0.55 + 0.45 * Math.sin(t * 3);

  // Captions.
  const cues = [
    [0.2, 2.5, c.start], [2.7, 6.6, c.watch], [6.9, 9.3, c.close], [9.4, 13.1, c.away],
    [13.3, 15, c.open], [15.2, 18.2, c.back],
  ];
  const captions = cues.map(([a, b, text]) => {
    const o = span(t, a, a + 0.35) * (1 - span(t, b - 0.3, b));
    const y = lerp(10, 0, span(t, a, a + 0.45));
    return o > 0 ? `<div class="cap" style="opacity:${o};transform:translateX(-50%) translateY(${y}px)">${text}</div>` : '';
  }).join('');

  // End card.
  const end = span(t, 18.5, 19.2);
  const endScale = lerp(0.94, 1, end);

  const dots = [0, 1, 2].map((i) => `<i class="${i < doneCount ? 'on' : ''}"></i>`).join('');

  return `<!doctype html><html><head><meta charset="utf-8"><style>
  *{box-sizing:border-box} html,body{margin:0;width:${WIDTH}px;height:${HEIGHT}px;overflow:hidden;background:#07070a;
    font-family:-apple-system,"SF Pro Display","Thonburi",sans-serif;color:#f5f5f7;-webkit-font-smoothing:antialiased}
  .bg{position:absolute;inset:0;background:radial-gradient(70% 62% at 50% 34%,#2b2c34 0%,#141419 52%,#07070a 100%)}
  .floor{position:absolute;left:0;right:0;bottom:0;height:300px;background:linear-gradient(transparent,rgba(255,255,255,.035))}
  .stage{position:absolute;left:50%;top:50%;width:0;height:0;perspective:2600px}
  .cam{position:absolute;transform-style:preserve-3d;transform:translate(${shiftX}px,${shiftY}px) scale(${scale}) rotateX(${tilt}deg) rotateY(${spin}deg)}
  .shadow{position:absolute;left:-520px;top:132px;width:1040px;height:640px;background:radial-gradient(50% 50% at 50% 50%,rgba(0,0,0,.8),transparent 72%);transform-origin:50% 0;transform:translateY(12px) rotateX(90deg)}
  /* Base */
  .base{position:absolute;left:-385px;top:128px;width:770px;height:520px;transform-origin:50% 0;transform:rotateX(90deg);transform-style:preserve-3d;
    border-radius:4px 4px 26px 26px;background:linear-gradient(180deg,#b9bbc0 0%,#a7a9ae 100%);box-shadow:inset 0 0 0 1px rgba(255,255,255,.25)}
  .keys{position:absolute;left:52px;right:52px;top:30px;height:262px;border-radius:9px;background:#17181b;
    background-image:linear-gradient(#26272b 1px,transparent 1px),linear-gradient(90deg,#26272b 1px,transparent 1px);background-size:44.5px 44px;
    box-shadow:inset 0 2px 7px rgba(0,0,0,.9)}
  .pad{position:absolute;left:230px;right:230px;top:310px;height:185px;border-radius:12px;background:linear-gradient(180deg,#b3b5ba,#a2a4a9);box-shadow:inset 0 0 0 1px rgba(0,0,0,.14),inset 0 1px 0 rgba(255,255,255,.4)}
  .edge{position:absolute;left:-385px;top:128px;width:770px;height:12px;border-radius:0 0 16px 16px;background:linear-gradient(#a0a2a7,#5d5e62);transform:translateZ(520px)}
  /* Lid */
  .lid{position:absolute;left:-385px;top:-372px;width:770px;height:500px;transform-origin:50% 100%;transform:rotateX(${hinge}deg);transform-style:preserve-3d}
  .face{position:absolute;inset:0;border-radius:22px 22px 4px 4px;background:#0a0a0c;box-shadow:inset 0 0 0 2px #2a2b2f,inset 0 0 0 9px #050506;backface-visibility:hidden;overflow:hidden}
  .back{position:absolute;inset:0;border-radius:22px 22px 4px 4px;background:radial-gradient(90% 80% at 40% 20%,#dfe1e5,#b4b6bb 55%,#94969b);transform:rotateY(180deg);backface-visibility:hidden}
  .notch{position:absolute;left:50%;top:9px;margin-left:-46px;width:92px;height:18px;border-radius:0 0 10px 10px;background:#050506;z-index:6}
  .display{position:absolute;inset:9px 9px 11px;border-radius:13px 13px 2px 2px;overflow:hidden;background:radial-gradient(90% 90% at 70% 12%,#3b3a55 0%,#1b1b2c 45%,#0c0c13 100%);opacity:${screenOn}}
  .bar{position:absolute;left:0;right:0;top:0;height:24px;background:rgba(0,0,0,.34);display:flex;align-items:center;justify-content:flex-end;gap:13px;padding:0 12px;font-size:11px;font-weight:500}
  .bar .a{display:flex;width:22px;height:18px;align-items:center;justify-content:center;border-radius:4px;background:rgba(255,255,255,${panelOpacity > 0.05 ? 0.24 : 0})}
  .term{position:absolute;left:30px;top:66px;width:345px;height:206px;border-radius:9px;background:rgba(9,10,14,.9);box-shadow:0 18px 40px rgba(0,0,0,.5),inset 0 0 0 1px rgba(255,255,255,.08);padding:30px 14px;font:11.5px/1.75 Menlo,monospace;color:#b9f2cc}
  .term:before{content:"";position:absolute;left:12px;top:11px;width:9px;height:9px;border-radius:50%;background:#ff5f57;box-shadow:15px 0 #febc2e,30px 0 #28c840}
  .panel{position:absolute;right:13px;top:29px;width:206px;border-radius:13px;overflow:hidden;box-shadow:0 24px 50px rgba(0,0,0,.65),0 0 0 1px rgba(255,255,255,.12);
    opacity:${panelOpacity};transform:translateY(${lerp(-10, 0, panelOpacity)}px) scale(${lerp(0.97, 1, panelOpacity)});transform-origin:100% 0}
  .panel img{display:block;width:100%}
  .cap{position:absolute;left:50%;bottom:34px;white-space:nowrap;font-size:26px;font-weight:600;letter-spacing:-.01em;padding:10px 22px;border-radius:999px;background:rgba(10,10,14,.72);box-shadow:inset 0 0 0 1px rgba(255,255,255,.1)}
  .status{position:absolute;left:50%;top:94px;transform:translateX(-50%);display:flex;align-items:center;gap:14px;padding:13px 22px;border-radius:999px;font-size:21px;font-weight:600;
    background:rgba(255,255,255,.07);box-shadow:inset 0 0 0 1px rgba(255,255,255,.11);opacity:${statusIn}}
  .status i{display:block;width:10px;height:10px;border-radius:50%;background:rgba(255,255,255,.2)} .status i.on{background:#62d98e}
  .status .live{width:10px;height:10px;border-radius:50%;background:#62d98e;opacity:${pulse}}
  .note{position:absolute;right:26px;bottom:18px;font-size:13px;color:rgba(255,255,255,.34)}
  .end{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:24px;background:#07070a;opacity:${end}}
  .end img{width:128px;transform:scale(${endScale})} .end b{font-size:46px;font-weight:700;letter-spacing:-.02em} .end span{font-size:24px;color:rgba(255,255,255,.66)}
  </style></head><body>
  <div class="bg"></div><div class="floor"></div>
  <div class="stage"><div class="cam">
    <div class="shadow"></div>
    <div class="base"><div class="keys"></div><div class="pad"></div></div>
    <div class="edge"></div>
    <div class="lid">
      <div class="back"></div>
      <div class="face"><div class="notch"></div>
        <div class="display">
          <div class="bar"><span class="a"><svg width="13" height="13" viewBox="0 0 32 32"><path d="M6 26.5 16 5.5l10 21" fill="none" stroke="#fff" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span><span>9:41</span></div>
          <div class="term">${terminal}</div>
          <div class="panel"><img src="${panelSrc}"></div>
        </div>
      </div>
    </div>
  </div></div>
  <div class="status"><span class="live"></span>${c.done(doneCount)}${dots}</div>
  ${captions}
  <div class="note">${c.note}</div>
  <div class="end"><img src="${icon}"><b>AFK Pug</b><span>${c.tag}</span></div>
  </body></html>`;
}

// Each worker needs its own Chrome profile: two at once on one profile refuse to start.
function shoot(html, png, tmp, index, worker = 0) {
  const file = join(tmp, `${index}.html`);
  writeFileSync(file, html);
  return new Promise((done, fail) => {
    execFile(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', '--force-device-scale-factor=1',
      `--user-data-dir=${join(tmp, `profile-${worker}`)}`, `--window-size=${WIDTH},${HEIGHT}`, `--screenshot=${png}`, `file://${file}`],
    (error) => (error ? fail(error) : done()));
  });
}

const WORKERS = Math.max(2, Math.min(8, cpus().length - 2));
const args = process.argv.slice(2);
const stillAt = args.indexOf('--still');
const langs = args.filter((a) => a === 'en' || a === 'th');

for (const lang of langs.length ? langs : ['en', 'th']) {
  const tmp = mkdtempSync(join(tmpdir(), 'afkpug-video-'));
  if (stillAt >= 0) {
    for (const s of args[stillAt + 1].split(',')) await shoot(frame(lang, Number(s)), resolve(`dist/still-${lang}-${s}.png`), tmp, 0);
    rmSync(tmp, { recursive: true, force: true });
    console.log('stills in dist/');
    continue;
  }
  const total = DURATION * FPS;
  let next = 0;
  await Promise.all(Array.from({ length: WORKERS }, async (_, worker) => {
    while (next < total) {
      const i = next++;
      await shoot(frame(lang, i / FPS), join(tmp, `f${String(i).padStart(5, '0')}.png`), tmp, i, worker);
    }
  }));
  const input = ['-y', '-loglevel', 'error', '-framerate', String(FPS), '-i', join(tmp, 'f%05d.png')];
  execFileSync('ffmpeg', [...input, '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', `docs/demo-${lang}.mp4`]);
  // GitHub only plays repo media inline as an image. A GIF tops out around 15-25 fps with
  // banding, so the README shows an animated WebP at WEBP_FPS and links the MP4.
  const small = join(tmp, 'small');
  execFileSync('mkdir', [small]);
  execFileSync('ffmpeg', [...input, '-vf', `fps=${WEBP_FPS},scale=${WEBP_WIDTH}:-2:flags=lanczos`, join(small, 's%05d.png')]);
  const frames = Array.from({ length: DURATION * WEBP_FPS }, (_, i) => join(small, `s${String(i + 1).padStart(5, '0')}.png`));
  // Spread the rounding so the frames still add up to exactly DURATION.
  const delays = frames.map((_, i) => Math.round(((i + 1) * 1000) / WEBP_FPS) - Math.round((i * 1000) / WEBP_FPS));
  execFileSync('img2webp', ['-loop', '0', '-lossy', '-q', '72', '-m', '6', ...frames.flatMap((f, i) => ['-d', String(delays[i]), f]), '-o', `docs/demo-${lang}.webp`]);
  rmSync(tmp, { recursive: true, force: true });
  console.log(`docs/demo-${lang}.mp4, docs/demo-${lang}.webp`);
}
