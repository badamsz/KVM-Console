// Renders the SVG sources in this folder into PiKVMConsole/Assets.xcassets.
// Run from the repo root:  node Design/AppIcon/generate.js
// Needs Node and Playwright with Chromium (npm i -g playwright && npx playwright install chromium).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const here = __dirname;
const catalog = path.join(here, '..', '..', 'PiKVMConsole', 'Assets.xcassets');
const write = (p, obj) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(obj, null, 2) + '\n'); };
const info = { author: 'xcode', version: 1 };

// macOS app icon slots. 16 and 32 pt use a simplified drawing that stays legible.
const slots = [16, 32, 128, 256, 512].flatMap(pt => [1, 2].map(scale => ({ pt, scale, px: pt * scale })));
const jobs = [];
for (const s of slots) {
  const src = s.px <= 64 ? 'icon-small.svg' : 'icon.svg';
  s.filename = `icon_${s.pt}x${s.pt}${s.scale === 2 ? '@2x' : ''}.png`;
  jobs.push([src, path.join(catalog, 'AppIcon.appiconset', s.filename), s.px]);
}
// In-app logo (e.g. About or empty states).
jobs.push(['icon.svg', path.join(catalog, 'AppLogo.imageset', 'AppLogo.png'), 256]);
jobs.push(['icon.svg', path.join(catalog, 'AppLogo.imageset', 'AppLogo@2x.png'), 512]);
// Menu bar template image, 18 pt.
jobs.push(['menubar.svg', path.join(catalog, 'MenuBarIcon.imageset', 'MenuBarIcon.png'), 18]);
jobs.push(['menubar.svg', path.join(catalog, 'MenuBarIcon.imageset', 'MenuBarIcon@2x.png'), 36]);

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const [src, out, px] of jobs) {
    const svg = fs.readFileSync(path.join(here, src), 'utf8')
      .replace('<svg ', `<svg style="width:${px}px;height:${px}px;display:block" `);
    await page.setViewportSize({ width: px, height: px });
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    await page.screenshot({ path: out, omitBackground: true, clip: { x: 0, y: 0, width: px, height: px } });
  }
  await browser.close();

  write(path.join(catalog, 'Contents.json'), { info });
  write(path.join(catalog, 'AppIcon.appiconset', 'Contents.json'), {
    images: slots.map(s => ({ filename: s.filename, idiom: 'mac', scale: `${s.scale}x`, size: `${s.pt}x${s.pt}` })),
    info,
  });
  write(path.join(catalog, 'AppLogo.imageset', 'Contents.json'), {
    images: [
      { filename: 'AppLogo.png', idiom: 'universal', scale: '1x' },
      { filename: 'AppLogo@2x.png', idiom: 'universal', scale: '2x' },
    ],
    info,
  });
  write(path.join(catalog, 'MenuBarIcon.imageset', 'Contents.json'), {
    images: [
      { filename: 'MenuBarIcon.png', idiom: 'mac', scale: '1x' },
      { filename: 'MenuBarIcon@2x.png', idiom: 'mac', scale: '2x' },
    ],
    info,
    properties: { 'template-rendering-intent': 'template' },
  });
})();
