// Draws the README's install pictures (GitHub, Finder and macOS screens with
// numbered call-outs) and the hero image in headless Chrome, and saves PNGs to
// docs/guide/. Run scripts/screenshots.sh first: the hero uses docs/screens/.
// Usage: node scripts/guide-illustrations.mjs [filter]
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const chrome = [process.env.CHROME_PATH, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']
  .filter(Boolean).find(existsSync);
if (!chrome) throw new Error('Chrome not found; set CHROME_PATH');

const outDir = resolve('docs/guide');
mkdirSync(outDir, { recursive: true });
const tmp = mkdtempSync(join(tmpdir(), 'afkpug-guide-'));
const filter = process.argv[2];
const version = readFileSync('Resources/Info.plist', 'utf8').match(/CFBundleShortVersionString<\/key>\s*<string>([^<]+)/)[1];
const appIcon = `file://${resolve('docs/icon.png')}`;
const screen = (lang, name) => `file://${resolve(`docs/screens/${lang}/${name}.png`)}`;

const PALETTE = {
  light: {
    call: '#000000', callText: '#ffffff', callGlow: 'rgba(0,0,0,.14)',
    text: '#1f2328', muted: '#6b6b6b', border: '#d9d9d9', shadow: '0 12px 40px rgba(0,0,0,.18)',
    gh: { bg: '#ffffff', subtle: '#f6f8fa', border: '#d1d9e0', text: '#1f2328', muted: '#59636e', link: '#0969da', label: '#1a7f37' },
    mac: { window: '#ececec', side: '#e6e6e6', pane: '#ffffff', group: '#f5f5f5', select: '#0a64d9', bar: 'rgba(245,245,247,.92)', barText: '#1d1d1f', button: '#ffffff', wall: 'linear-gradient(120deg,#d9dee8,#eef0f4)', dialog: '#f2f2f2' },
  },
  dark: {
    call: '#ffffff', callText: '#000000', callGlow: 'rgba(255,255,255,.18)',
    text: '#e6e6e6', muted: '#a0a0a0', border: '#3c3c3c', shadow: '0 12px 40px rgba(0,0,0,.55)',
    gh: { bg: '#0d1117', subtle: '#151b23', border: '#3d444d', text: '#e6edf3', muted: '#9198a1', link: '#4493f8', label: '#3fb950' },
    mac: { window: '#2b2b2b', side: '#323232', pane: '#1e1e1e', group: '#2a2a2a', select: '#0a64d9', bar: 'rgba(30,30,32,.92)', barText: '#f5f5f7', button: '#4a4a4a', wall: 'linear-gradient(120deg,#23262e,#14161b)', dialog: '#2e2e2e' },
  },
};

const ICON = {
  box: '<path d="M12 3 20 7v10l-8 4-8-4V7z M4 7l8 4 8-4 M12 11v10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
  file: '<path d="M14 3H7a1 1 0 0 0-1 1v15a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V8z M14 3v5h5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>',
  caret: '<path d="M7 10l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
  gear: '<circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M12 4v3M12 17v3M4 12h3M17 12h3M6.3 6.3l2.1 2.1M15.6 15.6l2.1 2.1M6.3 17.7l2.1-2.1M15.6 8.4l2.1-2.1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>',
  hand: '<path d="M8 12V6.5a1.5 1.5 0 0 1 3 0V11m0-1V5a1.5 1.5 0 0 1 3 0v6m0-3.5a1.5 1.5 0 0 1 3 0V14c0 4-2.5 6.5-6 6.5-3 0-4.5-1.500-6-4.500l-1.300-2.600c-.8-1.600 1.500-2.700 2.600-1.300L8 14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>',
  moon: '<path d="M19 14.5A7.500 7.500 0 1 1 9.500 5a6 6 0 0 0 9.500 9.500z" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linejoin="round"/>',
  lock: '<rect x="5.500" y="11" width="13" height="9" rx="2" fill="none" stroke="currentColor" stroke-width="1.700"/><path d="M8.500 11V8a3.500 3.500 0 0 1 7 0v3" fill="none" stroke="currentColor" stroke-width="1.700"/>',
  wifi: '<path d="M3.500 10a12 12 0 0 1 17 0M7 13.500a7 7 0 0 1 10 0M10.300 17a2.500 2.500 0 0 1 3.400 0" fill="none" stroke="currentColor" stroke-width="1.800" stroke-linecap="round"/>',
  battery: '<rect x="2.500" y="7.500" width="17" height="9" rx="2.500" fill="none" stroke="currentColor" stroke-width="1.500"/><rect x="4.500" y="9.500" width="11" height="5" rx="1" fill="currentColor"/><path d="M21.500 10.500v3" stroke="currentColor" stroke-width="1.500" stroke-linecap="round"/>',
  search: '<circle cx="10.500" cy="10.500" r="5.500" fill="none" stroke="currentColor" stroke-width="1.800"/><path d="M14.500 14.500 20 20" stroke="currentColor" stroke-width="1.800" stroke-linecap="round"/>',
  mark: '<path d="M6 19.500 12 4.500l6 15" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
};
const icon = (name, size = 20) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24">${ICON[name]}</svg>`;
const mark = (n, inner, { pos = 'tr', block = false, round = 6 } = {}) =>
  `<span class="mark ${block ? 'block' : ''}" style="--r:${round}px">${inner}<i class="badge ${pos}">${n}</i></span>`;
const lights = `<span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span>`;

const BASE_CSS = (p) => `
*{box-sizing:border-box}
html,body{margin:0;background:transparent}
body{font:13px/1.4 -apple-system,BlinkMacSystemFont,"Thonburi",system-ui,sans-serif;color:${p.text};padding:28px;-webkit-font-smoothing:antialiased}
svg{display:block;flex:none}
.frame{border-radius:12px;overflow:hidden;box-shadow:${p.shadow};border:1px solid ${p.border}}
.mark{position:relative;display:inline-flex;border-radius:var(--r);outline:3px solid ${p.call};outline-offset:3px;box-shadow:0 0 0 9px ${p.callGlow}}
.mark.block{display:flex}
.badge{position:absolute;z-index:5;width:26px;height:26px;border-radius:50%;background:${p.call};color:${p.callText};font:700 14px/26px -apple-system,sans-serif;text-align:center;font-style:normal;box-shadow:0 2px 6px rgba(0,0,0,.35);border:2px solid ${p.callText};line-height:22px}
.badge.tr{top:-20px;right:-20px}.badge.tl{top:-20px;left:-20px}.badge.b{bottom:-40px;left:50%;margin-left:-13px}
.badge.r{top:50%;right:-42px;margin-top:-13px}.badge.l{top:50%;left:-42px;margin-top:-13px}
.row{display:flex;align-items:center}
.muted{color:${p.muted}}
.dot{width:12px;height:12px;border-radius:50%;display:inline-block}
`;

const macButton = (p, label, primary = false) =>
  `<span style="display:inline-block;padding:5px 18px;border-radius:7px;font-weight:500;${primary ? `background:${p.mac.select};color:#fff` : `background:${p.mac.button};box-shadow:0 0 0 .5px rgba(0,0,0,.25),0 1px 1px rgba(0,0,0,.12)`}">${label}</span>`;

const hero = (lang, captions) => ({
  width: 1080, height: 660, single: true,
  body: () => {
    const shot = (name, n, text) => `<div style="width:290px;text-align:center">
      <div style="margin-bottom:18px;font-size:16px;font-weight:600;color:#fff"><span style="color:rgba(255,255,255,.5);margin-right:6px">${n}</span>${text}</div>
      <img src="${screen(lang, name)}" style="width:290px;border-radius:14px;box-shadow:0 22px 50px rgba(0,0,0,.6);border:1px solid rgba(255,255,255,.09)">
    </div>`;
    return `<div style="margin:-28px;width:1080px;height:660px;padding:26px 42px;border-radius:20px;background:#000;display:flex;justify-content:space-between;align-items:flex-start">
      ${shot('idle', 1, captions[0])}${shot('working', 2, captions[1])}${shot('away', 3, captions[2])}
    </div>`;
  },
});

const ILLUSTRATIONS = {
  'hero-en': hero('en', ['Keep Agent mode on', 'Close the lid and go', 'Come back to a summary']),
  'hero-th': hero('th', ['เปิดโหมด agent ไว้', 'พับจอแล้วไปได้เลย', 'กลับมาดูสรุปงาน']),

  // GitHub release page: the zip under Assets.
  download: { width: 900, height: 330, body: (p) => {
    const g = p.gh;
    const asset = (ic, name, size, bold) => `<div class="row" style="width:100%;padding:10px 14px;gap:10px;color:${g.link};${bold ? 'font-weight:600' : ''}"><span style="color:${g.muted}">${icon(ic, 17)}</span><span style="flex:1">${name}</span><span style="color:${g.muted};font-weight:400;font-size:12px">${size}</span></div>`;
    return `<div class="frame" style="width:844px;height:274px;background:${g.bg};color:${g.text}">
      <div class="row" style="height:40px;padding:0 14px;gap:8px;background:${g.subtle};border-bottom:1px solid ${g.border}">${lights}<span class="muted" style="flex:1;margin-left:14px;padding:4px 12px;border-radius:14px;background:${g.bg};font-size:12px">github.com/Pug-03/AFK_Pug/releases/latest</span></div>
      <div style="padding:18px 60px 18px 26px">
        <div class="row" style="gap:10px"><b style="font-size:22px">AFK Pug ${version}</b><span style="border:1px solid ${g.label};color:${g.label};border-radius:12px;padding:0 9px;font-size:12px">Latest</span></div>
        <div class="row" style="gap:6px;margin:14px 0 10px;font-weight:600;font-size:15px">${icon('caret', 16)}Assets</div>
        <div style="border:1px solid ${g.border};border-radius:6px">
          <div style="padding:4px">${mark(1, asset('box', 'AFK-Pug.zip', '1 MB', true), { block: true, pos: 'r' })}</div>
          <div style="border-top:1px solid ${g.border}">${asset('file', 'Source code (zip)', '')}</div>
        </div>
      </div>
    </div>`;
  } },

  // Finder: drag the app onto Applications.
  drag: { width: 900, height: 340, body: (p) => {
    const m = p.mac;
    const folder = `<svg width="84" height="84" viewBox="0 0 24 24"><path d="M2.500 6.500A1.500 1.500 0 0 1 4 5h5.200l2 2H20a1.500 1.500 0 0 1 1.500 1.500V18a1.500 1.500 0 0 1-1.500 1.500H4A1.500 1.500 0 0 1 2.500 18z" fill="#5ab2f2"/><path d="M12 9.500l3.200 6.200h-1.400l-.6-1.300h-2.400l-.6 1.300H8.800zm0 2.300-.8 1.700h1.600z" fill="#fff"/></svg>`;
    const item = (visual, label) => `<div style="text-align:center;width:150px"><div style="height:92px;display:grid;place-items:center">${visual}</div><div style="margin-top:6px">${label}</div></div>`;
    const arrow = `<svg width="150" height="40" viewBox="0 0 150 40"><path d="M6 20h130M122 7l15 13-15 13" fill="none" stroke="#ff5a36" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="1 0"/></svg>`;
    return `<div class="frame" style="width:844px;height:284px;background:${m.pane}">
      <div class="row" style="height:40px;padding:0 14px;gap:8px;background:${m.window};border-bottom:1px solid ${p.border}">${lights}<b style="flex:1;text-align:center;margin-right:52px">Downloads</b></div>
      <div class="row" style="justify-content:center;gap:34px;height:244px">
        ${mark(2, item(`<img src="${appIcon}" width="84" height="84">`, 'AFK Pug'), { pos: 'tl', round: 10 })}
        ${arrow}
        ${item(folder, 'Applications')}
      </div>
    </div>`;
  } },

  // Gatekeeper's first-run dialog.
  blocked: { width: 620, height: 420, body: (p) => {
    const m = p.mac;
    return `<div class="frame" style="width:564px;height:364px;background:${m.wall};display:grid;place-items:center;border-radius:12px">
      <div style="width:300px;padding:22px 20px 18px;border-radius:16px;background:${m.dialog};text-align:center;box-shadow:0 18px 50px rgba(0,0,0,.35)">
        <img src="${appIcon}" width="58" height="58" style="display:block;margin:0 auto 12px">
        <b style="font-size:14px">“AFK Pug” Not Opened</b>
        <div style="font-size:11.500px;margin:8px 0 16px">Apple could not verify “AFK Pug” is free of malware that may harm your Mac or compromise your privacy.</div>
        <div class="row" style="justify-content:center;gap:16px">${mark(3, macButton(p, 'Done', true), { pos: 'tr', round: 7 })}${macButton(p, 'Move to Trash')}</div>
      </div>
    </div>`;
  } },

  // System Settings → Privacy & Security → Open Anyway.
  anyway: { width: 920, height: 450, body: (p) => {
    const m = p.mac;
    const side = (label, color, ic, sel) => `<div class="row" style="gap:8px;padding:5px 8px;border-radius:6px;${sel ? `background:${m.select};color:#fff` : ''}"><span style="width:22px;height:22px;border-radius:6px;background:${color};color:#fff;display:grid;place-items:center">${icon(ic, 14)}</span>${label}</div>`;
    return `<div class="frame" style="width:864px;height:394px;display:flex;background:${m.pane}">
      <div style="width:240px;background:${m.side};padding:14px 10px;border-right:1px solid ${p.border}">
        <div class="row" style="gap:7px;margin-bottom:16px">${lights}</div>
        ${side('General', '#8e8e93', 'gear')}${side('Notifications', '#ff3b30', 'gear')}${side('Focus', '#5e5ce6', 'moon')}
        <div style="margin:6px 0">${mark(4, `<div style="width:216px">${side('Privacy &amp; Security', '#0a84ff', 'hand', true)}</div>`, { block: true, pos: 'r' })}</div>
        ${side('Lock Screen', '#1c1c1e', 'lock')}${side('Touch ID &amp; Password', '#ff453a', 'lock')}
      </div>
      <div style="flex:1;padding:18px 44px 18px 26px">
        <b style="font-size:15px">Privacy &amp; Security</b>
        <div class="muted" style="margin:10px 0 18px;font-size:12px">Scroll down to the Security section.</div>
        <b>Security</b>
        <div style="margin-top:8px;background:${m.group};border:1px solid ${p.border};border-radius:10px">
          <div class="row" style="padding:12px 14px;border-bottom:1px solid ${p.border}"><span style="flex:1">Allow applications from</span><span class="muted">App Store &amp; Known Developers</span></div>
          <div class="row" style="padding:14px;gap:18px"><span style="flex:1">“AFK Pug” was blocked to protect your Mac.</span>${mark(5, macButton(p, 'Open Anyway'), { pos: 'tr', round: 7 })}</div>
        </div>
      </div>
    </div>`;
  } },

  // Menu bar with the notch: where the icon lives.
  menubar: { width: 920, height: 190, body: (p) => {
    const m = p.mac;
    return `<div class="frame" style="width:864px;height:134px;background:${m.wall};position:relative">
      <div class="row" style="height:34px;background:${m.bar};color:${m.barText};padding:0 16px;gap:18px;font-size:13px">
        <b>Terminal</b><span>Shell</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span>
        <span style="flex:1"></span>
        ${mark(1, `<span style="display:grid;place-items:center;width:28px;height:22px">${icon('mark', 18)}</span>`, { pos: 'b', round: 5 })}
        ${icon('wifi', 18)}${icon('battery', 24)}${icon('search', 16)}<span>Fri 17:55</span>
      </div>
      <div style="position:absolute;top:0;left:50%;margin-left:-75px;width:150px;height:34px;background:#000;border-radius:0 0 11px 11px"></div>
    </div>`;
  } },
};

let count = 0;
for (const [name, ill] of Object.entries(ILLUSTRATIONS)) {
  if (filter && !name.includes(filter)) continue;
  for (const theme of ill.single ? ['dark'] : ['light', 'dark']) {
    const p = PALETTE[theme];
    const html = join(tmp, `${name}-${theme}.html`);
    const out = join(outDir, ill.single ? `${name}.png` : `${name}-${theme}.png`);
    writeFileSync(html, `<!doctype html><html><head><meta charset="utf-8"><style>${BASE_CSS(p)}</style></head><body>${ill.body(p)}</body></html>`);
    execFileSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', '--force-device-scale-factor=2',
      '--default-background-color=00000000', `--window-size=${ill.width},${ill.height}`, `--screenshot=${out}`, `file://${html}`], { stdio: 'ignore' });
    count++;
  }
}
console.log(`${count} illustration(s) in docs/guide/`);
