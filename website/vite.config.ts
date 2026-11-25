import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

const websiteDir = path.dirname(fileURLToPath(import.meta.url));
const appVersion = fs.readFileSync(path.resolve(websiteDir, '../VERSION'), 'utf8').trim();

export default defineConfig({
  base: './',
  define: {
    __APP_VERSION__: JSON.stringify(appVersion),
  },
  plugins: [
    react(),
    tailwindcss(),
    {
      name: 'menubarhome-app-version',
      transformIndexHtml: (html) => html.replaceAll('__APP_VERSION__', appVersion),
    },
  ],
  build: {
    target: 'es2022',
    cssCodeSplit: true,
    modulePreload: {
      resolveDependencies(_filename, deps) {
        return deps.filter((d) => !d.includes('StudyScene3D'));
      },
    },
  },
});
