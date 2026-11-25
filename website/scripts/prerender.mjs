import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'vite';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST = path.join(ROOT, 'dist');
const SSR_OUT = path.join(ROOT, '.ssr-tmp');

await build({
  root: ROOT,
  logLevel: 'silent',
  build: {
    ssr: 'src/entry-server.tsx',
    outDir: '.ssr-tmp',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        format: 'esm',
      },
    },
  },
});

const serverEntry = pathToFileURL(path.join(SSR_OUT, 'entry-server.js')).href;
const { render } = await import(serverEntry);
const appHtml = render();

const indexPath = path.join(DIST, 'index.html');
const template = fs.readFileSync(indexPath, 'utf8');
// Strip redundant crossorigin on same-origin stylesheet so direct file:// opening still loads full CSS
const finalHtml = template
  .replace('<link rel="stylesheet" crossorigin href=', '<link rel="stylesheet" href=')
  .replace('<!--app-html-->', appHtml);

fs.writeFileSync(indexPath, finalHtml, 'utf8');

// Rewrite root-relative /fonts/ inside built CSS assets to ../fonts/ so dist/ works on subpaths & file://
const assetsDir = path.join(DIST, 'assets');
if (fs.existsSync(assetsDir)) {
  for (const file of fs.readdirSync(assetsDir)) {
    if (file.endsWith('.css')) {
      const cssPath = path.join(assetsDir, file);
      const css = fs.readFileSync(cssPath, 'utf8');
      const nextCss = css.replace(/url\((["']?)\/fonts\//g, 'url($1../fonts/');
      if (nextCss !== css) fs.writeFileSync(cssPath, nextCss, 'utf8');
    }
  }
}

fs.rmSync(SSR_OUT, { recursive: true, force: true });

console.log(`Prerendered static HTML into dist/index.html (${Math.round(finalHtml.length / 1024)} KB)`);
