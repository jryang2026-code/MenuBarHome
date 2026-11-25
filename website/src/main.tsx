import { StrictMode } from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import './styles/app.css';
import App from './App';

const rootEl = document.getElementById('root')!;
const appNode = (
  <StrictMode>
    <App />
  </StrictMode>
);

if (rootEl.innerHTML.trim() && !rootEl.innerHTML.includes('<!--app-html-->')) {
  hydrateRoot(rootEl, appNode);
} else {
  createRoot(rootEl).render(appNode);
}
