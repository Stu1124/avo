import { chromium } from "playwright-core";
import { mkdir } from "node:fs/promises";

const url = process.argv[2];
const outDir = process.argv[3];
const chrome = process.argv[4] || "/usr/local/bin/google-chrome";
const durationMs = 40_400;

if (!url || !outDir) {
  console.error("usage: record.mjs <url> <outDir> [chrome]");
  process.exit(1);
}

await mkdir(outDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: chrome,
  headless: true,
  args: [
    "--autoplay-policy=no-user-gesture-required",
    "--disable-dev-shm-usage",
    "--no-default-browser-check",
  ],
});

const context = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  deviceScaleFactor: 1,
  recordVideo: { dir: outDir, size: { width: 1920, height: 1080 } },
});

const page = await context.newPage();
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForFunction(() => window.AD_READY === true, { timeout: 30_000 });
await page.evaluate(() => window.play());
await page.waitForTimeout(durationMs);
await context.close();
await browser.close();
console.log(outDir);
