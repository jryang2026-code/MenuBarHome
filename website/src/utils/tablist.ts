import type { KeyboardEvent } from 'react';

/**
 * WAI-ARIA tabs keyboard model for a `role="tablist"` element: Left/Right wrap, Home/End jump.
 * Selects the new tab, moves focus to it, and stops the key from reaching page-level shortcuts.
 */
export function handleTablistKeyDown<T>(
  e: KeyboardEvent<HTMLElement>,
  values: readonly T[],
  current: T,
  select: (value: T) => void
): void {
  const index = values.indexOf(current);
  let next: number;
  switch (e.key) {
    case 'ArrowRight':
      next = (index + 1) % values.length;
      break;
    case 'ArrowLeft':
      next = (index - 1 + values.length) % values.length;
      break;
    case 'Home':
      next = 0;
      break;
    case 'End':
      next = values.length - 1;
      break;
    default:
      return;
  }
  e.preventDefault();
  e.stopPropagation();
  select(values[next]);
  const tabs = e.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]');
  tabs[next]?.focus();
}
