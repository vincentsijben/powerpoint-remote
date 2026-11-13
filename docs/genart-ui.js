// GenArt look only, no app logic: the dot spiral on the connect screen and the slide progress dots.
// It watches what app.js already puts on the page and never changes state or sends commands.
(function () {
  'use strict';
  const $ = (id) => document.getElementById(id);

  // The spiral moves only while the connect screen is visible (kind to older tablets).
  const view = $('connectView');
  const canvas = $('startDots');
  let stop = null;
  function syncSpiral() {
    const shown = !view.classList.contains('hidden');
    if (shown && !stop) {
      stop = GenArtDots.animate(canvas, 'PPT Remote', { count: 380, spacing: 10.5, cy: 0.44, fade: true });
    } else if (!shown && stop) {
      stop();
      stop = null;
    }
  }
  new MutationObserver(syncSpiral).observe(view, { attributes: true, attributeFilter: ['class'] });
  syncSpiral();

  // Slide progress as dots, read from the "3 / 22" counter. Long decks share MAX_DOTS dots.
  const MAX_DOTS = 12;
  const counter = $('slideNum');
  const dots = $('slideDots');
  let drawn = '';
  function syncDots() {
    const m = /^(\d+)\s*\/\s*(\d+)$/.exec(counter.textContent.trim());
    const total = m ? Number(m[2]) : 0;
    const n = Math.min(total, MAX_DOTS);
    const now = n > 1 ? Math.round(((Number(m[1]) - 1) / (total - 1)) * (n - 1)) : 0;
    const key = n + ':' + now;
    if (key === drawn) return;
    drawn = key;
    dots.textContent = '';
    for (let i = 0; i < n; i++) {
      const dot = document.createElement('i');
      if (i < now) dot.className = 'is-done';
      else if (i === now) dot.className = 'is-now';
      dots.appendChild(dot);
    }
  }
  new MutationObserver(syncDots).observe(counter, { childList: true, characterData: true, subtree: true });
  syncDots();
})();
