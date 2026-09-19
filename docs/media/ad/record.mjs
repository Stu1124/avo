import { chromium } from "playwright-core";
import { mkdir } from "node:fs/promises";
import { join } from "node:path";

const url = process.argv[2];
const frameDir = process.argv[3];
const chrome = process.argv[4] || "/usr/local/bin/google-chrome";
const FPS = 30;
const DURATION = 40;
const FRAMES = FPS * DURATION;

if (!url || !frameDir) {
  console.error("usage: record.mjs <url> <frameDir> [chrome]");
  process.exit(1);
}

await mkdir(frameDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: chrome,
  headless: true,
  args: ["--disable-dev-shm-usage", "--hide-scrollbars", "--font-render-hinting=none"],
});

const page = await browser.newPage({
  viewport: { width: 1920, height: 1080 },
  deviceScaleFactor: 1,
});

await page.goto(url, { waitUntil: "networkidle" });
await page.waitForFunction(() => window.AD_READY === true, { timeout: 30_000 });

for (let i = 0; i < FRAMES; i++) {
  const t = i / FPS;
  await page.evaluate((seconds) => window.seek(seconds), t);
  await page.screenshot({
    path: join(frameDir, `f${String(i).padStart(5, "0")}.jpg`),
    type: "jpeg",
    quality: 92,
  });
  if (i % 150 === 0) console.error(`frame ${i}/${FRAMES}`);
}

await browser.close();
console.log(frameDir);
