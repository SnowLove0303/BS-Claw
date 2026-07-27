import type { ReactElement } from 'react';

export function App(): ReactElement {
  return (
    <div className="app-shell">
      <aside className="navigation" aria-label="主导航">
        <div className="brand-mark" aria-hidden="true">
          BS
        </div>
        <div className="brand-name">BSClaw</div>
        <nav />
      </aside>
      <main className="workspace" />
    </div>
  );
}
