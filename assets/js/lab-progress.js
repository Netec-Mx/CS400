/* assets/js/lab-progress.js
   - Progreso por práctica (page.slug) y por tareas (ids del YAML)
   - Se considera "Completado" cuando TODAS las tareas están marcadas
   - Pinta badge en página del lab y en tarjetas de portada
*/

const STORAGE_KEY = "netec:labProgress:v1";

function safeParse(str, fallback) {
  try { return JSON.parse(str); } catch { return fallback; }
}

function loadState() {
  return safeParse(localStorage.getItem(STORAGE_KEY), { labs: {} });
}

function saveState(state) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

function ensureLab(state, labId) {
  if (!state.labs[labId]) {
    state.labs[labId] = { tasks: {}, completedAt: null, updatedAt: null };
  }
  return state.labs[labId];
}

function allDone(taskMap, taskIds) {
  return taskIds.length > 0 && taskIds.every(id => !!taskMap[id]);
}

function pct(checked, total) {
  if (!total) return 0;
  return Math.round((checked / total) * 100);
}

/* -------- Lab page (checklist) -------- */
function initLabChecklist() {
  const root = document.querySelector("[data-lab-progress][data-lab-id]");
  if (!root) return;

  const labId = root.getAttribute("data-lab-id");
  const inputs = Array.from(root.querySelectorAll("input[data-task-id]"));
  const taskIds = inputs.map(i => i.getAttribute("data-task-id"));

  const pctEl = root.querySelector("[data-lab-pct]");
  const badgeEl = root.querySelector("[data-lab-badge]");
  const markAllBtn = root.querySelector("[data-lab-mark-all]");
  const resetBtn = root.querySelector("[data-lab-reset]");

  const refresh = () => {
    const state = loadState();
    const lab = ensureLab(state, labId);

    inputs.forEach(i => {
      const tid = i.getAttribute("data-task-id");
      i.checked = !!lab.tasks[tid];
    });

    const checkedCount = taskIds.filter(tid => !!lab.tasks[tid]).length;
    const percent = pct(checkedCount, taskIds.length);
    if (pctEl) pctEl.textContent = `${percent}%`;

    const done = allDone(lab.tasks, taskIds);
    if (done) {
      if (!lab.completedAt) lab.completedAt = Date.now();
      if (badgeEl) badgeEl.hidden = false;
    } else {
      lab.completedAt = null;
      if (badgeEl) badgeEl.hidden = true;
    }

    lab.updatedAt = Date.now();
    saveState(state);
  };

  inputs.forEach(i => {
    i.addEventListener("change", () => {
      const state = loadState();
      const lab = ensureLab(state, labId);

      const tid = i.getAttribute("data-task-id");
      lab.tasks[tid] = i.checked;
      lab.updatedAt = Date.now();

      saveState(state);
      refresh();
      paintLabCards();
    });
  });

  if (markAllBtn) {
    markAllBtn.addEventListener("click", () => {
      const state = loadState();
      const lab = ensureLab(state, labId);

      taskIds.forEach(tid => (lab.tasks[tid] = true));
      lab.updatedAt = Date.now();

      saveState(state);
      refresh();
      paintLabCards();
    });
  }

  if (resetBtn) {
    resetBtn.addEventListener("click", () => {
      const state = loadState();
      state.labs[labId] = { tasks: {}, completedAt: null, updatedAt: Date.now() };
      saveState(state);

      refresh();
      paintLabCards();
    });
  }

  refresh();
}

/* -------- Portada/cards -------- */
function paintLabCards() {
  const cards = document.querySelectorAll("[data-lab-card][data-lab-id]");
  if (!cards.length) return;

  const state = loadState();

  cards.forEach(card => {
    const labId = card.getAttribute("data-lab-id");
    const badge = card.querySelector("[data-lab-card-badge]");

    const done = !!state.labs[labId]?.completedAt;

    if (badge) badge.hidden = !done;
    card.classList.toggle("is-done", done);
  });
}

document.addEventListener("DOMContentLoaded", () => {
  initLabChecklist();
  paintLabCards();
});
