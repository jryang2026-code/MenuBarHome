import { useEffect, useState } from 'react';

const formatClock = () =>
  new Date().toLocaleTimeString('en-GB', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  });

/** Ticking 24h HH:MM:SS clock; starts from a fixed value so SSR and hydration match. */
export function useUkClock(enabled = true, initial = '17:42:08'): string {
  const [clock, setClock] = useState(initial);

  useEffect(() => {
    if (!enabled) return;
    setClock(formatClock());
    const id = window.setInterval(() => setClock(formatClock()), 1000);
    return () => window.clearInterval(id);
  }, [enabled]);

  return clock;
}
