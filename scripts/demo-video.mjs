// Makes the README's demo video: a MacBook drawn in CSS 3D showing the real app screens
// from docs/screens/. It's an animation, not a screen recording. Every frame is a pure
// function of time, rendered in headless Chrome, then encoded with ffmpeg.
// Needs Chrome, ffmpeg built with libsvtav1 (Homebrew's is), and scripts/screenshots.sh run first.
// Usage: node scripts/demo-video.mjs [en|th] [--still <seconds>]
import { execFile, execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { cpus, tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const chrome = [process.env.CHROME_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
  .filter(Boolean).find(existsSync);
if (!chrome) throw new Error('Chrome not found; set CHROME_PATH');

const WIDTH = 1280, HEIGHT = 720, FPS = 60, DURATION = 13.5;
// Frames render at SCALE x the CSS size and are downsampled, so the zoomed panel stays sharp
// and slow camera moves don't snap to whole pixels.
const SCALE = 2, VIDEO_WIDTH = 1920;
// The README shows the AVIF at 860 CSS px, about 1720 device px on a Retina screen.
const AVIF_WIDTH = 1600;
/** Scales, converts with the BT.709 matrix and tags the stream to match, so browsers show the colors as rendered. */
const toVideo = (width) => `scale=${width}:-2:flags=lanczos:out_color_matrix=bt709,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv`;
const CAPTIONS = {
  en: {
    start: 'Your agents are working', watch: 'Click the A to see every job and its step', close: 'Close the lid',
    away: 'Screen off. Work keeps running', done: (n) => `${n} of 3 jobs done`, back: 'Open it: everything is back, with a summary',
    timer: 'No agent? Pick a time and press Go AFK', tag: 'Close the lid. Your agents keep running.',
    note: 'Animation made from the app’s screens',
  },
  th: {
    start: 'Agent กำลังทำงาน', watch: 'คลิก A ดูทุกงานและขั้นตอนปัจจุบัน', close: 'พับจอได้เลย',
    away: 'จอดับ แต่งานยังเดินต่อ', done: (n) => `เสร็จแล้ว ${n} จาก 3 งาน`, back: 'เปิดจอ ทุกอย่างกลับมา พร้อมสรุปงาน',
    timer: 'ไม่มี Agent ก็เลือกเวลาแล้วกดเริ่ม AFK', tag: 'พับจอได้เลย Agent ยังทำงานต่อ',
    note: 'แอนิเมชันจากหน้าจอจริงของแอป',
  },
};
const TERMINAL = ['$ claude "fix the failing payment tests"', '> Reading src/checkout.ts', '> Editing 4 files', '> Running the tests…', '✓ 128 passed'];

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const smooth = (v) => { const x = clamp(v); return x * x * x * (x * (x * 6 - 15) + 10); };
/** 0 before `a`, 1 after `b`, eased between. */
const span = (t, a, b) => smooth((t - a) / (b - a));
const lerp = (a, b, k) => a + (b - a) * k;
/** Visible between `a` and `b`, fading over `fade` seconds at each end. */
const window_ = (t, a, b, fade = 0.2) => span(t, a, a + fade) * (1 - span(t, b - fade, b));

// The display inside the lid is 752 x 480 CSS px. The app panel sits at its top right, 206 px
// wide, showing screenshots that are 800 px wide.
const PANEL = { left: 533, top: 29, width: 206 };
const K = PANEL.width / 800;
/** A point in a screenshot (800 px wide) as a point on the display. */
const onPanel = (x, y) => [PANEL.left + x * K, PANEL.top + y * K];
// Where things are in the screenshots, in their own pixels.
const SPOTS = {
  menuA: [686, 12],
  claudeRow: onPanel(420, 742),
  close: onPanel(717, 625),
  twoHours: onPanel(340, 392),
  goAFK: onPanel(400, 504),
};

/** The cursor's path: [time, x, y], eased from one stop to the next. */
const PATH = [
  [0.9, 560, 330], [1.3, ...SPOTS.menuA], [1.95, ...SPOTS.claudeRow], [3.2, ...SPOTS.claudeRow], [3.5, 640, 330],
  [7.2, 600, 340], [7.85, ...SPOTS.close], [8.15, ...SPOTS.close], [8.75, ...SPOTS.twoHours], [9.05, ...SPOTS.twoHours],
  [9.45, ...SPOTS.goAFK], [9.75, ...SPOTS.goAFK], [10.4, 700, 330],
];
const CLICKS = [1.3, 7.95, 8.85, 9.55];

function cursorAt(t) {
  if (t <= PATH[0][0]) return PATH[0].slice(1);
  for (let i = 1; i < PATH.length; i++) {
    const [t1, x1, y1] = PATH[i];
    if (t <= t1) {
      const [t0, x0, y0] = PATH[i - 1];
      const k = smooth((t - t0) / (t1 - t0));
      return [lerp(x0, x1, k), lerp(y0, y1, k)];
    }
  }
  return PATH[PATH.length - 1].slice(1);
}

function frame(lang, t) {
  const c = CAPTIONS[lang];
  const shot = (name) => `file://${resolve(`docs/screens/${lang}/${name}.png`)}`;
  const icon = `file://${resolve('docs/icon.png')}`;

  // Lid: 0 is open, 1 is shut. Closes at 3.6-4.5 s, opens at 6.2-7.1 s.
  const lid = span(t, 3.6, 4.5) * (1 - span(t, 6.2, 7.1));
  // CSS: a positive angle leans the lid back, -90 lays it flat on the base.
  const hinge = lerp(16, -89.5, lid);
  const screenOn = 1 - span(lid, 0.25, 0.75);

  // Camera: pushes in on the panel twice, pulls back for the lid and the end.
  const zoomIn = span(t, 1.35, 1.9) * (1 - span(t, 3.15, 3.6)) + span(t, 7.1, 7.6) * (1 - span(t, 11.2, 11.8));
  const scale = lerp(0.74, 1.3, zoomIn);
  const shiftX = lerp(0, -350, zoomIn);
  const shiftY = lerp(30, 185, zoomIn) - 175 * lid;
  const tilt = lerp(-13, -3, zoomIn) - 27 * lid;
  const spin = Math.sin(t * 0.5) * (1 - zoomIn) * 3;

  // The panel and which screen it shows.
  const panelOn = Math.max(window_(t, 1.35, 3.5), span(t, 7.0, 7.3) * (1 - span(t, 11.9, 12.2)));
  const screens = [
    ['working', window_(t, 1.3, 3.6, 0.05)],
    ['away', window_(t, 6.9, 8.2, 0.1)],
    ['idle', window_(t, 8.0, 9.8, 0.15)],
    ['timer', span(t, 9.6, 9.8)],
  ].map(([name, o]) => `<img src="${shot(name)}" style="opacity:${o}">`).join('');
  const typed = Math.floor(clamp((t - 0.1) / 0.8) * 3) + (t > 7.2 ? 2 : 0);
  const terminal = TERMINAL.map((line, i) => `<div style="opacity:${i < typed ? 1 : 0}">${line}</div>`).join('');

  // Things the cursor does to the panel: a hover, presses, and the timer counting down.
  const hover = window_(t, 1.9, 3.3, 0.15);
  const press = (at) => Math.max(0, 1 - Math.abs(t - at) / 0.12);
  const box = ([x, y, w, h], o, extra = '') => o > 0.01
    ? `<div class="spot" style="left:${x * K}px;top:${y * K}px;width:${w * K}px;height:${h * K}px;opacity:${o};${extra}"></div>` : '';
  const spots = box([30, 688, 740, 112], hover * 0.9)
    + box([700, 608, 34, 34], press(7.95), 'border-radius:50%')
    + box([281, 364, 118, 58], press(8.85))
    + box([36, 466, 728, 76], press(9.55), 'background:rgba(0,0,0,.22)');
  const left = Math.max(0, 7200 - Math.floor(Math.max(0, t - 9.7)));
  const clock = `${Math.floor(left / 3600)}:${String(Math.floor(left / 60) % 60).padStart(2, '0')}:${String(left % 60).padStart(2, '0')}`;
  const countdown = t > 9.6 ? `<div class="clock" style="opacity:${span(t, 9.6, 9.8)}">${clock}</div>` : '';

  const [cx, cy] = cursorAt(t);
  const cursorOn = Math.max(window_(t, 0.85, 3.55), window_(t, 7.15, 10.9)) * screenOn;
  const squeeze = 1 - 0.18 * Math.max(...CLICKS.map(press));
  const ripples = CLICKS.map((at) => {
    const k = (t - at) / 0.45;
    if (k < 0 || k > 1) return '';
    const [x, y] = cursorAt(at);
    return `<div class="ripple" style="left:${x}px;top:${y}px;transform:translate(-50%,-50%) scale(${lerp(0.3, 1.6, k)});opacity:${(1 - k) * 0.8}"></div>`;
  }).join('');

  // Under the closed lid: a soft pulse, and jobs finishing one by one.
  const doneCount = t < 5.0 ? 0 : t < 5.4 ? 1 : t < 5.8 ? 2 : 3;
  const statusIn = window_(t, 4.6, 6.2, 0.3);
  const pulse = 0.55 + 0.45 * Math.sin(t * 5);

  // Captions.
  const cues = [[0.05, 1.3, c.start], [1.4, 3.4, c.watch], [3.5, 4.6, c.close], [4.7, 6.2, c.away], [6.4, 8.5, c.back], [8.6, 11.6, c.timer]];
  const captions = cues.map(([a, b, text]) => {
    const o = span(t, a, a + 0.25) * (1 - span(t, b - 0.2, b));
    const y = lerp(10, 0, span(t, a, a + 0.35));
    return o > 0 ? `<div class="cap" style="opacity:${o};transform:translateX(-50%) translateY(${y}px)">${text}</div>` : '';
  }).join('');

  // End card.
  const end = span(t, 11.9, 12.5);
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
    border-radius:4px 4px 0 0;background:linear-gradient(180deg,#b9bbc0 0%,#a7a9ae 100%);box-shadow:inset 0 1px 0 rgba(255,255,255,.25)}
  .keys{position:absolute;left:52px;right:52px;top:30px;height:262px;border-radius:9px;background:#17181b;
    background-image:linear-gradient(#26272b 1px,transparent 1px),linear-gradient(90deg,#26272b 1px,transparent 1px);background-size:44.5px 44px;
    box-shadow:inset 0 2px 7px rgba(0,0,0,.9)}
  .pad{position:absolute;left:230px;right:230px;top:310px;height:185px;border-radius:12px;background:linear-gradient(180deg,#b3b5ba,#a2a4a9);box-shadow:inset 0 0 0 1px rgba(0,0,0,.14),inset 0 1px 0 rgba(255,255,255,.4)}
  /* The base is a solid slab: top, front and two sides, so its edges meet. */
  .edge{position:absolute;left:-385px;top:127px;width:770px;height:14px;border-radius:0 0 7px 7px;background:linear-gradient(#a6a8ad,#8b8d92 45%,#5f6065);transform:translateZ(520px)}
  .side{position:absolute;top:127px;width:520px;height:14px;border-radius:0 0 7px 0;background:linear-gradient(#9a9ca1,#6d6e73);transform-origin:0 0;transform:rotateY(-90deg)}
  /* Lid */
  .lid{position:absolute;left:-385px;top:-372px;width:770px;height:500px;transform-origin:50% 100%;transform:rotateX(${hinge}deg);transform-style:preserve-3d}
  .face{position:absolute;inset:0;border-radius:22px 22px 4px 4px;background:#0a0a0c;box-shadow:inset 0 0 0 2px #2a2b2f,inset 0 0 0 9px #050506;backface-visibility:hidden;overflow:hidden}
  .back{position:absolute;inset:0;border-radius:22px 22px 4px 4px;background:radial-gradient(90% 80% at 40% 20%,#dfe1e5,#b4b6bb 55%,#94969b);transform:rotateY(180deg);backface-visibility:hidden}
  .notch{position:absolute;left:50%;top:9px;margin-left:-46px;width:92px;height:18px;border-radius:0 0 10px 10px;background:#050506;z-index:6}
  .display{position:absolute;inset:9px 9px 11px;border-radius:13px 13px 2px 2px;overflow:hidden;background:radial-gradient(90% 90% at 70% 12%,#3b3a55 0%,#1b1b2c 45%,#0c0c13 100%);opacity:${screenOn}}
  .bar{position:absolute;left:0;right:0;top:0;height:24px;background:rgba(0,0,0,.34);display:flex;align-items:center;justify-content:flex-end;gap:13px;padding:0 12px;font-size:11px;font-weight:500}
  .bar .a{display:flex;width:22px;height:18px;align-items:center;justify-content:center;border-radius:4px;background:rgba(255,255,255,${0.24 * panelOn})}
  .term{position:absolute;left:30px;top:66px;width:345px;height:206px;border-radius:9px;background:rgba(9,10,14,.9);box-shadow:0 18px 40px rgba(0,0,0,.5),inset 0 0 0 1px rgba(255,255,255,.08);padding:30px 14px;font:11.5px/1.75 Menlo,monospace;color:#b9f2cc}
  .term:before{content:"";position:absolute;left:12px;top:11px;width:9px;height:9px;border-radius:50%;background:#ff5f57;box-shadow:15px 0 #febc2e,30px 0 #28c840}
  .panel{position:absolute;left:${PANEL.left}px;top:${PANEL.top}px;width:${PANEL.width}px;opacity:${panelOn};transform:translateY(${lerp(-10, 0, panelOn)}px) scale(${lerp(0.97, 1, panelOn)});transform-origin:100% 0}
  .panel img{position:absolute;left:0;top:0;display:block;width:100%;border-radius:13px;box-shadow:0 24px 50px rgba(0,0,0,.65),0 0 0 1px rgba(255,255,255,.12)}
  .spot{position:absolute;border-radius:8px;background:rgba(255,255,255,.12)}
  .clock{position:absolute;left:${30 * K}px;top:${148 * K}px;width:${420 * K}px;height:${92 * K}px;background:#0e0e10;font-size:${96 * K}px;line-height:${92 * K}px;font-weight:300;letter-spacing:-.01em;font-variant-numeric:tabular-nums;padding-left:${6 * K}px}
  .cursor{position:absolute;left:0;top:0;width:15px;height:22px;transform:translate(${cx}px,${cy}px) scale(${squeeze});transform-origin:0 0;z-index:9;filter:drop-shadow(0 2px 3px rgba(0,0,0,.5));opacity:${cursorOn}}
  .ripple{position:absolute;width:34px;height:34px;border-radius:50%;border:2px solid rgba(255,255,255,.85);z-index:8}
  .cap{position:absolute;left:50%;bottom:34px;white-space:nowrap;font-size:26px;font-weight:600;letter-spacing:-.01em;padding:10px 22px;border-radius:999px;background:#0a0a0e;box-shadow:inset 0 0 0 1px rgba(255,255,255,.1)}
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
    <div class="edge"></div><div class="side" style="left:-385px"></div><div class="side" style="left:385px"></div>
    <div class="lid">
      <div class="back"></div>
      <div class="face"><div class="notch"></div>
        <div class="display">
          <div class="bar"><span class="a"><svg width="13" height="13" viewBox="0 0 32 32"><path d="M6 26.5 16 5.5l10 21" fill="none" stroke="#fff" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span><span>9:41</span></div>
          <div class="term">${terminal}</div>
          <div class="panel">${screens}${spots}${countdown}</div>
          ${ripples}
          <svg class="cursor" viewBox="0 0 15 22"><path d="M1 1v17.5l4.6-4.4 2.9 6.6 2.8-1.2-2.8-6.5h6.3z" fill="#fff" stroke="#000" stroke-width="1.2" stroke-linejoin="round"/></svg>
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
// Headless Chrome now and then hangs on a screenshot, so each try is killed after 60 s.
async function shoot(html, png, tmp, index, worker = 0) {
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
    execFile(chrome, ['--headless=new', '--hide-scrollbars', '--allow-file-access-from-files', `--force-device-scale-factor=${SCALE}`,
      `--user-data-dir=${join(tmp, `profile-${worker}`)}`, `--window-size=${WIDTH},${HEIGHT}`, `--screenshot=${png}`, `file://${file}`],
    { timeout: 60_000, killSignal: 'SIGKILL' }, (error) => (error ? fail(error) : done()));
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
  execFileSync('ffmpeg', [...input, '-vf', toVideo(VIDEO_WIDTH), '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-movflags', '+faststart', `docs/demo-${lang}.mp4`]);
  // GitHub only plays repo media inline as an image. A GIF bands and tops out around 20 fps,
  // and an animated WebP either judders or leaves stale blocks on slow moves. An AVIF is real
  // AV1 video: 60 fps, clean gradients, and a fraction of the size.
  execFileSync('ffmpeg', [...input, '-vf', toVideo(AVIF_WIDTH), '-c:v', 'libsvtav1', '-crf', '30', '-preset', '4', '-g', '300', '-loop', '0', `docs/demo-${lang}.avif`]);
  rmSync(tmp, { recursive: true, force: true });
  console.log(`docs/demo-${lang}.mp4, docs/demo-${lang}.avif`);
}
