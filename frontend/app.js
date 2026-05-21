/* ============================================
   GA Release Portal — Application Logic
   ============================================ */

// Configuration
const CONFIG = {
    apiBaseUrl: '/api',
    adoOrg: 'https://schouw.visualstudio.com',
    adoProject: 'Foodware 365 BC',
    gaReviewers: [
        'ks@aptean.com',
        'kkumar@aptean.com',
        'srs@aptean.com'
    ]
};

// Dashboard access — only these emails can see the Dashboard tab
const GA_ADMINS = [
    'ks@aptean.com',
    'krishna.s@aptean.com',
    'kkumar@aptean.com',
    'kapilkumar@aptean.com',
    'srs@aptean.com',
    'subhavarman.rs@aptean.com'
];

// State
let allRequests = [];
let epicBlocks = [];       // { id, epicNumber, epicTitle, apps: [{ repoId, repoName, branch }] }
let epicIdCounter = 0;
let cachedRepos = null;
let cachedEpics = null;    // Epics from ADO with GA Validation status
let branchCache = {};
let epicLoadingTeam = '';  // Track which team name was used to load epics
let cutoffOverrideGranted = false; // GA team override for cutoff
const CUTOFF_DISABLED = true;     // temporary: set false to re-enable cutoff enforcement
let attachedFiles = [];    // Files attached to the current submission
let activeRelease = null;  // { id, title } — set by GA Admin via Release Config subtab

// ---- Release Schedule (repeating yearly pattern) ----
// Each entry: { cutoffMonth, cutoffDay, releaseMonth, releaseDay, type, batchPrefix }
// Month is 0-indexed (0=Jan)
const RELEASE_SCHEDULE = [
    { cutoffMonth: 11, cutoffDay: 31, releaseMonth: 0,  releaseDay: 28, type: 'feature',   batchPrefix: 'MajJan' },
    { cutoffMonth: 1,  cutoffDay: 18, releaseMonth: 1,  releaseDay: 25, type: 'stability', batchPrefix: 'MinFeb' },
    { cutoffMonth: 2,  cutoffDay: 18, releaseMonth: 2,  releaseDay: 25, type: 'stability', batchPrefix: 'MinMar' },
    { cutoffMonth: 2,  cutoffDay: 30, releaseMonth: 3,  releaseDay: 22, type: 'feature',   batchPrefix: 'MajApr' },
    { cutoffMonth: 4,  cutoffDay: 20, releaseMonth: 4,  releaseDay: 27, type: 'stability', batchPrefix: 'MinMay' },
    { cutoffMonth: 5,  cutoffDay: 17, releaseMonth: 5,  releaseDay: 24, type: 'stability', batchPrefix: 'MinJun' },
    { cutoffMonth: 5,  cutoffDay: 29, releaseMonth: 6,  releaseDay: 22, type: 'feature',   batchPrefix: 'MajJul' },
    { cutoffMonth: 7,  cutoffDay: 19, releaseMonth: 7,  releaseDay: 26, type: 'stability', batchPrefix: 'MinAug' },
    { cutoffMonth: 8,  cutoffDay: 16, releaseMonth: 8,  releaseDay: 23, type: 'stability', batchPrefix: 'MinSep' },
    { cutoffMonth: 8,  cutoffDay: 28, releaseMonth: 9,  releaseDay: 21, type: 'feature',   batchPrefix: 'MajOct' },
    { cutoffMonth: 10, cutoffDay: 18, releaseMonth: 10, releaseDay: 25, type: 'stability', batchPrefix: 'MinNov' },
    { cutoffMonth: 11, cutoffDay: 30, releaseMonth: 0,  releaseDay: 27, type: 'feature',   batchPrefix: 'MajJan' },
];

/**
 * Find the next upcoming release for a given type ('feature' or 'stability').
 * Returns { releaseMonth, releaseYear, cutoffDate, isPastCutoff, batchBranch } or null.
 */
function getNextRelease(releaseType) {
    const now = new Date();
    const scheduleType = releaseType === 'feature' ? 'feature' : 'stability';

    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    // Build candidate releases for current year and next year
    const candidates = [];
    for (let yearOffset = 0; yearOffset <= 1; yearOffset++) {
        const baseYear = now.getFullYear() + yearOffset;
        for (const entry of RELEASE_SCHEDULE) {
            if (entry.type !== scheduleType) continue;
            const releaseYear = entry.releaseMonth < entry.cutoffMonth ? baseYear + 1 : baseYear;
            const cutoffYear = baseYear;
            const releaseDate = new Date(releaseYear, entry.releaseMonth, entry.releaseDay);
            const cutoffDate = new Date(cutoffYear, entry.cutoffMonth, entry.cutoffDay, 23, 59, 59);

            if (releaseDate >= today) {
                candidates.push({
                    releaseMonth: entry.releaseMonth,
                    releaseYear,
                    releaseDate,
                    cutoffDate,
                    isPastCutoff: !CUTOFF_DISABLED && (now > cutoffDate),
                    batchBranch: entry.batchPrefix + String(releaseYear).slice(2)
                });
            }
        }
    }

    candidates.sort((a, b) => a.releaseDate - b.releaseDate);
    return candidates.length > 0 ? candidates[0] : null;
}

/**
 * Format a cutoff date for display (includes time if not midnight).
 */
function formatCutoffDate(d) {
    const dateStr = d.toLocaleDateString('en-US', { day: 'numeric', month: 'long', year: 'numeric' });
    if (d.getHours() !== 0 || d.getMinutes() !== 0) {
        const timeStr = d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });
        return `${dateStr} at ${timeStr}`;
    }
    return dateStr;
}

// ---- Age-based retention for dashboard views ----
// Completed requests drop off after 30 days; everything else after 45 days.
const RETENTION_DAYS = { completed: 30, default: 45 };

function isRequestExpired(req) {
    if (!req || !req.submittedAt) return false;
    const submitted = new Date(req.submittedAt);
    if (isNaN(submitted)) return false;
    const ageDays = (Date.now() - submitted.getTime()) / (1000 * 60 * 60 * 24);
    const limit = req.status === 'completed' ? RETENTION_DAYS.completed : RETENTION_DAYS.default;
    return ageDays > limit;
}

// ---- Dashboard Access Control ----
function isAdmin() {
    const email = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '').toLowerCase();
    return GA_ADMINS.includes(email);
}

function applyDashboardACL() {
    const admin = isAdmin();
    const gaBtn = document.querySelector('.sidebar-nav-btn[data-view="ga-initial"]');
    if (gaBtn) {
        gaBtn.style.display = admin ? '' : 'none';
    }
    // Mark body so CSS can hide GA-only columns/actions for the Handover view
    document.body.classList.toggle('handover-view', !admin);

    // Service Pack release type is restricted to GA admins on the New Request form.
    // Hide it from the dropdown for everyone else.
    const rtSelect = document.getElementById('releaseType');
    if (rtSelect) {
        const spOpt = rtSelect.querySelector('option[value="service-pack"]');
        if (spOpt) spOpt.style.display = admin ? '' : 'none';
        // If a non-admin had service-pack already selected, reset to placeholder
        if (!admin && rtSelect.value === 'service-pack') {
            rtSelect.value = '';
        }
    }

    // Release Config subtab is admin-only
    const releaseConfigBtn = document.getElementById('releaseConfigTabBtn');
    if (releaseConfigBtn) releaseConfigBtn.style.display = admin ? '' : 'none';
}

// ---- Canvas particle network background ----
function initAppParticles() {
    const canvas = document.getElementById('appParticleCanvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');

    const COLORS = ['#6366f1', '#8b5cf6', '#06b6d4', '#3b82f6', '#a855f7', '#ec4899'];
    const COUNT  = 75;
    const CONNECT = 165;

    let W, H, particles;

    function resize() {
        W = canvas.width  = window.innerWidth;
        H = canvas.height = window.innerHeight;
    }

    function make() {
        particles = Array.from({ length: COUNT }, () => ({
            x:  Math.random() * W,
            y:  Math.random() * H,
            vx: (Math.random() - 0.5) * 0.32,
            vy: (Math.random() - 0.5) * 0.32,
            r:  Math.random() * 1.8 + 1.2,
            a:  Math.random() * 0.5 + 0.3,
            c:  COLORS[Math.floor(Math.random() * COLORS.length)]
        }));
    }

    function draw() {
        ctx.clearRect(0, 0, W, H);

        // Connections
        for (let i = 0; i < COUNT; i++) {
            for (let j = i + 1; j < COUNT; j++) {
                const dx = particles[i].x - particles[j].x;
                const dy = particles[i].y - particles[j].y;
                const d2 = dx * dx + dy * dy;
                if (d2 < CONNECT * CONNECT) {
                    const a = (1 - Math.sqrt(d2) / CONNECT) * 0.22;
                    ctx.strokeStyle = `rgba(99,102,241,${a})`;
                    ctx.lineWidth = 0.7;
                    ctx.beginPath();
                    ctx.moveTo(particles[i].x, particles[i].y);
                    ctx.lineTo(particles[j].x, particles[j].y);
                    ctx.stroke();
                }
            }
        }

        // Nodes
        for (const p of particles) {
            ctx.save();
            ctx.shadowBlur  = 10;
            ctx.shadowColor = p.c;
            ctx.globalAlpha = p.a;
            ctx.fillStyle   = p.c;
            ctx.beginPath();
            ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();
        }
    }

    function update() {
        for (const p of particles) {
            p.x += p.vx;
            p.y += p.vy;
            if (p.x < 0 || p.x > W) p.vx *= -1;
            if (p.y < 0 || p.y > H) p.vy *= -1;
        }
    }

    let raf;
    function loop() {
        update();
        draw();
        raf = requestAnimationFrame(loop);
    }

    // Pause when tab is hidden to save resources
    document.addEventListener('visibilitychange', () => {
        if (document.hidden) { cancelAnimationFrame(raf); }
        else { loop(); }
    });

    // Respect prefers-reduced-motion
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    resize();
    make();
    loop();
    window.addEventListener('resize', () => { resize(); make(); });
}

// ---- Sidebar collapse ----
function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    sidebar.classList.toggle('collapsed');
    localStorage.setItem('sidebarCollapsed', sidebar.classList.contains('collapsed'));
}

function restoreSidebarState() {
    if (localStorage.getItem('sidebarCollapsed') === 'true') {
        const sidebar = document.getElementById('sidebar');
        if (sidebar) sidebar.classList.add('collapsed');
    }
}

// ---- Theme toggle (dark / light) ----
function toggleTheme() {
    const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
    const next = isDark ? 'light' : 'dark';
    applyTheme(next);
    localStorage.setItem('theme', next);
}

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    const btn = document.getElementById('themeToggleBtn');
    if (!btn) return;
    const label = btn.querySelector('.theme-label');
    if (theme === 'dark') {
        if (label) label.textContent = 'Light Mode';
        btn.title = 'Switch to light mode';
    } else {
        if (label) label.textContent = 'Dark Mode';
        btn.title = 'Switch to dark mode';
    }
}

function initTheme() {
    const saved = localStorage.getItem('theme') || 'light';
    applyTheme(saved);
}

// ---- View Navigation ----
function showView(viewName) {
    if (viewName === 'ga-initial' && !isAdmin()) {
        viewName = 'submit';
    }

    document.querySelectorAll('.content').forEach(el => el.style.display = 'none');
    document.querySelectorAll('.sidebar-nav-btn').forEach(el => el.classList.remove('active'));

    const view = document.getElementById(`view-${viewName}`);
    const btn = document.querySelector(`.sidebar-nav-btn[data-view="${viewName}"]`);

    if (view) view.style.display = 'block';
    if (btn) btn.classList.add('active');

    if (viewName === 'dashboard') {
        loadRequests();
    }
    if (viewName === 'ga-initial') {
        loadGARequests();
    }
    if (viewName === 'submit' && activeRelease) {
        loadEpicsFromRelease();
    }
}

// ---- Repo & Branch Loading ----
async function loadRepos() {
    if (cachedRepos) return cachedRepos;
    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetRepos`);
        if (!response.ok) throw new Error('API error');
        cachedRepos = await response.json();
        return cachedRepos;
    } catch (err) {
        console.error('Failed to load repos:', err);
        showToast('Failed to load repositories from ADO', 'error');
        cachedRepos = [];
        return cachedRepos;
    }
}

async function loadBranches(repoId) {
    if (branchCache[repoId]) return branchCache[repoId];
    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetBranches?repoId=${encodeURIComponent(repoId)}`);
        if (!response.ok) throw new Error('API error');
        branchCache[repoId] = await response.json();
        return branchCache[repoId];
    } catch (err) {
        console.error('Failed to load branches:', err);
        branchCache[repoId] = [];
        return branchCache[repoId];
    }
}

// ---- Release-type helpers ----

function needsActiveRelease(type) {
    return type === 'feature' || type === 'stability';
}

function getCurrentReleaseType() {
    return document.getElementById('releaseType')?.value || '';
}

// ---- Active Release Config ----

async function loadActiveRelease() {
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease`);
        if (!res.ok) return;
        const data = await res.json();
        activeRelease = (data && data.id) ? data : null;
    } catch (e) {
        console.warn('Could not load active release config:', e);
        activeRelease = null;
    }
    renderReleaseBanner();
    renderReleaseConfigPanel();
}

function renderReleaseBanner() {
    const loading = document.getElementById('releaseBannerLoading');
    const text    = document.getElementById('releaseBannerText');
    if (!text) return;
    if (loading) loading.style.display = 'none';
    text.style.display = '';
    const banner = document.getElementById('releaseBanner');
    const type   = getCurrentReleaseType();

    if (!needsActiveRelease(type) && type !== '') {
        // Hotfix / Service-Pack — release WI not required
        text.innerHTML = `<em class="release-wi-none">Not required for <strong>${type}</strong> release type.</em>`;
        if (banner) banner.className = 'release-wi-field na';
        return;
    }

    if (activeRelease) {
        text.innerHTML = `<span class="release-wi-badge">#${activeRelease.id}</span><strong>${activeRelease.title}</strong>`;
        if (banner) banner.className = 'release-wi-field active';
    } else {
        text.innerHTML = `<em class="release-wi-none">No active release configured &mdash; GA Admin must set one via <strong>GA-Initial &rarr; Release Config</strong>.</em>`;
        if (banner) banner.className = needsActiveRelease(type) ? 'release-wi-field required-empty' : 'release-wi-field empty';
    }
}

function renderReleaseConfigPanel() {
    const display    = document.getElementById('releaseConfigDisplay');
    const clearBtn   = document.getElementById('clearReleaseBtn');
    if (!display) return;
    if (activeRelease) {
        display.innerHTML = `<strong>#${activeRelease.id}</strong> — ${activeRelease.title}`;
        if (clearBtn) clearBtn.style.display = '';
    } else {
        display.innerHTML = '<em style="opacity:0.55;">None set — submitters see all epics</em>';
        if (clearBtn) clearBtn.style.display = 'none';
    }
}

function onReleaseWiInput() {
    const input = document.getElementById('releaseWiInput');
    input.value = input.value.replace(/\D/g, '');
    const hasVal = input.value.length > 0;
    document.getElementById('releaseWiPreviewBtn').disabled = !hasVal;
    document.getElementById('releaseWiSaveBtn').disabled = !hasVal;
    document.getElementById('releaseWiPreview').style.display = 'none';
}

async function previewReleaseWi() {
    const id = document.getElementById('releaseWiInput').value.trim();
    if (!id) return;
    const preview = document.getElementById('releaseWiPreview');
    preview.style.display = '';
    preview.className = 'release-config-preview loading';
    preview.textContent = 'Fetching…';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease?preview=${encodeURIComponent(id)}`);
        let data = {};
        try { data = await res.json(); } catch (_) { /* non-JSON body */ }
        if (!res.ok) throw new Error(data.message || data.Message || `HTTP ${res.status}`);
        preview.className = 'release-config-preview success';
        preview.textContent = `✓  #${data.id} — ${data.title}`;
    } catch (e) {
        preview.className = 'release-config-preview error';
        preview.textContent = `✗  ${e.message}`;
    }
}

async function fetchAndSaveRelease() {
    const id = document.getElementById('releaseWiInput').value.trim();
    if (!id) { showToast('Please enter a Work Item ID', 'error'); return; }
    const saveBtn = document.getElementById('releaseWiSaveBtn');
    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving…';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id })
        });
        let data = {};
        try { data = await res.json(); } catch (_) { /* non-JSON body */ }
        if (!res.ok) throw new Error(data.message || data.Message || `HTTP ${res.status}`);
        activeRelease = { id: data.id, title: data.title };
        renderReleaseBanner();
        renderReleaseConfigPanel();
        document.getElementById('releaseWiInput').value = '';
        document.getElementById('releaseWiPreview').style.display = 'none';
        onReleaseWiInput();
        showToast(`Active release set to #${data.id}: ${data.title}`, 'success');
        cachedEpics = null;
        epicLoadingTeam = '';
    } catch (e) {
        console.error('[fetchAndSaveRelease]', e);
        showToast(`Failed to save release: ${e.message}`, 'error');
        saveBtn.disabled = false;
        saveBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor"><path d="M13.854 3.646a.5.5 0 0 1 0 .708l-7 7a.5.5 0 0 1-.708 0l-3.5-3.5a.5.5 0 1 1 .708-.708L6.5 10.293l6.646-6.647a.5.5 0 0 1 .708 0z"/></svg> Save &amp; Activate';
    }
}

async function clearActiveRelease() {
    if (!confirm('Clear the active release? Submitters will see all GA-ready epics again.')) return;
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease`, { method: 'DELETE' });
        if (!res.ok) throw new Error('Clear failed');
        activeRelease = null;
        renderReleaseBanner();
        renderReleaseConfigPanel();
        showToast('Active release cleared.', 'success');
        cachedEpics = null;
        epicLoadingTeam = '';
    } catch (e) {
        showToast(`Failed to clear: ${e.message}`, 'error');
    }
}

// ---- Task Parent WI Config ----

let taskParentWi = null;  // { id, title } — changes every release month

async function loadTaskParentWi() {
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease?type=taskParent`);
        if (!res.ok) return;
        const data = await res.json();
        taskParentWi = (data && data.id) ? data : null;
    } catch (e) {
        console.warn('Could not load task parent WI config:', e);
        taskParentWi = null;
    }
    renderTaskParentWiPanel();
}

function renderTaskParentWiPanel() {
    const display  = document.getElementById('taskParentWiDisplay');
    const clearBtn = document.getElementById('clearTaskParentWiBtn');
    if (!display) return;
    if (taskParentWi) {
        display.innerHTML = `<strong>#${taskParentWi.id}</strong> — ${taskParentWi.title}`;
        if (clearBtn) clearBtn.style.display = '';
    } else {
        display.innerHTML = '<em style="opacity:0.55;">None set — GA tasks won\'t be parented to a Release WI</em>';
        if (clearBtn) clearBtn.style.display = 'none';
    }
}

function onTaskParentWiInput() {
    const input = document.getElementById('taskParentWiInput');
    input.value = input.value.replace(/\D/g, '');
    const hasVal = input.value.length > 0;
    document.getElementById('taskParentWiPreviewBtn').disabled = !hasVal;
    document.getElementById('taskParentWiSaveBtn').disabled = !hasVal;
    document.getElementById('taskParentWiPreview').style.display = 'none';
}

async function previewTaskParentWi() {
    const id = document.getElementById('taskParentWiInput').value.trim();
    if (!id) return;
    const preview = document.getElementById('taskParentWiPreview');
    preview.style.display = '';
    preview.className = 'release-config-preview loading';
    preview.textContent = 'Fetching…';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease?preview=${encodeURIComponent(id)}`);
        let data = {};
        try { data = await res.json(); } catch (_) { /* non-JSON body */ }
        if (!res.ok) throw new Error(data.message || data.Message || `HTTP ${res.status}`);
        preview.className = 'release-config-preview success';
        preview.textContent = `✓  #${data.id} — ${data.title}`;
    } catch (e) {
        preview.className = 'release-config-preview error';
        preview.textContent = `✗  ${e.message}`;
    }
}

async function saveTaskParentWi() {
    const id = document.getElementById('taskParentWiInput').value.trim();
    if (!id) { showToast('Please enter a Work Item ID', 'error'); return; }
    const saveBtn = document.getElementById('taskParentWiSaveBtn');
    saveBtn.disabled = true;
    saveBtn.textContent = 'Saving…';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id, type: 'taskParent' })
        });
        let data = {};
        try { data = await res.json(); } catch (_) { /* non-JSON body */ }
        if (!res.ok) throw new Error(data.message || data.Message || `HTTP ${res.status}`);
        taskParentWi = { id: data.id, title: data.title };
        renderTaskParentWiPanel();
        document.getElementById('taskParentWiInput').value = '';
        document.getElementById('taskParentWiPreview').style.display = 'none';
        onTaskParentWiInput();
        showToast(`Task parent WI set to #${data.id}: ${data.title}`, 'success');
    } catch (e) {
        console.error('[saveTaskParentWi]', e);
        showToast(`Failed to save task parent WI: ${e.message}`, 'error');
        saveBtn.disabled = false;
        saveBtn.innerHTML = '<svg width="13" height="13" viewBox="0 0 16 16" fill="currentColor"><path d="M13.854 3.646a.5.5 0 0 1 0 .708l-7 7a.5.5 0 0 1-.708 0l-3.5-3.5a.5.5 0 1 1 .708-.708L6.5 10.293l6.646-6.647a.5.5 0 0 1 .708 0z"/></svg> Save';
    }
}

async function clearTaskParentWi() {
    if (!confirm('Clear the task parent WI? New GA tasks will be parented to the Epic instead.')) return;
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetActiveRelease?type=taskParent`, { method: 'DELETE' });
        if (!res.ok) throw new Error('Clear failed');
        taskParentWi = null;
        renderTaskParentWiPanel();
        showToast('Task parent WI cleared.', 'success');
    } catch (e) {
        showToast(`Failed to clear: ${e.message}`, 'error');
    }
}

// ---- Epic Loading from ADO ----

function showEpicBlocked() {
    const section   = document.getElementById('epicSection');
    const container = document.getElementById('epicBlocksContainer');
    const hint      = document.getElementById('epicSectionHint');
    section.style.display = '';
    container.innerHTML = `
        <div class="epic-blocked">
            <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 1.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zm-.75 3.25h1.5v4h-1.5v-4zm0 5h1.5v1.5h-1.5v-1.5z"/></svg>
            <span>Active Release is not configured. A GA Admin must set it via <strong>GA-Initial &rarr; Release Config</strong> before you can select epics.</span>
        </div>`;
    if (hint) hint.textContent = 'Epics are sourced from the active Release WI (Factory Status = "70 GA Validation").';
}

async function loadEpics(teamName) {
    const type = getCurrentReleaseType();

    // Feature / Stability: epics must come from the active release WI
    if (needsActiveRelease(type)) {
        if (!activeRelease) {
            showEpicBlocked();
            return;
        }
        await loadEpicsFromRelease();
        return;
    }

    // Hotfix / Service-Pack (or no type yet): use team-name filter
    if (!teamName) {
        cachedEpics = null;
        epicLoadingTeam = '';
        hideEpicSection();
        return;
    }

    // Don't reload if same team
    if (epicLoadingTeam === teamName && cachedEpics !== null) return;
    epicLoadingTeam = teamName;

    const section   = document.getElementById('epicSection');
    const container = document.getElementById('epicBlocksContainer');
    const hint      = document.getElementById('epicSectionHint');
    section.style.display = '';
    container.innerHTML = '<div class="epic-loading"><span class="spinner"></span> Loading epics with GA Validation status...</div>';
    if (hint) hint.textContent = 'Showing your team\'s epics with Factory Status = "70 GA Validation". Each epic can contain multiple apps.';

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetEpics?teamName=${encodeURIComponent(teamName)}`);
        if (!response.ok) throw new Error('API error');
        cachedEpics = await response.json();
    } catch (err) {
        console.error('Failed to load epics:', err);
        cachedEpics = [];
    }

    // Clear existing epic blocks when team changes
    epicBlocks = [];
    epicIdCounter = 0;

    if (cachedEpics.length === 0) {
        container.innerHTML = '<div class="empty-epic-hint">No epics found with <strong>"70 GA Validations"</strong> status for this team.</div>';
    } else {
        renderEpicBlocks();
    }
}

async function loadEpicsFromRelease() {
    if (!activeRelease) return;

    // Don't reload if already cached for this release
    const cacheKey = `release:${activeRelease.id}`;
    if (epicLoadingTeam === cacheKey && cachedEpics !== null) {
        showEpicSectionIfNeeded();
        return;
    }
    epicLoadingTeam = cacheKey;

    const section   = document.getElementById('epicSection');
    const container = document.getElementById('epicBlocksContainer');
    const hint      = document.getElementById('epicSectionHint');
    section.style.display = '';
    container.innerHTML = '<div class="epic-loading"><span class="spinner"></span> Loading epics from release…</div>';
    if (hint) hint.textContent = `Showing epics under Release #${activeRelease.id} — ${activeRelease.title} with Factory Status = "70 GA Validation".`;

    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetEpics?releaseId=${encodeURIComponent(activeRelease.id)}`);
        if (!res.ok) throw new Error('API error');
        cachedEpics = await res.json();
    } catch (err) {
        console.error('Failed to load epics from release:', err);
        cachedEpics = [];
    }

    epicBlocks = [];
    epicIdCounter = 0;

    if (cachedEpics.length === 0) {
        container.innerHTML = '<div class="empty-epic-hint">No epics with <strong>"70 GA Validation"</strong> status found under this release.</div>';
    } else {
        renderEpicBlocks();
    }
}

function showEpicSectionIfNeeded() {
    const section = document.getElementById('epicSection');
    if (section && cachedEpics && cachedEpics.length > 0) {
        section.style.display = '';
    }
}

function hideEpicSection() {
    const section = document.getElementById('epicSection');
    if (section) section.style.display = 'none';
}

let teamNameDebounce = null;
let adoTeams = [];         // Cached list of ADO teams
let teamDropdownOpen = false;

// Fetch teams from ADO on page load
async function fetchAdoTeams() {
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetTeams`);
        if (res.ok) {
            const data = await res.json();
            adoTeams = (data.teams || []).map(t => t.name);
        }
    } catch (e) {
        console.warn('Failed to load ADO teams:', e);
    }
}

function onTeamSearchInput() {
    const input = document.getElementById('teamName');
    const query = input.value.trim().toLowerCase();
    renderTeamDropdown(query);
    // Also trigger epic loading with debounce
    clearTimeout(teamNameDebounce);
    teamNameDebounce = setTimeout(() => loadEpics(input.value.trim()), 400);
}

function onTeamSearchFocus() {
    const input = document.getElementById('teamName');
    renderTeamDropdown(input.value.trim().toLowerCase());
}

function onTeamSearchBlur() {
    // Delay hiding so click on dropdown item registers
    setTimeout(() => {
        const dropdown = document.getElementById('teamDropdown');
        if (dropdown) dropdown.style.display = 'none';
        teamDropdownOpen = false;
    }, 200);
}

function renderTeamDropdown(query) {
    const dropdown = document.getElementById('teamDropdown');
    if (!dropdown) return;

    const filtered = query
        ? adoTeams.filter(t => t.toLowerCase().includes(query))
        : adoTeams;

    if (filtered.length === 0) {
        dropdown.style.display = 'none';
        teamDropdownOpen = false;
        return;
    }

    dropdown.innerHTML = filtered.map(t =>
        `<div class="team-dropdown-item" onmousedown="selectTeam('${sanitize(t)}')">${highlightMatch(t, query)}</div>`
    ).join('');
    dropdown.style.display = 'block';
    teamDropdownOpen = true;
}

function highlightMatch(text, query) {
    if (!query) return sanitize(text);
    const idx = text.toLowerCase().indexOf(query);
    if (idx === -1) return sanitize(text);
    const before = text.substring(0, idx);
    const match = text.substring(idx, idx + query.length);
    const after = text.substring(idx + query.length);
    return `${sanitize(before)}<strong>${sanitize(match)}</strong>${sanitize(after)}`;
}

function selectTeam(name) {
    const input = document.getElementById('teamName');
    input.value = name;
    const dropdown = document.getElementById('teamDropdown');
    if (dropdown) dropdown.style.display = 'none';
    teamDropdownOpen = false;
    // Trigger epic load for selected team
    clearTimeout(teamNameDebounce);
    loadEpics(name);
}

function onTeamNameChange() {
    clearTimeout(teamNameDebounce);
    const teamName = document.getElementById('teamName').value.trim();
    teamNameDebounce = setTimeout(() => loadEpics(teamName), 400);
}

// ---- CC Email Tags ----
let ccEmailList = [];
let ccSuggestionIndex = -1;
let ccSearchTimer = null;
let ccCachedResults = [];

function onCcInputChange() {
    const input = document.getElementById('ccEmailInput');
    const query = input.value.trim().toLowerCase();
    const sugBox = document.getElementById('ccSuggestions');

    if (query.length < 2) {
        sugBox.classList.remove('show');
        ccSuggestionIndex = -1;
        return;
    }

    // Debounce API calls — wait 300ms after last keystroke
    clearTimeout(ccSearchTimer);
    ccSearchTimer = setTimeout(() => searchCcUsers(query), 300);
}

async function searchCcUsers(query) {
    const sugBox = document.getElementById('ccSuggestions');

    // 1. Try Microsoft Graph (User.Read.All) for full org search
    let matches = null;
    let graphError = null;
    try {
        if (typeof searchApteanPeople === 'function') {
            matches = await searchApteanPeople(query);
        }
    } catch (e) {
        console.warn('Graph CC search failed; falling back.', e);
        graphError = e.message || 'Microsoft Graph error';
        matches = null;
    }

    // 2. Fallback: legacy backend (ADO User Entitlements) if Graph isn't available
    let usedFallback = false;
    if (!Array.isArray(matches)) {
        usedFallback = true;
        try {
            const response = await fetch(`${CONFIG.apiBaseUrl}/SearchUsers?q=${encodeURIComponent(query)}`);
            if (response.ok) matches = await response.json();
        } catch (err) {
            console.warn('Backend CC fallback failed:', err);
        }
    }

    if (!Array.isArray(matches)) matches = [];
    ccCachedResults = matches;

    // Filter out already-added emails
    const filtered = matches.filter(p => !ccEmailList.includes(p.email));

    let header = '';
    if (usedFallback && graphError) {
        header = `<div class="cc-suggestion-item cc-no-results" style="color:#f87171">Graph search failed: ${sanitize(graphError)} — using fallback search</div>`;
    } else if (usedFallback) {
        header = '<div class="cc-suggestion-item cc-no-results" style="color:#f59e0b">Not signed in to Microsoft Graph — using fallback search</div>';
    }

    if (filtered.length === 0) {
        sugBox.innerHTML = header || '<div class="cc-suggestion-item cc-no-results">No matching users found</div>';
        sugBox.classList.add('show');
        ccSuggestionIndex = -1;
        return;
    }

    sugBox.innerHTML = header + filtered.map(m =>
        `<div class="cc-suggestion-item" data-email="${sanitize(m.email)}" onclick="addCcTag('${sanitize(m.email)}', '${sanitize(m.name).replace(/'/g, '&#39;')}')">
            <span class="cc-suggestion-name">${sanitize(m.name)}</span>
            <span class="cc-suggestion-email">${sanitize(m.email)}</span>
        </div>`
    ).join('');
    sugBox.classList.add('show');
    ccSuggestionIndex = -1;
}

function onCcInputKeydown(e) {
    const sugBox = document.getElementById('ccSuggestions');
    const items = sugBox.querySelectorAll('.cc-suggestion-item');

    if (e.key === 'ArrowDown') {
        e.preventDefault();
        ccSuggestionIndex = Math.min(ccSuggestionIndex + 1, items.length - 1);
        items.forEach((it, i) => it.classList.toggle('active', i === ccSuggestionIndex));
    } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        ccSuggestionIndex = Math.max(ccSuggestionIndex - 1, 0);
        items.forEach((it, i) => it.classList.toggle('active', i === ccSuggestionIndex));
    } else if (e.key === 'Enter') {
        e.preventDefault();
        if (ccSuggestionIndex >= 0 && items[ccSuggestionIndex]) {
            items[ccSuggestionIndex].click();
        } else {
            // Allow manual aptean email entry
            const val = document.getElementById('ccEmailInput').value.trim();
            if (val && val.includes('@aptean.com')) {
                addCcTag(val, val.split('@')[0]);
            }
        }
    } else if (e.key === 'Backspace' && !document.getElementById('ccEmailInput').value && ccEmailList.length) {
        removeCcTag(ccEmailList[ccEmailList.length - 1]);
    }
}

function addCcTag(email, name) {
    email = email.toLowerCase();
    if (ccEmailList.includes(email)) return;
    // Don't add the submitter's own email
    const submitterEmail = document.getElementById('submitterEmail').value.toLowerCase();
    if (email === submitterEmail) {
        showToast('You cannot CC yourself', 'error');
        return;
    }
    ccEmailList.push(email);
    // Cache person info for tag display
    if (!ccCachedResults.find(p => p.email === email)) {
        ccCachedResults.push({ name, email });
    }
    renderCcTags();
    document.getElementById('ccEmailInput').value = '';
    document.getElementById('ccSuggestions').classList.remove('show');
    document.getElementById('ccEmails').value = ccEmailList.join(',');
}

function removeCcTag(email) {
    ccEmailList = ccEmailList.filter(e => e !== email);
    renderCcTags();
    document.getElementById('ccEmails').value = ccEmailList.join(',');
}

function renderCcTags() {
    const container = document.getElementById('ccTags');
    container.innerHTML = ccEmailList.map(email => {
        const person = ccCachedResults.find(p => p.email === email);
        const label = person ? person.name : email;
        return `<span class="cc-tag">${sanitize(label)} <button type="button" class="cc-tag-remove" onclick="removeCcTag('${email}')">&times;</button></span>`;
    }).join('');
}

// ---- Release Type Change (Hotfix fields toggle + auto-assign target month) ----
function onReleaseTypeChange() {
    const type = document.getElementById('releaseType').value;
    const hotfixFields = document.getElementById('hotfixFields');
    hotfixFields.style.display = type === 'hotfix' ? '' : 'none';

    // Toggle required on hotfix-only fields
    document.getElementById('hotfixApprovedByInput').required = type === 'hotfix';
    document.getElementById('approvalMail').required = type === 'hotfix';

    const targetSelect = document.getElementById('targetMonth');
    const cutoffBanner = document.getElementById('cutoffBanner');
    const submitBtn = document.getElementById('submitBtn');

    // Reset cutoff state
    if (cutoffBanner) {
        cutoffBanner.style.display = 'none';
        cutoffBanner.classList.remove('cutoff-approved', 'cutoff-rejected');
    }
    cutoffOverrideGranted = false;
    pendingOverrideId = null;
    stopOverridePolling();

    // Auto-assign target month for feature/stability only
    if (type === 'feature' || type === 'stability') {
        const next = getNextRelease(type);
        if (next) {
            // Format: "MAY GA2026" (single space, GA prefix on year). This becomes
            // the source for the two task tags created later: "MAY" + "GA2026".
            const monthValue = `${MONTH_NAMES[next.releaseMonth]} GA${next.releaseYear}`;
            let opt = targetSelect.querySelector(`option[value="${monthValue}"]`);
            if (!opt) {
                opt = document.createElement('option');
                opt.value = monthValue;
                opt.textContent = monthValue;
                targetSelect.appendChild(opt);
            }
            targetSelect.value = monthValue;
            targetSelect.disabled = true; // Lock it for feature/stability

            // Check cutoff enforcement
            if (next.isPastCutoff) {
                const cutoffStr = formatCutoffDate(next.cutoffDate);
                if (cutoffBanner) {
                    cutoffBanner.innerHTML = `
                        <div class="cutoff-icon">&#9888;</div>
                        <div class="cutoff-text">
                            <strong>Cut-off date has passed</strong> (${cutoffStr})
                            <br>Submission for <strong>${MONTH_NAMES[next.releaseMonth]} ${next.releaseYear}</strong> is closed.
                            <br>Please provide a reason and request an override from the GA team.
                        </div>
                        <div class="cutoff-reason-area">
                            <textarea id="cutoffReason" class="cutoff-reason-input" rows="2" placeholder="Enter reason for late submission..."></textarea>
                            <button type="button" class="btn btn-sm btn-warning" onclick="requestCutoffOverride('${monthValue}', '${cutoffStr}')">
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M0 2.5A2.5 2.5 0 0 1 2.5 0h11A2.5 2.5 0 0 1 16 2.5v8.44c0 .58-.212 1.14-.593 1.575l-2.272 2.596A2.5 2.5 0 0 1 11.228 16H2.5A2.5 2.5 0 0 1 0 13.5v-11z"/></svg>
                                Request Override via Teams
                            </button>
                        </div>`;
                    cutoffBanner.style.display = 'flex';
                }
                submitBtn.disabled = true;
            } else {
                submitBtn.disabled = false;
            }
        }
    } else if (type === 'hotfix') {
        // Hotfix: always targets the current month, non-editable
        const now = new Date();
        const monthValue = `${MONTH_NAMES[now.getMonth()]} GA${now.getFullYear()}`;
        let opt = targetSelect.querySelector(`option[value="${monthValue}"]`);
        if (!opt) {
            opt = document.createElement('option');
            opt.value = monthValue;
            opt.textContent = monthValue;
            targetSelect.appendChild(opt);
        }
        targetSelect.value = monthValue;
        targetSelect.disabled = true;
        submitBtn.disabled = false;
    } else {
        // service-pack — free selection
        targetSelect.disabled = false;
        submitBtn.disabled = false;
    }

    // Re-evaluate epic section and release WI field for the new type
    renderReleaseBanner();
    const teamName = document.getElementById('teamName').value.trim();
    cachedEpics = null;
    epicLoadingTeam = '';
    epicBlocks = [];
    epicIdCounter = 0;
    if (needsActiveRelease(type)) {
        // Feature/Stability: show epics from release (or blocked state)
        if (activeRelease) {
            loadEpicsFromRelease();
        } else {
            showEpicBlocked();
        }
    } else if (type) {
        // Hotfix/Service-Pack: show epics by team name if already entered
        if (teamName) {
            loadEpics(teamName);
        } else {
            hideEpicSection();
        }
    } else {
        hideEpicSection();
    }
}

let pendingOverrideId = null;
let overridePollTimer = null;

async function requestCutoffOverride(monthValue, cutoffStr) {
    const reason = (document.getElementById('cutoffReason')?.value || '').trim();
    if (!reason) {
        showToast('Please enter a reason for the override request.', 'error');
        document.getElementById('cutoffReason')?.focus();
        return;
    }

    const userEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : 'unknown');
    const teamName = document.getElementById('teamName').value.trim() || 'Unknown Team';
    const releaseType = document.getElementById('releaseType').value;
    const typeLabel = releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor';

    try {
        const overrideAbort = new AbortController();
        const overrideTimer = setTimeout(() => overrideAbort.abort(), 30000);
        let res;
        try {
            res = await fetch(`${CONFIG.apiBaseUrl}/SubmitRequest`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    overrideRequest: true,
                    teamName,
                    submitterEmail: userEmail,
                    releaseType,
                    typeLabel,
                    targetMonth: monthValue,
                    cutoffDate: cutoffStr,
                    reason,
                    portalBaseUrl: window.location.origin
                }),
                signal: overrideAbort.signal
            });
        } finally {
            clearTimeout(overrideTimer);
        }
        if (!res.ok) throw new Error('Request failed');

        const data = await res.json();
        pendingOverrideId = data.overrideId || null;

        renderOverrideWaitingBanner(monthValue, cutoffStr, reason);
        if (pendingOverrideId) startOverridePolling();

        showToast('Override request posted to GA Teams channel. Waiting for approval...', 'info');
    } catch (e) {
        showToast('Failed to post override request. Please contact GA team directly via Teams.', 'error');
    }
}

function renderOverrideWaitingBanner(monthValue, cutoffStr, reason) {
    const banner = document.getElementById('cutoffBanner');
    if (!banner) return;
    banner.innerHTML = `
        <div class="cutoff-icon"><span class="spinner"></span></div>
        <div class="cutoff-text">
            <strong>Override request submitted</strong>
            <br>Posted to GA Teams channel — waiting for approval.
            <br><span style="opacity:.75;font-size:13px;">Cut-off: ${cutoffStr} · Reason: ${sanitize(reason)}</span>
        </div>`;
    banner.style.display = 'flex';
}

function renderOverrideApprovedBanner(decidedBy, decidedAt) {
    const banner = document.getElementById('cutoffBanner');
    if (!banner) return;
    const when = decidedAt ? new Date(decidedAt).toLocaleString() : '';
    banner.classList.add('cutoff-approved');
    banner.innerHTML = `
        <div class="cutoff-icon">&#10004;</div>
        <div class="cutoff-text">
            <strong>Override approved</strong> — you can submit the request now.
            ${when ? `<br><span style="opacity:.75;font-size:13px;">Approved ${when}</span>` : ''}
        </div>`;
    banner.style.display = 'flex';
}

function renderOverrideRejectedBanner(decidedAt) {
    const banner = document.getElementById('cutoffBanner');
    if (!banner) return;
    const when = decidedAt ? new Date(decidedAt).toLocaleString() : '';
    banner.classList.add('cutoff-rejected');
    banner.innerHTML = `
        <div class="cutoff-icon">&#10006;</div>
        <div class="cutoff-text">
            <strong>Override rejected</strong> by GA team.
            ${when ? `<br><span style="opacity:.75;font-size:13px;">Rejected ${when}</span>` : ''}
            <br>Submission for this month remains closed.
        </div>`;
    banner.style.display = 'flex';
}

function startOverridePolling() {
    stopOverridePolling();
    overridePollTimer = setInterval(checkOverrideStatus, 8000);
    checkOverrideStatus(); // immediate first check
}

function stopOverridePolling() {
    if (overridePollTimer) {
        clearInterval(overridePollTimer);
        overridePollTimer = null;
    }
}

async function checkOverrideStatus() {
    if (!pendingOverrideId) return;
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetOverrideStatus?id=${encodeURIComponent(pendingOverrideId)}`);
        if (!res.ok) return;
        const data = await res.json();

        if (data.status === 'approved') {
            stopOverridePolling();
            cutoffOverrideGranted = true;
            const submitBtn = document.getElementById('submitBtn');
            if (submitBtn) submitBtn.disabled = false;
            renderOverrideApprovedBanner(data.decidedBy, data.decidedAt);
            showToast('Cut-off override approved! You can now submit your request.', 'success');
        } else if (data.status === 'rejected') {
            stopOverridePolling();
            renderOverrideRejectedBanner(data.decidedAt);
            showToast('Cut-off override was rejected by GA team.', 'error');
        }
    } catch (e) {
        // network blip — keep polling
    }
}

// ---- Hotfix Approver Search ----
// Live Microsoft Graph search (User.Read.All). If Graph isn't available
// (e.g. AUTH_DISABLED dev bypass), falls back to this curated list so
// development continues to work.
const KNOWN_APPROVERS = [
    { name: 'Krishna S',         email: 'krishna.s@aptean.com' },
    { name: 'Kapil Kumar',       email: 'kapilkumar@aptean.com' },
    { name: 'Subha Varman R S',  email: 'subhavarman.rs@aptean.com' },
];

let approverSuggestionIndex = -1;
let approverSearchTimer = null;

function onApproverSearch() {
    const input = document.getElementById('hotfixApprovedByInput');
    const query = input.value.trim();
    const sugBox = document.getElementById('approverSuggestions');

    // Clear hidden value when user types
    document.getElementById('hotfixApprovedBy').value = '';

    if (query.length < 2) {
        sugBox.classList.remove('show');
        approverSuggestionIndex = -1;
        return;
    }

    clearTimeout(approverSearchTimer);
    approverSearchTimer = setTimeout(() => searchApproverUsers(query), 250);
}

async function searchApproverUsers(query) {
    const sugBox = document.getElementById('approverSuggestions');

    let matches = null;
    let graphError = null;
    try {
        if (typeof searchApteanPeople === 'function') {
            matches = await searchApteanPeople(query);   // null → not signed in; throws → Graph error
        }
    } catch (e) {
        console.warn('Graph approver search failed; falling back to curated list.', e);
        graphError = e.message || 'Microsoft Graph error';
        matches = null;
    }

    // Source label so the user can see which list they're looking at
    let source = 'graph';
    if (!Array.isArray(matches)) {
        const q = query.toLowerCase();
        matches = KNOWN_APPROVERS.filter(a =>
            a.name.toLowerCase().includes(q) || a.email.toLowerCase().includes(q)
        );
        source = graphError ? 'fallback-error' : 'fallback-noauth';
    }

    matches = matches.slice(0, 15);

    if (matches.length === 0 && source === 'graph') {
        sugBox.innerHTML = '<div class="approver-item approver-no-results">No matching approvers in directory</div>';
        sugBox.classList.add('show');
        approverSuggestionIndex = -1;
        return;
    }

    let header = '';
    if (source === 'fallback-error') {
        header = `<div class="approver-item approver-no-results" style="color:#f87171">Graph search failed: ${sanitize(graphError)} — showing curated list</div>`;
    } else if (source === 'fallback-noauth') {
        header = '<div class="approver-item approver-no-results" style="color:#f59e0b">Not signed in to Microsoft Graph — showing curated list</div>';
    }
    if (matches.length === 0) {
        sugBox.innerHTML = header || '<div class="approver-item approver-no-results">No matching approvers</div>';
        sugBox.classList.add('show');
        approverSuggestionIndex = -1;
        return;
    }

    sugBox.innerHTML = header + matches.map(m =>
        `<div class="approver-item" onclick="selectApprover('${sanitize(m.email)}', '${sanitize(m.name).replace(/'/g, '&#39;')}')">
            <div class="approver-item-name">${sanitize(m.name)}</div>
            <div class="approver-item-email">${sanitize(m.email)}</div>
        </div>`
    ).join('');
    sugBox.classList.add('show');
    approverSuggestionIndex = -1;
}

function onApproverKeydown(e) {
    const sugBox = document.getElementById('approverSuggestions');
    const items = sugBox.querySelectorAll('.approver-item');

    if (e.key === 'ArrowDown') {
        e.preventDefault();
        approverSuggestionIndex = Math.min(approverSuggestionIndex + 1, items.length - 1);
        items.forEach((it, i) => it.classList.toggle('active', i === approverSuggestionIndex));
    } else if (e.key === 'ArrowUp') {
        e.preventDefault();
        approverSuggestionIndex = Math.max(approverSuggestionIndex - 1, 0);
        items.forEach((it, i) => it.classList.toggle('active', i === approverSuggestionIndex));
    } else if (e.key === 'Enter') {
        e.preventDefault();
        if (approverSuggestionIndex >= 0 && items[approverSuggestionIndex]) {
            items[approverSuggestionIndex].click();
        }
    }
}

function selectApprover(email, name) {
    document.getElementById('hotfixApprovedByInput').value = name;
    document.getElementById('hotfixApprovedBy').value = email;
    document.getElementById('approverSuggestions').classList.remove('show');
}

function onApprovalFileChange() {
    const input = document.getElementById('approvalMail');
    if (input.files.length > 0) {
        const file = input.files[0];
        const maxSize = 10 * 1024 * 1024; // 10MB
        if (file.size > maxSize) {
            showToast('File too large. Maximum 10MB allowed.', 'error');
            input.value = '';
        }
    }
}

// Close suggestion dropdowns when clicking outside
document.addEventListener('click', function(e) {
    if (!e.target.closest('.cc-input-container')) {
        const ccSug = document.getElementById('ccSuggestions');
        if (ccSug) ccSug.classList.remove('show');
    }
    if (!e.target.closest('.approver-search-container')) {
        const apSug = document.getElementById('approverSuggestions');
        if (apSug) apSug.classList.remove('show');
    }
});

// ---- Epic Block Management ----
function addEpicBlock() {
    if (!cachedEpics || cachedEpics.length === 0) {
        showToast('No GA-ready epics available. Enter your team name first.', 'error');
        return;
    }
    epicIdCounter++;
    epicBlocks.push({ id: epicIdCounter, epicNumber: '', epicTitle: '', apps: [] });
    renderEpicBlocks();
}

function removeEpicBlock(epicId) {
    epicBlocks = epicBlocks.filter(e => e.id !== epicId);
    renderEpicBlocks();
}

function renderEpicBlocks() {
    const container = document.getElementById('epicBlocksContainer');
    if (epicBlocks.length === 0) {
        container.innerHTML = '<div class="empty-epic-hint">Click <strong>"Add Epic"</strong> to start adding epics and apps to your request.</div>';
        return;
    }

    container.innerHTML = epicBlocks.map((epic, idx) => `
        <div class="epic-block" data-epic-id="${epic.id}">
            <div class="epic-block-header">
                <span class="epic-block-title">Epic ${idx + 1}</span>
                ${epicBlocks.length > 1 ? `<button type="button" class="btn-icon btn-remove" onclick="removeEpicBlock(${epic.id})" title="Remove this Epic">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0V6z"/><path fill-rule="evenodd" d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1H5.5l1-1h3l1 1H13.5a1 1 0 0 1 1 1v1z"/></svg>
                </button>` : ''}
            </div>
            <div class="epic-block-body">
                <div class="form-group" style="max-width: 600px;">
                    <label>Epic <span class="required">*</span></label>
                    <select class="epic-select" onchange="onEpicSelect(${epic.id}, this.value)">
                        <option value="">Select an epic...</option>
                        ${getEpicOptions(epic.epicNumber)}
                    </select>
                </div>

                <div class="apps-section">
                    <div class="apps-header">
                        <label>Apps in this Epic</label>
                        <div class="apps-header-actions">
                            ${epic.epicNumber ? `
                            <button type="button" class="btn btn-autofill-prs" onclick="autoFillAppsFromPRs(${epic.id})" title="Walk this epic's PRs and pre-populate apps from each merged repo+branch">
                                <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0zm-.5 3v5l3 1.5.5-1L8.5 7V3h-1z"/></svg>
                                Auto-fill from PRs
                            </button>
                            ${epic.apps.some(a => a._autoFilled) ? `
                            <button type="button" class="btn btn-edit-autofilled ${epic._editAutoFilled ? 'is-active' : ''}" onclick="toggleEditAutoFilledApps(${epic.id})" title="Unlock auto-filled rows for editing">
                                <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M12.146.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1 0 .708l-10 10a.5.5 0 0 1-.168.11l-5 2a.5.5 0 0 1-.65-.65l2-5a.5.5 0 0 1 .11-.168l10-10z"/></svg>
                                ${epic._editAutoFilled ? 'Lock edits' : 'Edit auto-filled'}
                            </button>` : ''}
                            ` : ''}
                            <button type="button" class="btn btn-add-app" onclick="addAppToEpic(${epic.id})" title="Add app">
                                <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a1 1 0 0 1 1 1v5h5a1 1 0 1 1 0 2H9v5a1 1 0 1 1-2 0V9H2a1 1 0 0 1 0-2h5V2a1 1 0 0 1 1-1z"/></svg>
                                Add App
                            </button>
                        </div>
                    </div>
                    <div class="apps-list" id="apps-${epic.id}">
                        ${renderAppsForEpic(epic)}
                    </div>
                </div>
            </div>
        </div>
    `).join('');
}

function getEpicOptions(selectedEpicNumber) {
    if (!cachedEpics) return '';
    // Already-selected epic IDs (by other blocks) — prevent duplicates
    const usedIds = epicBlocks.map(b => b.epicNumber).filter(n => n && n !== selectedEpicNumber);
    return cachedEpics
        .filter(e => !usedIds.includes(String(e.id)))
        .map(e =>
            `<option value="${e.id}" ${String(e.id) === selectedEpicNumber ? 'selected' : ''}>#${e.id} — ${sanitize(e.title)}</option>`
        ).join('');
}

function onEpicSelect(epicId, value) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic) return;
    const match = (cachedEpics || []).find(e => String(e.id) === String(value));
    epic.epicNumber = value ? String(value) : '';
    epic.epicTitle = match ? match.title : '';
    renderEpicBlocks();
}


function renderAppsForEpic(epic) {
    if (epic.apps.length === 0) {
        return '<div class="empty-app-hint">Click "Add App" to add apps for this epic.</div>';
    }

    const rows = epic.apps.map((app, appIdx) => {
        const repoSelected = !!app.repoId;
        const isLocked = !!app._autoFilled && !epic._editAutoFilled;
        const lockBadge = app._autoFilled
            ? `<span class="autofilled-badge" title="Derived from this epic's PRs">${epic._editAutoFilled ? 'auto · editing' : 'auto · locked'}</span>`
            : '';
        const isFirst = appIdx === 0;
        const isLast  = appIdx === epic.apps.length - 1;
        return `
        <tr class="app-row${app._autoFilled ? ' app-row-autofilled' : ''}${isLocked ? ' app-row-locked' : ''}" data-app-idx="${appIdx}">
            <td class="apps-col-sno">
                <span class="app-sno">${appIdx + 1}</span>
                ${isFirst ? '<span class="app-first-badge" title="Processed first — no wait">1st</span>' : ''}
            </td>
            <td class="apps-col-repo">
                ${lockBadge}
                <div class="autocomplete-wrapper">
                    <input type="text" class="app-repo-input"
                        id="repo-input-${epic.id}-${appIdx}"
                        placeholder="Type to search repository..."
                        value="${sanitize(app.repoName || '')}"
                        autocomplete="off"
                        ${isLocked ? 'readonly' : ''}
                        oninput="onRepoSearchInput(${epic.id}, ${appIdx})"
                        onfocus="onRepoSearchFocus(${epic.id}, ${appIdx})"
                        onblur="onRepoSearchBlur(${epic.id}, ${appIdx})">
                    <div class="autocomplete-dropdown" id="repo-dropdown-${epic.id}-${appIdx}"></div>
                </div>
            </td>
            <td class="apps-col-branch">
                <div class="autocomplete-wrapper">
                    <input type="text" class="app-branch-input"
                        id="branch-input-${epic.id}-${appIdx}"
                        placeholder="${repoSelected ? 'Type to search branch...' : 'Select repo first'}"
                        value="${sanitize(app.branch || '')}"
                        autocomplete="off"
                        ${repoSelected && !isLocked ? '' : 'disabled'}
                        oninput="onBranchSearchInput(${epic.id}, ${appIdx})"
                        onfocus="onBranchSearchFocus(${epic.id}, ${appIdx})"
                        onblur="onBranchSearchBlur(${epic.id}, ${appIdx})">
                    <div class="autocomplete-dropdown" id="branch-dropdown-${epic.id}-${appIdx}"></div>
                </div>
            </td>
            <td class="apps-col-actions">
                <div class="app-actions">
                    <button type="button" class="app-move-btn" onclick="moveAppUp(${epic.id}, ${appIdx})"
                        title="Move up (process earlier)" ${isFirst || isLocked ? 'disabled' : ''}>
                        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M7.646 4.646a.5.5 0 0 1 .708 0l6 6a.5.5 0 0 1-.708.708L8 5.707l-5.646 5.647a.5.5 0 0 1-.708-.708l6-6z"/></svg>
                    </button>
                    <button type="button" class="app-move-btn" onclick="moveAppDown(${epic.id}, ${appIdx})"
                        title="Move down (process later)" ${isLast || isLocked ? 'disabled' : ''}>
                        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M1.646 4.646a.5.5 0 0 1 .708 0L8 10.293l5.646-5.647a.5.5 0 0 1 .708.708l-6 6a.5.5 0 0 1-.708 0l-6-6a.5.5 0 0 1 0-.708z"/></svg>
                    </button>
                    <button type="button" class="btn-icon btn-remove-app" onclick="removeAppFromEpic(${epic.id}, ${appIdx})" title="Remove app">
                        <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>
                    </button>
                </div>
            </td>
            <td class="apps-col-remark">
                <textarea
                    class="app-remark-input"
                    placeholder="Remark..."
                    rows="2"
                    ${isLocked ? 'readonly' : ''}
                    oninput="onAppRemarkInput(${epic.id}, ${appIdx}, this.value)">${sanitize(app.remark || '')}</textarea>
            </td>
        </tr>`;
    }).join('');

    return `
    <table class="apps-table">
        <thead>
            <tr>
                <th class="apps-col-sno">#</th>
                <th class="apps-col-repo">App / Repo <span class="required">*</span></th>
                <th class="apps-col-branch">Source Branch <span class="required">*</span></th>
                <th class="apps-col-actions"></th>
                <th class="apps-col-remark">Remark</th>
            </tr>
        </thead>
        <tbody>${rows}</tbody>
    </table>`;
}

function onAppRemarkInput(epicId, appIdx, value) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (epic && epic.apps[appIdx]) epic.apps[appIdx].remark = value;
}

function moveAppUp(epicId, appIdx) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || appIdx <= 0) return;
    [epic.apps[appIdx - 1], epic.apps[appIdx]] = [epic.apps[appIdx], epic.apps[appIdx - 1]];
    renderEpicBlocks();
}

function moveAppDown(epicId, appIdx) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || appIdx >= epic.apps.length - 1) return;
    [epic.apps[appIdx], epic.apps[appIdx + 1]] = [epic.apps[appIdx + 1], epic.apps[appIdx]];
    renderEpicBlocks();
}

async function addAppToEpic(epicId) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic) return;
    await loadRepos();
    epic.apps.push({ repoId: '', repoName: '', branch: '', remark: '' });
    renderEpicBlocks();
}

// ---- Auto-fill apps from this Epic's linked PRs ----
async function autoFillAppsFromPRs(epicId) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || !epic.epicNumber) {
        showToast('Select an epic first.', 'error');
        return;
    }

    const appsContainer = document.getElementById(`apps-${epicId}`);
    const prevHTML = appsContainer ? appsContainer.innerHTML : '';
    if (appsContainer) {
        appsContainer.innerHTML = '<div class="empty-app-hint"><span class="spinner"></span> Walking PRs under epic #' + sanitize(epic.epicNumber) + '…</div>';
    }

    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/GetEpicAppsFromPRs?epicId=${encodeURIComponent(epic.epicNumber)}`);
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.message || `HTTP ${res.status}`);
        }
        const data = await res.json();
        const apps = Array.isArray(data.apps) ? data.apps : [];
        const warnings = Array.isArray(data.warnings) ? data.warnings : [];

        if (apps.length === 0) {
            if (appsContainer) appsContainer.innerHTML = prevHTML;
            const reason = warnings.length ? warnings[0] : 'No completed PRs found under this epic.';
            showToast(`No apps to fill: ${reason}`, 'warn');
            return;
        }

        // Make sure repos are loaded so the typeahead labels resolve cleanly
        await loadRepos();

        // Append (don't replace). Skip duplicates that already exist (same repoId + branch).
        const existingKeys = new Set(epic.apps.map(a => `${a.repoId}|${a.branch}`));
        let added = 0;
        apps.forEach(a => {
            const key = `${a.repoId}|${a.sourceBranch}`;
            if (existingKeys.has(key)) return;
            epic.apps.push({
                repoId: a.repoId,
                repoName: a.repoName,
                branch: a.sourceBranch,
                remark: '',
                _autoFilled: true
            });
            added++;
        });

        // Warm the branch typeahead cache for each new repo
        apps.forEach(a => { if (a.repoId) loadBranches(a.repoId); });

        renderEpicBlocks();

        // ---- Derive Release Type + Target Month from the epic's GA Date ----
        // Looks up the matching entry in RELEASE_SCHEDULE for the GA Date's month
        // and sets the form's Release Type + Target Month accordingly.
        const releaseInfo = applyReleaseScheduleFromGADate(data.epicGADate);

        const stats = data.stats || {};
        let summary = `${added} app${added === 1 ? '' : 's'} added from ${stats.completedPRCount || 0} completed PR(s) (under ${stats.descendantCount || 0} child work item(s)).`;
        if (releaseInfo) {
            summary += ` Release type → ${releaseInfo.label}, target → ${releaseInfo.targetMonth}.`;
        }
        showToast(summary, 'success');

        if (warnings.length) {
            console.warn('[auto-fill] warnings:', warnings);
            warnings.forEach(w => showToast(w, 'warn'));
        }
    } catch (e) {
        if (appsContainer) appsContainer.innerHTML = prevHTML;
        console.error('Auto-fill from PRs failed:', e);
        showToast(`Auto-fill failed: ${e.message}`, 'error');
    }
}

// Maps the epic's GA Date → matching RELEASE_SCHEDULE entry, then sets the
// Release Type + Target Month dropdowns. Returns { label, targetMonth } or null.
function applyReleaseScheduleFromGADate(gaDateRaw) {
    if (!gaDateRaw) {
        console.info('[auto-fill] no GA Date on epic — skipping release-type/month auto-fill');
        return null;
    }
    const d = new Date(gaDateRaw);
    if (isNaN(d.getTime())) {
        console.warn('[auto-fill] could not parse epic GA Date:', gaDateRaw);
        return null;
    }
    const m = d.getMonth();   // 0-11
    const y = d.getFullYear();

    // Find the schedule entry whose releaseMonth matches the GA Date's month.
    // Multiple schedule entries can share a month (e.g. Jan = Major Jan, Dec → Jan)
    // — pick the first match; releases for the same month always have the same `type`.
    const entry = (RELEASE_SCHEDULE || []).find(e => e.releaseMonth === m);
    if (!entry) {
        console.warn('[auto-fill] no RELEASE_SCHEDULE entry for month', m);
        return null;
    }

    const releaseType = entry.type;            // 'feature' or 'stability'
    const monthName   = MONTH_NAMES[m];        // e.g. 'MAY'
    const targetValue = `${monthName} GA${y}`; // e.g. 'MAY GA2026'

    // Set Release Type
    const rtSelect = document.getElementById('releaseType');
    if (rtSelect) {
        rtSelect.value = releaseType;
        // Trigger the existing handler so cutoff banners + auto-target-month logic run
        if (typeof onReleaseTypeChange === 'function') {
            onReleaseTypeChange();
        }
    }

    // Override target month with the value derived from the GA Date (in case the
    // current "next-upcoming-release" logic in onReleaseTypeChange picked a different
    // month than the epic actually targets — the epic's schedule wins).
    const tmSelect = document.getElementById('targetMonth');
    if (tmSelect) {
        let opt = tmSelect.querySelector(`option[value="${targetValue}"]`);
        if (!opt) {
            opt = document.createElement('option');
            opt.value = targetValue;
            opt.textContent = targetValue;
            tmSelect.appendChild(opt);
        }
        tmSelect.value = targetValue;
    }

    const label = releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor';
    return { label, targetMonth: targetValue };
}

// ---- Toggle locked / editable mode for auto-filled rows in an epic ----
function toggleEditAutoFilledApps(epicId) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic) return;
    epic._editAutoFilled = !epic._editAutoFilled;
    renderEpicBlocks();
}

function removeAppFromEpic(epicId, appIdx) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (epic) {
        epic.apps.splice(appIdx, 1);
        renderEpicBlocks();
    }
}

// ---- Repo typeahead (per-app row) ----
function onRepoSearchInput(epicId, appIdx) {
    const input = document.getElementById(`repo-input-${epicId}-${appIdx}`);
    if (!input) return;
    renderRepoDropdown(epicId, appIdx, (input.value || '').trim().toLowerCase());
}

function onRepoSearchFocus(epicId, appIdx) {
    const input = document.getElementById(`repo-input-${epicId}-${appIdx}`);
    if (!input) return;
    renderRepoDropdown(epicId, appIdx, (input.value || '').trim().toLowerCase());
}

function onRepoSearchBlur(epicId, appIdx) {
    // Delay so click on a dropdown item registers before we hide
    setTimeout(() => {
        const dropdown = document.getElementById(`repo-dropdown-${epicId}-${appIdx}`);
        if (dropdown) dropdown.style.display = 'none';
        // Restore the input value to whatever's actually saved (don't accept free text)
        const epic = epicBlocks.find(e => e.id === epicId);
        const input = document.getElementById(`repo-input-${epicId}-${appIdx}`);
        if (epic && input) {
            input.value = epic.apps[appIdx]?.repoName || '';
        }
    }, 200);
}

function renderRepoDropdown(epicId, appIdx, query) {
    const dropdown = document.getElementById(`repo-dropdown-${epicId}-${appIdx}`);
    if (!dropdown || !cachedRepos) return;

    const filtered = query
        ? cachedRepos.filter(r => r.name.toLowerCase().includes(query))
        : cachedRepos;

    const top = filtered.slice(0, 50);   // cap for perf
    if (top.length === 0) {
        dropdown.innerHTML = '<div class="autocomplete-item autocomplete-empty">No matching repositories</div>';
    } else {
        dropdown.innerHTML = top.map(r => {
            const safeId = sanitize(r.id);
            const safeName = sanitize(r.name);
            return `<div class="autocomplete-item" onmousedown="selectRepoForApp(${epicId}, ${appIdx}, '${safeId}', '${safeName.replace(/'/g, "\\'")}')">${highlightMatch(safeName, query)}</div>`;
        }).join('');
    }
    dropdown.style.display = 'block';
}

async function selectRepoForApp(epicId, appIdx, repoId, repoName) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || !epic.apps[appIdx]) return;

    epic.apps[appIdx].repoId = repoId;
    epic.apps[appIdx].repoName = repoName;
    epic.apps[appIdx].branch = '';

    // Hide dropdown immediately
    const dropdown = document.getElementById(`repo-dropdown-${epicId}-${appIdx}`);
    if (dropdown) dropdown.style.display = 'none';

    await loadBranches(repoId);
    renderEpicBlocks();
}

// ---- Branch typeahead (per-app row) ----
function onBranchSearchInput(epicId, appIdx) {
    const input = document.getElementById(`branch-input-${epicId}-${appIdx}`);
    if (!input) return;
    renderBranchDropdown(epicId, appIdx, (input.value || '').trim().toLowerCase());
}

function onBranchSearchFocus(epicId, appIdx) {
    const input = document.getElementById(`branch-input-${epicId}-${appIdx}`);
    if (!input) return;
    renderBranchDropdown(epicId, appIdx, (input.value || '').trim().toLowerCase());
}

function onBranchSearchBlur(epicId, appIdx) {
    setTimeout(() => {
        const dropdown = document.getElementById(`branch-dropdown-${epicId}-${appIdx}`);
        if (dropdown) dropdown.style.display = 'none';
        const epic = epicBlocks.find(e => e.id === epicId);
        const input = document.getElementById(`branch-input-${epicId}-${appIdx}`);
        if (epic && input) {
            input.value = epic.apps[appIdx]?.branch || '';
        }
    }, 200);
}

function renderBranchDropdown(epicId, appIdx, query) {
    const dropdown = document.getElementById(`branch-dropdown-${epicId}-${appIdx}`);
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!dropdown || !epic || !epic.apps[appIdx]) return;

    const repoId = epic.apps[appIdx].repoId;
    const branches = (repoId && branchCache[repoId]) ? branchCache[repoId] : [];

    const filtered = query
        ? branches.filter(b => (b.name || '').toLowerCase().includes(query))
        : branches;
    const top = filtered.slice(0, 50);

    if (top.length === 0) {
        dropdown.innerHTML = `<div class="autocomplete-item autocomplete-empty">${branches.length === 0 ? 'Loading branches...' : 'No matching branches'}</div>`;
    } else {
        dropdown.innerHTML = top.map(b => {
            const safeName = sanitize(b.name);
            return `<div class="autocomplete-item" onmousedown="selectBranchForApp(${epicId}, ${appIdx}, '${safeName.replace(/'/g, "\\'")}')">${highlightMatch(safeName, query)}</div>`;
        }).join('');
    }
    dropdown.style.display = 'block';
}

function selectBranchForApp(epicId, appIdx, branchName) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || !epic.apps[appIdx]) return;
    epic.apps[appIdx].branch = branchName;

    const input = document.getElementById(`branch-input-${epicId}-${appIdx}`);
    if (input) input.value = branchName;
    const dropdown = document.getElementById(`branch-dropdown-${epicId}-${appIdx}`);
    if (dropdown) dropdown.style.display = 'none';
}

function highlightMatch(text, query) {
    if (!query) return text;
    const idx = text.toLowerCase().indexOf(query);
    if (idx < 0) return text;
    return text.slice(0, idx) + '<strong>' + text.slice(idx, idx + query.length) + '</strong>' + text.slice(idx + query.length);
}

// ---- Form Submission ----
async function handleSubmit(event) {
    event.preventDefault();

    if (epicBlocks.length === 0) {
        showToast('Please add at least one Epic', 'error');
        return false;
    }

    // Hotfix-specific validation
    const releaseType = document.getElementById('releaseType').value;
    if (releaseType === 'hotfix') {
        if (!document.getElementById('hotfixApprovedBy').value) {
            showToast('Please select the Hotfix Approver', 'error');
            return false;
        }
        if (!document.getElementById('approvalMail').files.length) {
            showToast('Please attach the approval mail', 'error');
            return false;
        }
    }

    for (let i = 0; i < epicBlocks.length; i++) {
        const epic = epicBlocks[i];
        if (!epic.epicNumber) {
            showToast(`Epic ${i + 1}: Please select an Epic`, 'error');
            return false;
        }
        if (epic.apps.length === 0) {
            showToast(`Epic #${epic.epicNumber}: Please add at least one app`, 'error');
            return false;
        }
        for (let j = 0; j < epic.apps.length; j++) {
            const app = epic.apps[j];
            if (!app.repoId) {
                showToast(`Epic #${epic.epicNumber}, App ${j + 1}: Please select a repository`, 'error');
                return false;
            }
            if (!app.branch) {
                showToast(`Epic #${epic.epicNumber}, App ${j + 1}: Please select a source branch`, 'error');
                return false;
            }
        }
    }

    const submitBtn = document.getElementById('submitBtn');
    submitBtn.disabled = true;
    submitBtn.innerHTML = '<span class="spinner"></span> Submitting...';

    const form = document.getElementById('gaRequestForm');
    const formData = new FormData(form);

    let encodedAttachments = [];
    if (attachedFiles.length > 0) {
        try {
            encodedAttachments = await encodeAttachmentsAsBase64();
        } catch (e) {
            showToast(`Failed to read attachment: ${e.message}`, 'error');
            submitBtn.disabled = false;
            submitBtn.innerHTML = `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14.5 1.5l-13 5.5 5 2 2.5 5.5z"/></svg> Submit GA Request`;
            return false;
        }
    }

    // Encode the hotfix approval mail (separate file input, not in attachedFiles)
    let approvalMailAttachment = null;
    if (formData.get('releaseType') === 'hotfix') {
        const approvalMailInput = document.getElementById('approvalMail');
        if (approvalMailInput.files.length > 0) {
            try {
                approvalMailAttachment = await encodeFileAsBase64(approvalMailInput.files[0]);
            } catch (e) {
                showToast(`Failed to read approval mail: ${e.message}`, 'error');
                submitBtn.disabled = false;
                submitBtn.innerHTML = `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14.5 1.5l-13 5.5 5 2 2.5 5.5z"/></svg> Submit GA Request`;
                return false;
            }
        }
    }

    const payload = {
        teamName: formData.get('teamName'),
        releaseType: formData.get('releaseType'),
        submitterEmail: formData.get('submitterEmail'),
        ccEmails: ccEmailList.length > 0 ? ccEmailList : [],
        // Read targetMonth from the element directly: a disabled <select> is excluded from FormData,
        // so for feature/stability (where we lock the dropdown) FormData would return null.
        targetMonth: document.getElementById('targetMonth').value,
        hotfixApprovedBy: formData.get('releaseType') === 'hotfix' ? formData.get('hotfixApprovedBy') : null,
        approvalMailAttachment: approvalMailAttachment,
        epics: epicBlocks.map(epic => ({
            epicNumber: epic.epicNumber,
            epicTitle: epic.epicTitle,
            apps: epic.apps.map((app, appIdx) => ({
                repoId: app.repoId,
                repoName: app.repoName,
                sourceBranch: app.branch,
                remark: app.remark || '',
                dependencyOrder: appIdx
            }))
        })),
        notes: formData.get('notes') || '',
        attachments: encodedAttachments,
        submittedAt: new Date().toISOString(),
        cutoffOverrideId: cutoffOverrideGranted ? pendingOverrideId : null
    };

    try {
        const submitAbort = new AbortController();
        const submitTimer = setTimeout(() => submitAbort.abort(), 60000);
        let response;
        try {
            response = await fetch(`${CONFIG.apiBaseUrl}/SubmitRequest`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
                signal: submitAbort.signal
            });
        } finally {
            clearTimeout(submitTimer);
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));

            // Special-case: epic was already submitted previously (409 Conflict).
            // Show a longer, more explanatory message instead of a generic toast.
            if (response.status === 409 && err.code === 'epic_already_submitted') {
                showDuplicateEpicError(err);
                return false;
            }

            throw new Error(err.message || 'Failed to submit request');
        }

        const result = await response.json();
        showSuccessModal(payload, result.requestId);
        // Auto-reset the form after a successful submission so the page is
        // clean if the user comes back to submit another request.
        resetForm();
    } catch (error) {
        const msg = error.name === 'AbortError'
            ? 'Request timed out (>30s). Check that Azurite is running and try again.'
            : error.message;
        showToast(`Error: ${msg}`, 'error');
    } finally {
        submitBtn.disabled = false;
        submitBtn.innerHTML = `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14.5 1.5l-13 5.5 5 2 2.5 5.5z"/></svg> Submit GA Request`;
    }

    return false;
}

// Show a clearer message when SubmitRequest rejects with 409
// (one or more epics are already in an active request).
function showDuplicateEpicError(err) {
    const list = (err.conflicts || []).map(c =>
        `Epic #${c.epicNumber} — already in ${c.existingRequestId} (${c.existingStatus}, by ${c.submitter || 'unknown'})`
    );
    const lines = [
        'A request was already raised for the following epic(s):',
        ...list,
        '',
        "You can't submit a new request for the same epic.",
        'Please reach out to the GA Team — they can enable edit options on the existing request, or reject it so this epic can be re-submitted.'
    ];
    alert(lines.join('\n'));
    showToast('Duplicate epic — see message for details', 'error');
}

function resetForm() {
    document.getElementById('gaRequestForm').reset();
    epicBlocks = [];
    epicIdCounter = 0;
    cachedEpics = null;
    epicLoadingTeam = '';
    hideEpicSection();
    // Reset CC tags
    ccEmailList = [];
    renderCcTags();
    document.getElementById('ccEmails').value = '';
    // Reset hotfix fields
    document.getElementById('hotfixFields').style.display = 'none';
    document.getElementById('hotfixApprovedBy').value = '';
    document.getElementById('hotfixApprovedByInput').value = '';
    // Re-fill SSO email
    if (typeof getCurrentUserEmail === 'function') {
        document.getElementById('submitterEmail').value = getCurrentUserEmail();
    }
    // Reset cutoff override state
    cutoffOverrideGranted = false;
    pendingOverrideId = null;
    stopOverridePolling();
    const banner = document.getElementById('cutoffBanner');
    if (banner) {
        banner.style.display = 'none';
        banner.classList.remove('cutoff-approved', 'cutoff-rejected');
    }
    // Reset attachments
    attachedFiles = [];
    renderAttachmentList();
}

// ---- File Upload ----
const ALLOWED_FILE_TYPES = {
    'image/jpeg': 'img', 'image/jpg': 'img', 'image/png': 'img',
    'image/gif': 'img', 'image/bmp': 'img', 'image/webp': 'img',
    'application/vnd.ms-excel': 'xls',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xls',
    'application/pdf': 'pdf',
    'application/msword': 'doc',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'doc',
    'text/plain': 'txt',
    'text/csv': 'csv'
};
const MAX_FILES = 5;
const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 MB

function initUploadZone() {
    const zone = document.getElementById('uploadZone');
    const input = document.getElementById('attachmentInput');
    if (!zone || !input) return;

    zone.addEventListener('click', e => {
        if (!e.target.closest('.attachment-list')) input.click();
    });
    zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('drag-over'); });
    zone.addEventListener('dragleave', e => { if (!zone.contains(e.relatedTarget)) zone.classList.remove('drag-over'); });
    zone.addEventListener('drop', e => {
        e.preventDefault();
        zone.classList.remove('drag-over');
        handleFileSelection(Array.from(e.dataTransfer.files));
    });
    input.addEventListener('change', () => {
        handleFileSelection(Array.from(input.files));
        input.value = '';
    });
}

function handleFileSelection(files) {
    for (const file of files) {
        if (attachedFiles.length >= MAX_FILES) {
            showToast(`Maximum ${MAX_FILES} files allowed per request`, 'error');
            break;
        }
        if (!(file.type in ALLOWED_FILE_TYPES)) {
            showToast(`"${file.name}" is not a supported file type`, 'error');
            continue;
        }
        if (file.size > MAX_FILE_SIZE) {
            showToast(`"${file.name}" exceeds the 10 MB size limit`, 'error');
            continue;
        }
        if (attachedFiles.find(f => f.name === file.name && f.size === file.size)) {
            showToast(`"${file.name}" is already attached`, 'warning');
            continue;
        }
        attachedFiles.push(file);
    }
    renderAttachmentList();
}

function removeAttachment(index) {
    attachedFiles.splice(index, 1);
    renderAttachmentList();
}

function fileTypeIcon(mimeType) {
    const kind = ALLOWED_FILE_TYPES[mimeType] || 'file';
    const icons = {
        img: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M6.002 5.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0z"/><path d="M2.002 1a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2h-12zm12 1a1 1 0 0 1 1 1v6.5l-3.777-1.947a.5.5 0 0 0-.577.093l-3.71 3.71-2.66-1.772a.5.5 0 0 0-.63.062L1.002 12V3a1 1 0 0 1 1-1h12z"/></svg>`,
        xls: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14 4.5V11h-1V4.5h-2A1.5 1.5 0 0 1 9.5 3V1H4a1 1 0 0 0-1 1v9H2V2a2 2 0 0 1 2-2h5.5L14 4.5zm-3 7.5H9.5v-1h1V10h-1V9h1V8H9.5V7h2v5zM6.5 7H5L4 9.5 3 7H1.5l1.75 3.5L1.5 14H3l1-2.5 1 2.5h1.5L5 10.5 6.5 7z"/></svg>`,
        pdf: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14 4.5V14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2a2 2 0 0 1 2-2h5.5L14 4.5zm-3 0A1.5 1.5 0 0 1 9.5 3V1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V4.5h-2z"/></svg>`,
        doc: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14 4.5V14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2a2 2 0 0 1 2-2h5.5L14 4.5zm-3 0A1.5 1.5 0 0 1 9.5 3V1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V4.5h-2z"/></svg>`,
        txt: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M5 4a.5.5 0 0 0 0 1h6a.5.5 0 0 0 0-1H5zm-.5 2.5A.5.5 0 0 1 5 6h6a.5.5 0 0 1 0 1H5a.5.5 0 0 1-.5-.5zM5 8a.5.5 0 0 0 0 1h6a.5.5 0 0 0 0-1H5zm0 2a.5.5 0 0 0 0 1h3a.5.5 0 0 0 0-1H5z"/><path d="M2 2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2zm10-1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1z"/></svg>`,
        csv: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M5 4a.5.5 0 0 0 0 1h6a.5.5 0 0 0 0-1H5zm-.5 2.5A.5.5 0 0 1 5 6h6a.5.5 0 0 1 0 1H5a.5.5 0 0 1-.5-.5zM5 8a.5.5 0 0 0 0 1h6a.5.5 0 0 0 0-1H5zm0 2a.5.5 0 0 0 0 1h3a.5.5 0 0 0 0-1H5z"/><path d="M2 2a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2zm10-1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1z"/></svg>`,
        file: `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14 4.5V14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2a2 2 0 0 1 2-2h5.5L14 4.5zM9.5 3A1.5 1.5 0 0 1 11 4.5h2V14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h5.5v2z"/></svg>`
    };
    return icons[kind] || icons.file;
}

function formatFileSize(bytes) {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function renderAttachmentList() {
    const list = document.getElementById('attachmentList');
    if (!list) return;
    if (attachedFiles.length === 0) {
        list.innerHTML = '';
        return;
    }
    list.innerHTML = attachedFiles.map((f, i) => `
        <div class="attachment-chip">
            <span class="attachment-icon">${fileTypeIcon(f.type)}</span>
            <span class="attachment-name" title="${sanitize(f.name)}">${sanitize(f.name)}</span>
            <span class="attachment-size">${formatFileSize(f.size)}</span>
            <button type="button" class="attachment-remove" onclick="removeAttachment(${i})" title="Remove">
                <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>
            </button>
        </div>
    `).join('');
}

async function encodeAttachmentsAsBase64() {
    return Promise.all(attachedFiles.map(file => new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve({
            name: file.name,
            type: file.type,
            size: file.size,
            dataBase64: reader.result.split(',')[1]
        });
        reader.onerror = () => reject(new Error(`Failed to read ${file.name}`));
        reader.readAsDataURL(file);
    })));
}

function encodeFileAsBase64(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve({
            name: file.name,
            type: file.type || 'application/octet-stream',
            size: file.size,
            dataBase64: reader.result.split(',')[1]
        });
        reader.onerror = () => reject(new Error(`Failed to read ${file.name}`));
        reader.readAsDataURL(file);
    });
}

// ---- Dashboard ----
let epicFilterDebounce = null;

function onEpicFilterInput() {
    clearTimeout(epicFilterDebounce);
    epicFilterDebounce = setTimeout(() => {
        const filtered = applyClientFilters(allRequests);
        renderRequestsTable(filtered);
        updateStats(filtered);
    }, 250);
}

function applyClientFilters(requests) {
    // Drop expired requests (30 days for completed, 45 for everything else)
    let result = requests.filter(req => !isRequestExpired(req));

    // Status filter — applied client-side so it works even on fallback sample data
    const statusFilter = document.getElementById('filterStatus')?.value;
    if (statusFilter) {
        result = result.filter(req => (req.status || '') === statusFilter);
    }

    // Team filter — applied client-side as a safety net
    const teamFilter = document.getElementById('filterTeam')?.value;
    if (teamFilter) {
        result = result.filter(req => (req.teamName || '') === teamFilter);
    }

    // Epic number filter (comma-separated)
    const epicInput = document.getElementById('filterEpics');
    if (!epicInput) return result;
    const tokens = epicInput.value
        .split(',')
        .map(t => t.trim())
        .filter(Boolean);
    if (tokens.length === 0) return result;
    return result.filter(req =>
        (req.epics || []).some(e => {
            const num = String(e.epicNumber || '');
            return tokens.some(tok => num.includes(tok));
        })
    );
}

function setStatusFilter(status) {
    const sel = document.getElementById('filterStatus');
    if (!sel) return;
    // Toggle off if already active, otherwise apply
    sel.value = sel.value === status ? '' : status;
    updateStatCardActive(sel.value);
    loadRequests();
}

function updateStatCardActive(activeStatus) {
    document.querySelectorAll('.stat-card.stat-clickable').forEach(card => {
        card.classList.remove('stat-active');
    });
    if (!activeStatus) return;
    const map = { pending: 'statPending', approved: 'statApproved', 'in-progress': 'statInProgress', completed: 'statCompleted' };
    const targetId = map[activeStatus];
    if (targetId) {
        document.getElementById(targetId)?.closest('.stat-card')?.classList.add('stat-active');
    }
}

async function loadRequests() {
    const statusFilter = document.getElementById('filterStatus').value;
    const teamFilter = document.getElementById('filterTeam').value;

    const params = new URLSearchParams();
    if (statusFilter) params.set('status', statusFilter);
    if (teamFilter) params.set('team', teamFilter);

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetRequests?${params.toString()}`);
        if (!response.ok) throw new Error('Failed to load requests');

        allRequests = await response.json();
    } catch (error) {
        allRequests = getSampleData();
    }

    const filtered = applyClientFilters(allRequests);
    renderRequestsTable(filtered);
    updateStats(filtered);
}

function renderRequestsTable(requests) {
    const tbody = document.getElementById('requestsBody');

    if (requests.length === 0) {
        tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No requests found matching your filters.</td></tr>';
        return;
    }

    const myEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '').toLowerCase();
    const adminUser = (typeof isAdmin === 'function') ? isAdmin() : false;

    tbody.innerHTML = requests.map(req => {
        const statusClass = `status-${req.status.replace(/\s+/g, '-')}`;
        const releaseClass = `release-${req.releaseType || 'stability'}`;
        const releaseLabel = getReleaseTypeLabel(req.releaseType);
        const hotfixBadge = req.releaseType === 'hotfix' && req.status === 'pending'
            ? `<span class="hotfix-approval-indicator" title="Hotfix — approval mail attached for review">&#9888; Review approval</span>`
            : '';
        const epics = (req.epics || []).map(e => `#${sanitize(e.epicNumber)}`).join(', ');
        const totalApps = (req.epics || []).reduce((sum, e) => sum + (e.apps || []).length, 0);
        const dt = new Date(req.submittedAt);
        const date = dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
        const time = dt.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });

        const reqId = sanitize(req.id || req.requestId);
        const isOwnRequest = !!(myEmail && req.submitterEmail && req.submitterEmail.toLowerCase() === myEmail);

        // Edit button: only the original submitter, only while still pending.
        const isOwnPending = (isOwnRequest && req.status === 'pending');
        const editBtn = isOwnPending
            ? `<button class="btn btn-secondary btn-sm" onclick='openSubmitterEditModal(${JSON.stringify(req).replace(/'/g, "&#39;")})' title="Edit your request">
                   <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="vertical-align:-1px"><path d="M12.146.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1 0 .708l-10 10a.5.5 0 0 1-.168.11l-5 2a.5.5 0 0 1-.65-.65l2-5a.5.5 0 0 1 .11-.168l10-10z"/></svg>
                   Edit
               </button>`
            : '';

        // Cancel button: pending status, submitter or admin
        const canCancel = req.status === 'pending' && (isOwnRequest || adminUser);
        const cancelBtn = canCancel
            ? `<button class="btn btn-warning btn-sm" onclick="cancelMyRequest('${reqId}')" title="Cancel this pending request">
                   <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="vertical-align:-1px"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>
                   Cancel
               </button>`
            : '';

        // Delete button: admin only, available on ANY status (temporary cleanup tool).
        const canDelete = adminUser;
        const deleteBtn = canDelete
            ? `<button class="btn btn-danger btn-sm" onclick="deleteCompletedRequest('${reqId}','${sanitize(req.status || '')}')" title="Permanently delete this request (admin)">
                   <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="vertical-align:-1px"><path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0V6z"/><path d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1 0-2h3a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1h3a1 1 0 0 1 1 1zM4.118 4L4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4H4.118z"/></svg>
                   Delete
               </button>`
            : '';

        return `<tr>
            <td><strong>${reqId}</strong></td>
            <td>${sanitize(req.teamName)}</td>
            <td><span class="release-type-badge ${releaseClass}">${releaseLabel}</span>${hotfixBadge}</td>
            <td>${epics}</td>
            <td>${totalApps} app${totalApps !== 1 ? 's' : ''}</td>
            <td><span class="status-badge ${statusClass}">${sanitize(capitalizeFirst(req.status))}</span></td>
            <td><span class="submitted-datetime">${date}<br><span class="submitted-time">${time}</span></span></td>
            <td style="white-space:nowrap;">
                <button class="btn btn-secondary btn-sm" onclick='showDetail(${JSON.stringify(req).replace(/'/g, "&#39;")})'>View</button>
                ${editBtn}
                ${cancelBtn}
                ${deleteBtn}
            </td>
        </tr>`;
    }).join('');
}

function updateStats(requests) {
    const counts = { pending: 0, approved: 0, 'in-progress': 0, completed: 0 };
    requests.forEach(r => {
        const key = r.status.replace(/\s+/g, '-');
        if (counts[key] !== undefined) counts[key]++;
    });
    document.getElementById('statPending').textContent = counts.pending;
    document.getElementById('statApproved').textContent = counts.approved;
    document.getElementById('statInProgress').textContent = counts['in-progress'];
    document.getElementById('statCompleted').textContent = counts.completed;
}

// ---- Detail Modal ----
function showDetail(request) {
    const body = document.getElementById('detailModalBody');
    const footer = document.getElementById('detailModalFooter');

    const epicsHtml = (request.epics || []).map(epic => {
        const appsRows = (epic.apps || []).map((app, i) =>
            `<div class="detail-app-row">
                <span class="detail-app-sno">${i + 1}</span>
                <span class="detail-app-repo">${sanitize(app.repoName)}</span>
                <span class="detail-app-branch"><code>${sanitize(app.sourceBranch)}</code></span>
                ${app.remark ? `<span class="detail-app-remark">${sanitize(app.remark)}</span>` : ''}
            </div>`
        ).join('');
        return `<div class="detail-epic-card">
            <div class="detail-epic-header">Epic #${sanitize(epic.epicNumber)}${epic.epicTitle ? ' — ' + sanitize(epic.epicTitle) : ''}</div>
            <div class="detail-epic-apps">${appsRows}</div>
        </div>`;
    }).join('');

    body.innerHTML = `
        <dl class="detail-grid">
            <dt>Request ID</dt>
            <dd><strong>${sanitize(request.id || request.requestId)}</strong></dd>

            <dt>Team</dt>
            <dd>${sanitize(request.teamName)}</dd>

            <dt>Release Type</dt>
            <dd><span class="release-type-badge release-${request.releaseType}">
                ${getReleaseTypeLabel(request.releaseType)}
            </span></dd>

            <dt>Submitted By</dt>
            <dd>${sanitize(request.submitterEmail)}</dd>

            ${request.ccEmails && request.ccEmails.length ? `<dt>CC</dt><dd>${request.ccEmails.map(e => sanitize(e)).join(', ')}</dd>` : ''}

            <dt>Submitted At</dt>
            <dd>${new Date(request.submittedAt).toLocaleString()}</dd>

            <dt>Status</dt>
            <dd><span class="status-badge status-${request.status}">${sanitize(capitalizeFirst(request.status))}</span></dd>

            ${request.notes ? `<dt>Notes</dt><dd>${sanitize(request.notes)}</dd>` : ''}

            ${(() => {
                let attachments = [];
                try {
                    attachments = request.attachments
                        ? (typeof request.attachments === 'string' ? JSON.parse(request.attachments) : request.attachments)
                        : [];
                } catch {}
                if (!attachments.length) return '';
                const chips = attachments.map(a => `
                    <a href="${sanitize(a.url)}" target="_blank" rel="noopener noreferrer" class="attachment-chip attachment-chip-link" title="${sanitize(a.name)}">
                        <span class="attachment-name">${sanitize(a.name)}</span>
                        <span class="attachment-size">${a.size ? formatFileSize(a.size) : ''}</span>
                    </a>`).join('');
                return `<dt>Attachments</dt><dd><div class="attachment-list attachment-list-inline">${chips}</div></dd>`;
            })()}
        </dl>

        ${request.releaseType === 'hotfix' ? `
        <div class="hotfix-review-section">
            <div class="hotfix-review-header">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 1.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zm-.75 3.25h1.5v4h-1.5v-4zm0 5h1.5v1.5h-1.5v-1.5z"/></svg>
                Hotfix Approval Verification
                <span class="hotfix-review-required">Required before approving</span>
            </div>
            <div class="hotfix-review-body">
                <div class="hotfix-review-row">
                    <span class="hotfix-review-label">Approved By</span>
                    <span class="hotfix-review-value">
                        ${request.hotfixApprovedBy
                            ? `<span class="hotfix-approver-chip">${sanitize(request.hotfixApprovedBy)}</span>`
                            : '<em class="hotfix-missing">Not provided — ask submitter to resubmit</em>'}
                    </span>
                </div>
                <div class="hotfix-review-row">
                    <span class="hotfix-review-label">Approval Mail</span>
                    <span class="hotfix-review-value">
                        ${request.hotfixApprovalMailUrl
                            ? `<a href="${sanitize(request.hotfixApprovalMailUrl)}" target="_blank" rel="noopener noreferrer" class="hotfix-mail-link">
                                   <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M.05 3.555A2 2 0 0 1 2 2h12a2 2 0 0 1 1.95 1.555L8 8.414.05 3.555ZM0 4.697v7.104l5.803-3.558L0 4.697ZM6.761 8.83l-6.57 4.026A2 2 0 0 0 2 14h12a2 2 0 0 0 1.808-1.144l-6.57-4.027L8 9.586l-1.239-.757Zm3.436-.586L16 11.801V4.697l-5.803 3.546Z"/></svg>
                                   Open Approval Mail
                               </a>`
                            : '<em class="hotfix-missing">Not uploaded — ask submitter to resubmit</em>'}
                    </span>
                </div>
            </div>
        </div>` : ''}

        <div class="detail-epics-section">
            <h3>Epics & Apps</h3>
            ${epicsHtml}
        </div>
    `;

    if (request.status === 'pending' && isAdmin()) {
        const isHotfix = request.releaseType === 'hotfix';
        const approveId = sanitize(request.id || request.requestId);
        footer.innerHTML = `
            ${isHotfix ? `
            <label class="hotfix-verify-check">
                <input type="checkbox" id="hotfixVerifiedChk" onchange="onHotfixVerifyChange('${approveId}')">
                I have reviewed and verified the hotfix approval details above
            </label>` : ''}
            <button class="btn btn-reject btn-sm" onclick="handleAction('${sanitize(request.id || request.requestId)}', 'rejected')">Reject</button>
            <button class="btn btn-approve btn-sm" id="approveBtn_${approveId}" ${isHotfix ? 'disabled title="Check the verification box above to enable"' : ''} onclick="handleAction('${approveId}', 'approved')">
                Approve & Start GA Process
            </button>
        `;
    } else {
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeDetailModal()">Close</button>`;
    }

    document.getElementById('detailModal').style.display = 'flex';
}

function onHotfixVerifyChange(approveId) {
    const chk = document.getElementById('hotfixVerifiedChk');
    const btn = document.getElementById(`approveBtn_${approveId}`);
    if (btn) btn.disabled = !chk?.checked;
}

// ---- Cancel a pending request (own request or admin) ----
async function cancelMyRequest(requestId) {
    if (!requestId) return;
    if (!confirm(`Cancel request ${requestId}?\n\nThe request will be permanently removed from the dashboard.`)) return;

    const editorEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/DeleteRequest`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, action: 'cancel', editorEmail })
        });
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.message || `HTTP ${res.status}`);
        }
        showToast(`Request ${requestId} cancelled.`, 'success');
        loadRequests();
    } catch (e) {
        showToast(`Cancel failed: ${e.message}`, 'error');
    }
}

// ---- Delete a request (admin only — temporary cleanup, any status) ----
async function deleteCompletedRequest(requestId, currentStatus) {
    if (!requestId) return;
    const statusNote = currentStatus ? ` (current status: ${currentStatus})` : '';
    if (!confirm(`Permanently DELETE request ${requestId}${statusNote}?\n\nThis cannot be undone. The record will be removed from storage entirely.`)) return;

    const editorEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/DeleteRequest`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, action: 'delete', editorEmail })
        });
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.message || `HTTP ${res.status}`);
        }
        showToast(`Request ${requestId} deleted.`, 'success');
        loadRequests();
    } catch (e) {
        showToast(`Delete failed: ${e.message}`, 'error');
    }
}

// ---- Submitter self-edit (Dashboard → Edit button on own pending requests) ----
let editingRequestSnapshot = null;

function openSubmitterEditModal(req) {
    if (!req) return;
    editingRequestSnapshot = req;

    document.getElementById('editRequestIdSuffix').textContent = `· ${req.id || req.requestId}`;
    document.getElementById('editRequestId').value     = req.id || req.requestId;
    document.getElementById('editRequestStatus').value = req.status || '';
    document.getElementById('editRequestTeam').value   = req.teamName || '';
    document.getElementById('editRequestCc').value     = Array.isArray(req.ccEmails) ? req.ccEmails.join(', ') : (req.ccEmails || '');
    document.getElementById('editRequestNotes').value  = req.notes || '';

    // Read-only summary of epics/apps so they remember what's in the request
    const summary = (req.epics || []).map(e => {
        const apps = (e.apps || []).map(a =>
            `<li><code>${sanitize(a.repoName || '')}</code> ← <code>${sanitize(a.sourceBranch || '')}</code></li>`
        ).join('');
        return `<div class="edit-request-epic">
            <strong>Epic #${sanitize(e.epicNumber)}</strong>${e.epicTitle ? ' — ' + sanitize(e.epicTitle) : ''}
            <ul>${apps || '<li><em>(no apps)</em></li>'}</ul>
        </div>`;
    }).join('');
    document.getElementById('editRequestEpicsSummary').innerHTML = summary || '<em>No epics on this request.</em>';

    document.getElementById('editRequestValidation').style.display = 'none';
    document.getElementById('editRequestValidation').textContent = '';

    document.getElementById('editRequestModal').style.display = 'flex';
}

function closeSubmitterEditModal() {
    document.getElementById('editRequestModal').style.display = 'none';
    editingRequestSnapshot = null;
}

async function saveSubmitterEdit() {
    if (!editingRequestSnapshot) return;
    const req = editingRequestSnapshot;

    const updates = {
        teamName: document.getElementById('editRequestTeam').value.trim(),
        ccEmails: document.getElementById('editRequestCc').value
            .split(',')
            .map(e => e.trim())
            .filter(Boolean),
        notes: document.getElementById('editRequestNotes').value.trim()
    };

    const editorEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
    if (!editorEmail) {
        const v = document.getElementById('editRequestValidation');
        v.style.display = '';
        v.classList.add('validation-error-active');
        v.textContent = 'Could not detect your signed-in email. Please reload and sign in again.';
        return;
    }

    const saveBtn = document.getElementById('editRequestSaveBtn');
    saveBtn.disabled = true;
    saveBtn.innerHTML = '<span class="spinner"></span> Saving…';

    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/EditRequest`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                requestId: req.id || req.requestId,
                editorEmail,
                updates
            })
        });
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.message || `HTTP ${res.status}`);
        }
        const data = await res.json();
        const sentTo = (data.notifiedGA || []).join(', ');
        showToast(`Request updated. GA team notified${sentTo ? ': ' + sentTo : ''}.`, 'success');
        closeSubmitterEditModal();
        loadRequests();
    } catch (e) {
        const v = document.getElementById('editRequestValidation');
        v.style.display = '';
        v.classList.add('validation-error-active');
        v.textContent = e.message;
    } finally {
        saveBtn.disabled = false;
        saveBtn.textContent = 'Save & Notify GA';
    }
}

function closeDetailModal() {
    document.getElementById('detailModal').style.display = 'none';
}

async function handleAction(requestId, action) {
    try {
        const approverEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
        const response = await fetch(`${CONFIG.apiBaseUrl}/ApproveRequest`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, action, approverEmail })
        });

        if (!response.ok) throw new Error('Failed to update request');

        showToast(`Request ${requestId} ${action === 'approved' ? 'approved — GA process initiated!' : 'rejected'}`,
            action === 'approved' ? 'success' : 'error');
        closeDetailModal();
        loadRequests();
    } catch (error) {
        showToast(`Action failed: ${error.message}`, 'error');
    }
}

// ---- Modals ----
function showSuccessModal(payload, requestId) {
    const details = document.getElementById('modalDetails');
    const epicsSummary = payload.epics.map(e =>
        `Epic #${sanitize(e.epicNumber)} (${e.apps.length} app${e.apps.length !== 1 ? 's' : ''})`
    ).join(', ');

    details.innerHTML = `
        <div class="detail-row">
            <span class="detail-label">Request ID</span>
            <span class="detail-value">${sanitize(requestId || 'GA-' + Date.now())}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Team</span>
            <span class="detail-value">${sanitize(payload.teamName)}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Release Type</span>
            <span class="detail-value">${payload.releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor'}</span>
        </div>
        <div class="detail-row">
            <span class="detail-label">Epics</span>
            <span class="detail-value">${epicsSummary}</span>
        </div>
    `;
    document.getElementById('successModal').style.display = 'flex';
}

function closeModal() {
    document.getElementById('successModal').style.display = 'none';
}

// ---- Toasts ----
function showToast(message, type = 'info') {
    let container = document.querySelector('.toast-container');
    if (!container) {
        container = document.createElement('div');
        container.className = 'toast-container';
        document.body.appendChild(container);
    }

    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    container.appendChild(toast);

    setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transform = 'translateX(100%)';
        toast.style.transition = 'all 0.3s';
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

// ---- Utilities ----
function sanitize(str) {
    if (str == null) return '';
    const div = document.createElement('div');
    div.textContent = String(str);
    return div.innerHTML;
}

function capitalizeFirst(str) {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1);
}

function getReleaseTypeLabel(type) {
    const labels = {
        'feature': 'Feature / Major',
        'stability': 'Stability / Minor',
        'hotfix': 'Hotfix',
        'service-pack': 'Service Pack'
    };
    return labels[type] || capitalizeFirst(type);
}

function getSampleData() {
    return [];
}

// ---- GA-Initial Tab ----
let gaRequests = [];
let gaPreviewData   = null;   // cached preview response
let gaModalPhase           = 'task'; // 'task' | 'pr'
let gaCreatedTasks         = {};     // key: "repoId|sourceBranch" → { taskId, taskUrl, consolidated, mergedTeamName }
let gaTaskCreationResults  = [];     // raw array from CreateGATask API

const GA_TASK_ASSIGNEES = [
    { email: 'krishna.s@aptean.com',        name: 'Krishna S' },
    { email: 'kapilkumar@aptean.com',        name: 'Kapil Kumar' },
    { email: 'subhavarman.rs@aptean.com',    name: 'Subhavarman RS' }
];

function getDefaultAssignee() {
    const me = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
    const match = GA_TASK_ASSIGNEES.find(a => a.email.toLowerCase() === me.toLowerCase());
    return match ? match.email : GA_TASK_ASSIGNEES[0].email;
}

function ensureTaskAssignees(data) {
    const def = getDefaultAssignee();
    (data.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (app.taskPreview && !app.taskPreview.assignedTo) {
                app.taskPreview.assignedTo = def;
            }
        });
    });
}

function gaMonthDisplayName(targetMonth) {
    const map = { JAN:'January', FEB:'February', MAR:'March', APR:'April', MAY:'May', JUN:'June',
                  JUL:'July', AUG:'August', SEP:'September', OCT:'October', NOV:'November', DEC:'December' };
    const abbr = (targetMonth || '').split(/[\s\-]+/)[0].toUpperCase();
    return map[abbr] || abbr;
}

function gaTaskTitle(appShortName, releaseType, targetMonth) {
    if (releaseType === 'hotfix') return `${appShortName} - Hotfix - GA Release Activity`;
    const month = gaMonthDisplayName(targetMonth);
    return `${appShortName} - ${month} Release - GA Release Activity`;
}

async function loadGARequests() {
    const statusFilter = document.getElementById('gaFilterStatus')?.value || '';
    const teamFilter = document.getElementById('gaFilterTeam')?.value || '';
    const releaseTypeFilter = document.getElementById('gaFilterReleaseType')?.value || '';

    const params = new URLSearchParams();
    if (statusFilter) params.set('status', statusFilter);
    if (teamFilter) params.set('team', teamFilter);

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetRequests?${params.toString()}`);
        if (!response.ok) throw new Error('Failed to load requests');
        gaRequests = await response.json();
    } catch (error) {
        gaRequests = [];
    }

    // Drop expired requests (30 days for completed, 45 for everything else)
    let filtered = gaRequests.filter(r => !isRequestExpired(r));
    if (releaseTypeFilter) {
        filtered = filtered.filter(r => r.releaseType === releaseTypeFilter);
    }

    // Populate team dropdown from loaded data (deduplicate)
    populateGATeamFilter(gaRequests);

    renderGARequestsTable(filtered);
}

function populateGATeamFilter(requests) {
    const select = document.getElementById('gaFilterTeam');
    if (!select) return;
    const current = select.value;
    const teams = [...new Set(requests.map(r => r.teamName).filter(Boolean))].sort();
    // Keep "All Teams" + add unique team options
    const opts = '<option value="">All Teams</option>' + teams.map(t => `<option value="${sanitize(t)}"${t === current ? ' selected' : ''}>${sanitize(t)}</option>`).join('');
    select.innerHTML = opts;
}

function renderGARequestsTable(requests) {
    const tbody = document.getElementById('gaRequestsBody');
    if (!tbody) return;

    if (requests.length === 0) {
        tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No requests found.</td></tr>';
        return;
    }

    tbody.innerHTML = requests.map(req => {
        const statusClass = `status-${(req.status || '').replace(/\s+/g, '-')}`;
        const releaseTypeMap = { feature: 'Feature / Major', stability: 'Stability / Minor', hotfix: 'Hotfix', 'service-pack': 'Service Pack' };
        const releaseClassMap = { feature: 'release-feature', stability: 'release-stability', hotfix: 'release-hotfix', 'service-pack': 'release-service-pack' };
        const releaseClass = releaseClassMap[req.releaseType] || 'release-stability';
        const releaseLabel = releaseTypeMap[req.releaseType] || req.releaseType || 'Unknown';
        const epics = (req.epics || []).map(e => `#${sanitize(e.epicNumber)}`).join(', ');
        const totalApps = (req.epics || []).reduce((sum, e) => sum + (e.apps || []).length, 0);
        const dt = new Date(req.submittedAt);
        const date = dt.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
        const time = dt.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: true });
        const reqId = sanitize(req.id || req.requestId);

        return `<tr>
            <td><strong>${reqId}</strong></td>
            <td>${sanitize(req.teamName)}</td>
            <td><span class="release-type-badge ${releaseClass}">${releaseLabel}</span></td>
            <td>${epics}</td>
            <td>${totalApps} app${totalApps !== 1 ? 's' : ''}</td>
            <td><span class="status-badge ${statusClass}">${sanitize(capitalizeFirst(req.status))}</span></td>
            <td><span class="submitted-datetime">${date}<br><span class="submitted-time">${time}</span></span></td>
            <td>
                <button class="btn btn-secondary btn-sm" onclick="openGAProcessModal('${reqId}')">View</button>
            </td>
        </tr>`;
    }).join('');
}

async function openGAProcessModal(requestId) {
    const body = document.getElementById('gaProcessModalBody');
    const footer = document.getElementById('gaProcessModalFooter');

    // Show loading state
    body.innerHTML = '<div class="ga-loading-state"><span class="spinner"></span> Loading version preview from repositories...</div>';
    footer.innerHTML = '';
    document.getElementById('gaProcessModal').style.display = 'flex';

    // Call PreviewGA API
    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/PreviewGA`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId })
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `API returned ${response.status}`);
        }

        gaPreviewData = await response.json();
        gaModalPhase = 'task';
        gaCreatedTasks = {};
        gaTaskCreationResults = [];
        ensureTaskAssignees(gaPreviewData);

        // If all non-error apps already have tasks (either epic-scoped or cross-team consolidated),
        // skip dialog 1 entirely and open the PR dialog directly.
        const allApps = (gaPreviewData.epics || []).flatMap(e =>
            (e.apps || []).filter(a => !a.error).map(a => ({ ...a, epicId: e.epicId }))
        );
        const appTaskDone = a => (a.task && a.task.id) || (a.globalTask && a.globalTask.taskId);
        if (allApps.length > 0 && allApps.every(appTaskDone)) {
            gaTaskCreationResults = allApps.map(a => {
                const isConsolidated = !(a.task && a.task.id) && !!(a.globalTask && a.globalTask.taskId);
                const taskId  = isConsolidated ? a.globalTask.taskId  : a.task.id;
                const taskUrl = isConsolidated
                    ? (a.globalTask.taskUrl || `${CONFIG.adoOrg}/${encodeURIComponent(CONFIG.adoProject)}/_workitems/edit/${a.globalTask.taskId}`)
                    : `${CONFIG.adoOrg}/${encodeURIComponent(CONFIG.adoProject)}/_workitems/edit/${a.task.id}`;
                return {
                    repoId:       a.repoId,
                    sourceBranch: a.sourceBranch,
                    epicId:       a.epicId,
                    success:      true,
                    taskId,
                    taskUrl,
                    consolidated: isConsolidated,
                    preExisting:  true
                };
            });
            gaTaskCreationResults.forEach(t => {
                gaCreatedTasks[`${t.repoId}|${t.sourceBranch}`] = {
                    taskId:         t.taskId,
                    taskUrl:        t.taskUrl,
                    epicId:         t.epicId,
                    consolidated:   false,
                    mergedTeamName: '',
                    previousTeam:   ''
                };
            });
            // Hide the loading dialog and go straight to the PR modal
            document.getElementById('gaProcessModal').style.display = 'none';
            openGAPRModal(requestId);
            return;
        }

        renderGAPreview(gaPreviewData, false);
    } catch (error) {
        body.innerHTML = `<div class="ga-error-state">Failed to load preview: ${sanitize(error.message)}</div>`;
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>`;
    }
}

function renderGAPreview(data, editMode) {
    const body = document.getElementById('gaProcessModalBody');
    const footer = document.getElementById('gaProcessModalFooter');

    const releaseLabel = (typeof getReleaseTypeLabel === 'function')
        ? getReleaseTypeLabel(data.releaseType)
        : (data.releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor');
    const canApprove = (data.status === 'in-progress' || data.status === 'approved') && isAdmin();
    const isHotfix = data.releaseType === 'hotfix';

    // Header info
    let html = `
        <div class="ga-field-grid">
            <span class="ga-field-label">Request ID</span>
            <span class="ga-field-value">${sanitize(data.requestId)}</span>
            <span class="ga-field-label">Team</span>
            <span class="ga-field-value">${sanitize(data.teamName)}</span>
            <span class="ga-field-label">Release Type</span>
            <span class="ga-field-value">${releaseLabel}</span>
            <span class="ga-field-label">Status</span>
            <span class="ga-field-value"><span class="status-badge status-${data.status}">${sanitize(capitalizeFirst(data.status))}</span></span>
        </div>
    `;

    // Epics with version preview
    (data.epics || []).forEach((epic, epicIdx) => {
        html += `<div class="ga-epic-card">
            <div class="ga-epic-card-header">
                <span>Epic #${sanitize(epic.epicId)}${epic.epicTitle ? ' — ' + sanitize(epic.epicTitle) : ''}</span>
            </div>`;

        // App version table (without App Name column)
        html += `<table class="ga-app-table">
            <thead><tr>
                <th>Repository</th>
                <th>Source Branch</th>
                <th>Current Version</th>
                <th>New Version</th>
                <th>AppSourceCop</th>
                <th>Target Branch</th>
            </tr></thead>
            <tbody>`;

        (epic.apps || []).forEach((app, appIdx) => {
            const hasError = !!app.error;
            const rowClass = hasError ? 'ga-row-error' : '';

            // Build target branch dropdown from branches
            let targetBranchHtml;
            if (editMode && app.branches && app.branches.length > 0) {
                const currentTarget = app._targetBranch || 'main';
                const opts = app.branches.map(b =>
                    `<option value="${sanitize(b.name)}" ${b.name === currentTarget ? 'selected' : ''}>${sanitize(b.name)}</option>`
                ).join('');
                targetBranchHtml = `<select class="ga-target-select" data-epic="${epicIdx}" data-app="${appIdx}" onchange="onGATargetChange(${epicIdx}, ${appIdx}, this.value)">${opts}</select>`;
            } else if (!editMode && app.branches && app.branches.length > 0) {
                const currentTarget = app._targetBranch || 'main';
                targetBranchHtml = `<code>${sanitize(currentTarget)}</code>`;
            } else {
                targetBranchHtml = '<code>main</code>';
            }

            // Version display — editable for feature/stability/service-pack.
            // Hotfix: read-only "Unchanged" since the app.json version isn't bumped.
            let newVersionHtml;
            if (hasError) {
                newVersionHtml = '—';
            } else if (isHotfix) {
                newVersionHtml = `<span class="ga-version-readonly" title="app.json version is not bumped on hotfix runs">${sanitize(app.currentVersion || '—')} <span class="hotfix-pill">Unchanged</span></span>`;
            } else {
                newVersionHtml = `<input type="text" class="ga-version-input" data-epic="${epicIdx}" data-app="${appIdx}" value="${sanitize(app.newVersion || '')}" onchange="onGAVersionChange(${epicIdx}, ${appIdx}, this.value)">`;
            }

            // AppSourceCop — editable in edit mode
            let appSourceCopHtml;
            if (editMode && !hasError) {
                appSourceCopHtml = `<input type="text" class="ga-version-input" data-epic="${epicIdx}" data-app="${appIdx}" value="${sanitize(app.appSourceCopVersion || '')}" onchange="onGAAppSourceCopChange(${epicIdx}, ${appIdx}, this.value)">`;
            } else {
                appSourceCopHtml = app.appSourceCopVersion ? sanitize(app.appSourceCopVersion) : '<em>N/A</em>';
            }

            html += `<tr class="${rowClass}">
                <td>${sanitize(app.repoName)}</td>
                <td><code>${sanitize(app.sourceBranch)}</code></td>
                <td>${hasError ? `<span class="ga-error-text">${sanitize(app.error)}</span>` : sanitize(app.currentVersion)}</td>
                <td>${newVersionHtml}</td>
                <td>${appSourceCopHtml}</td>
                <td>${targetBranchHtml}</td>
            </tr>`;
        });

        html += `</tbody></table>`;

        // Task Creation Preview section (replaces old task list)
        // Task preview section — only shown in task phase
        if (gaModalPhase === 'task') {
            html += `<div class="ga-task-preview-section">
            <h4 class="ga-task-preview-title">Task Creation Preview <span class="ga-phase-badge phase-task">Step 1 of 2</span></h4>
            <table class="ga-task-preview-table">
                <thead><tr>
                    <th>Task Title</th>
                    <th>App Name</th>
                    <th>Team Name</th>
                    <th>Version</th>
                    <th>Release Type</th>
                    <th>Assigned To</th>
                </tr></thead>
                <tbody>`;

            (epic.apps || []).forEach((app, appIdx) => {
                if (app.error) return;

                // Pre-existing task: created in a previous session — show read-only row
                const taskKey = `${app.repoId}|${app.sourceBranch}`;
                const preExistingTask = gaCreatedTasks[taskKey];
                if (preExistingTask && preExistingTask.taskId) {
                    const taskLink = preExistingTask.taskUrl
                        ? `<a href="${sanitize(preExistingTask.taskUrl)}" target="_blank" rel="noopener" class="ga-task-link">#${sanitize(String(preExistingTask.taskId))}</a>`
                        : `<strong>#${sanitize(String(preExistingTask.taskId))}</strong>`;
                    html += `<tr class="ga-task-row-pre-existing">
                        <td colspan="6">
                            <div class="ga-pre-existing-task-row">
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor" style="color:#059669;flex-shrink:0"><path d="M13.854 3.646a.5.5 0 0 1 0 .708l-7 7a.5.5 0 0 1-.708 0l-3.5-3.5a.5.5 0 1 1 .708-.708L6.5 10.293l6.646-6.647a.5.5 0 0 1 .708 0z"/></svg>
                                Task ${taskLink} already created for <strong>${sanitize(app.appShortName || app.repoName)}</strong>
                                <span class="ga-pre-existing-note">No action needed — proceed to Create PRs.</span>
                            </div>
                        </td>
                    </tr>`;
                    return;
                }

                // Cross-team consolidation: this app already has a task from another team
                const gt = app.globalTask;
                if (gt && gt.taskId) {
                    const taskLink = gt.taskUrl
                        ? `<a href="${sanitize(gt.taskUrl)}" target="_blank" rel="noopener" class="ga-task-link">#${sanitize(String(gt.taskId))}</a>`
                        : `<strong>#${sanitize(String(gt.taskId))}</strong>`;
                    html += `<tr class="ga-task-row-consolidated">
                        <td colspan="6">
                            <div class="ga-consolidation-preview-row">
                                <span class="ga-consolidation-badge">Consolidated</span>
                                Task ${taskLink} already exists for <strong>${sanitize(app.appShortName || app.repoName)}</strong>
                                — owned by <strong>${sanitize(gt.teamName || '—')}</strong>.
                                Your team (<strong>${sanitize(data.teamName)}</strong>) will be merged in when tasks are created.
                                <span class="ga-consolidation-readonly-note">Read-only — no new task will be created.</span>
                            </div>
                        </td>
                    </tr>`;
                    return; // skip editable row for this app
                }

                const tp = app.taskPreview || {};
                const rl = (data.releaseLabel) || (
                    data.releaseType === 'feature'      ? 'Major' :
                    data.releaseType === 'hotfix'       ? 'Hotfix' :
                    data.releaseType === 'service-pack' ? 'Service Pack' : 'Minor'
                );
                const taskTitle   = tp.title || gaTaskTitle(app.appShortName || app.repoName, data.releaseType, data.targetMonth || '');
                const taskVersion = isHotfix ? '—' : (tp.version || app.newVersion);
                const assignedTo  = tp.assignedTo || getDefaultAssignee();
                const assigneeOpts = GA_TASK_ASSIGNEES.map(a =>
                    `<option value="${sanitize(a.email)}" ${a.email === assignedTo ? 'selected' : ''}>${sanitize(a.name)}</option>`
                ).join('');

                if (editMode) {
                    html += `<tr>
                        <td><input type="text" class="ga-task-input" value="${sanitize(taskTitle)}" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'title', this.value)"></td>
                        <td><input type="text" class="ga-task-input" value="${sanitize(tp.appName || app.repoName)}" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'appName', this.value)"></td>
                        <td><input type="text" class="ga-task-input" value="${sanitize(tp.teamName || data.teamName)}" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'teamName', this.value)"></td>
                        <td>${isHotfix ? '<em>—</em>' : `<input type="text" class="ga-task-input ga-task-input-sm" value="${sanitize(taskVersion)}" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'version', this.value)">`}</td>
                        <td><input type="text" class="ga-task-input ga-task-input-sm" value="${sanitize(tp.releaseType || rl)}" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'releaseType', this.value)"></td>
                        <td><select class="ga-task-input ga-task-assignee-select" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'assignedTo', this.value)">${assigneeOpts}</select></td>
                    </tr>`;
                } else {
                    html += `<tr>
                        <td>${sanitize(taskTitle)}</td>
                        <td>${sanitize(tp.appName || app.repoName)}</td>
                        <td>${sanitize(tp.teamName || data.teamName)}</td>
                        <td>${sanitize(taskVersion)}</td>
                        <td>${sanitize(tp.releaseType || rl)}</td>
                        <td><select class="ga-task-assignee-select" onchange="onGATaskFieldChange(${epicIdx}, ${appIdx}, 'assignedTo', this.value)">${assigneeOpts}</select></td>
                    </tr>`;
                }
            });

            html += `</tbody></table></div>`;
        }
        html += `</div>`; // close ga-epic-card
    });


    body.innerHTML = html;

    // Prepend task creation summary whenever results exist (after task creation or pre-existing detection)
    if (gaTaskCreationResults.length > 0) {
        const taskSummaryHtml = renderTaskCreationSummary();
        body.innerHTML = taskSummaryHtml + body.innerHTML;
    }

    // Footer buttons
    if (canApprove) {
        const hasCreatedTasks = Object.keys(gaCreatedTasks).length > 0;

        if (editMode) {
            footer.innerHTML = `
                <button class="btn btn-secondary btn-sm" onclick="renderGAPreview(gaPreviewData, false)">Cancel Edit</button>
                <button class="btn btn-primary btn-sm" onclick="saveGAPreviewChanges()">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M11.5 1a.5.5 0 0 1 .5.5v4a.5.5 0 0 1-1 0V2H5v3.5A1.5 1.5 0 0 1 3.5 7H1v7h5.5a.5.5 0 0 1 0 1H.5a.5.5 0 0 1-.5-.5v-8l4-4h7.5z"/><path d="M15.854 8.646a.5.5 0 0 1 0 .708l-5 5a.5.5 0 0 1-.708 0l-2.5-2.5a.5.5 0 0 1 .708-.708L10.5 13.293l4.646-4.647a.5.5 0 0 1 .708 0z"/></svg>
                    Save Changes
                </button>
            `;
        } else if (hasCreatedTasks) {
            // Tasks exist (just created or pre-existing) — show "Create PRs"
            footer.innerHTML = `
                <button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>
                <button class="btn-initiate" onclick="openGAPRModal('${sanitize(data.requestId)}')">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M1 3.5A1.5 1.5 0 0 1 2.5 2h2.764c.958 0 1.76.56 2.311 1.184C7.985 3.648 8.48 4 9 4h4.5A1.5 1.5 0 0 1 15 5.5v.64c.57.265.94.876.856 1.546l-.64 5.124A2.5 2.5 0 0 1 12.733 15H3.267a2.5 2.5 0 0 1-2.483-2.19l-.64-5.124A1.5 1.5 0 0 1 1 6.14V3.5zm2-.5a.5.5 0 0 0-.5.5v2.5h11V5.5a.5.5 0 0 0-.5-.5H9c-.964 0-1.71-.629-2.174-1.154C6.374 3.334 5.82 3 5.264 3H2.5z"/></svg>
                    Create PRs
                    <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="margin-left:4px"><path d="M4 8a.5.5 0 0 1 .5-.5h5.793L8.146 5.354a.5.5 0 1 1 .708-.708l3 3a.5.5 0 0 1 0 .708l-3 3a.5.5 0 0 1-.708-.708L10.293 8.5H4.5A.5.5 0 0 1 4 8z"/></svg>
                </button>
            `;
        } else {
            const valid = validateTaskFields();
            footer.innerHTML = `
                <button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>
                <button class="btn btn-edit btn-sm" onclick="renderGAPreview(gaPreviewData, true)">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M12.146.854a.5.5 0 0 1 .708 0l2.292 2.292a.5.5 0 0 1 0 .708l-9.5 9.5a.5.5 0 0 1-.168.11l-4 1.5a.5.5 0 0 1-.65-.65l1.5-4a.5.5 0 0 1 .11-.168l9.5-9.5zM11.207 2.5L13.5 4.793 14.793 3.5 12.5 1.207 11.207 2.5zm1.586 3L10.5 3.207 3 10.707V11h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.293l7.5-7.5z"/></svg>
                    Edit
                </button>
                <button id="gaCreateTasksBtn" class="btn-initiate${valid ? '' : ' btn-initiate-disabled'}"
                    onclick="createGATasks('${sanitize(data.requestId)}')"
                    ${valid ? '' : 'disabled title="Fill in all task fields before creating tasks"'}>
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm.75 4.5v2.75H11.5a.75.75 0 0 1 0 1.5H8.75V12.5a.75.75 0 0 1-1.5 0V9.75H4.5a.75.75 0 0 1 0-1.5h2.75V5.5a.75.75 0 0 1 1.5 0z"/></svg>
                    Create Tasks
                    <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" style="margin-left:4px"><path d="M4 8a.5.5 0 0 1 .5-.5h5.793L8.146 5.354a.5.5 0 1 1 .708-.708l3 3a.5.5 0 0 1 0 .708l-3 3a.5.5 0 0 1-.708-.708L10.293 8.5H4.5A.5.5 0 0 1 4 8z"/></svg>
                </button>
            `;
        }
    } else {
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>`;
    }

    // Legacy: keep gaModalPhase in sync so external callers that still read it see the right state
    gaModalPhase = Object.keys(gaCreatedTasks).length > 0 ? 'pr' : 'task';
}


function renderTaskCreationSummary() {
    if (!gaTaskCreationResults.length) return '';
    const anyConsolidated = gaTaskCreationResults.some(t => t.consolidated && t.success);
    const items = gaTaskCreationResults.map(t => {
        if (!t.success) {
            return `<div class="ga-task-result-item ga-task-result-error">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 1.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zM7.25 4.75h1.5v5h-1.5v-5zm0 6h1.5v1.5h-1.5v-1.5z"/></svg>
                <span><strong>${sanitize(t.repoId || t.sourceBranch)}</strong> — task failed: ${sanitize(t.error || 'Unknown error')}</span>
            </div>`;
        }
        const taskLink = t.taskUrl
            ? `<a href="${sanitize(t.taskUrl)}" target="_blank" rel="noopener" class="ga-task-link">#${sanitize(String(t.taskId))}</a>`
            : `<strong>#${sanitize(String(t.taskId))}</strong>`;
        if (t.consolidated) {
            return `<div class="ga-task-result-item ga-task-result-consolidated">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm3.53 4.97a.75.75 0 0 1 0 1.06L7.06 11.5a.75.75 0 0 1-1.06 0L4.47 9.97a.75.75 0 0 1 1.06-1.06l1 1 4-4a.75.75 0 0 1 1 .06z"/></svg>
                <span>Task ${taskLink} consolidated — team updated to <strong>${sanitize(t.mergedTeamName || '')}</strong>
                    <span class="ga-consolidation-badge">Consolidated</span></span>
            </div>`;
        }
        if (t.preExisting) {
            return `<div class="ga-task-result-item ga-task-result-existing">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm.75 4.5v2.75H11.5a.75.75 0 0 1 0 1.5H8.75V12.5a.75.75 0 0 1-1.5 0V9.75H4.5a.75.75 0 0 1 0-1.5h2.75V5.5a.75.75 0 0 1 1.5 0z"/></svg>
                <span>Task ${taskLink} already exists</span>
            </div>`;
        }
        return `<div class="ga-task-result-item ga-task-result-created">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>
            <span>Task ${taskLink} created</span>
        </div>`;
    }).join('');

    const allPreExisting = gaTaskCreationResults.length > 0 && gaTaskCreationResults.every(t => t.preExisting);
    const headerText = allPreExisting
        ? 'Tasks already exist — review versions and create PRs'
        : 'Tasks ready — Step 2: Review versions and create PRs';
    return `<div class="ga-task-creation-summary${anyConsolidated ? ' has-consolidated' : ''}${allPreExisting ? ' all-existing' : ''}">
        <div class="ga-task-summary-header">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>
            ${headerText}
        </div>
        <div class="ga-task-result-list">${items}</div>
        ${anyConsolidated ? `<p class="ga-consolidation-note">One or more tasks were <strong>consolidated</strong>: the existing task's team name was updated to include the new team. Both requests share the same ADO task.</p>` : ''}
    </div>`;
}

function onGATargetChange(epicIdx, appIdx, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        gaPreviewData.epics[epicIdx].apps[appIdx]._targetBranch = value;
    }
}

function onGAVersionChange(epicIdx, appIdx, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        gaPreviewData.epics[epicIdx].apps[appIdx].newVersion = value;
        // Also update task preview version
        if (!gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview) {
            gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview = {};
        }
        gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview.version = value;
        // Re-render to reflect version in task preview and PR preview
        const isEdit = !!document.querySelector('.ga-version-input');
        renderGAPreview(gaPreviewData, isEdit);
        // Restore focus to the version input that was just edited
        const input = document.querySelector(`.ga-version-input[data-epic="${epicIdx}"][data-app="${appIdx}"]`);
        if (input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
    }
}

function onGAAppSourceCopChange(epicIdx, appIdx, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        gaPreviewData.epics[epicIdx].apps[appIdx].appSourceCopVersion = value;
    }
}

function onGATaskFieldChange(epicIdx, appIdx, field, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        if (!gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview) {
            gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview = {};
        }
        gaPreviewData.epics[epicIdx].apps[appIdx].taskPreview[field] = value;
    }
}

function saveGAPreviewChanges() {
    // Save is just persisting to gaPreviewData (already done via onchange handlers)
    // Switch back to read-only view
    showToast('Changes saved', 'success');
    renderGAPreview(gaPreviewData, false);
}

function validateTaskFields() {
    if (!gaPreviewData) return false;
    for (const epic of (gaPreviewData.epics || [])) {
        for (const app of (epic.apps || [])) {
            if (app.error) continue;
            const tp = app.taskPreview || {};
            if (!tp.title || !tp.appName || !tp.teamName || !tp.version || !tp.releaseType) return false;
        }
    }
    return true;
}

async function createGATasks(requestId) {
    if (!gaPreviewData) return;

    const appsPayload = [];
    (gaPreviewData.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (!app.error) {
                const tp = app.taskPreview || {};
                appsPayload.push({
                    epicId:       epic.epicId,
                    repoId:       app.repoId,
                    repoName:     app.repoName,
                    sourceBranch: app.sourceBranch,
                    targetMonth:  gaPreviewData.targetMonth || '',
                    taskPreview: {
                        title:           tp.title       || gaTaskTitle(app.appShortName || app.repoName, gaPreviewData.releaseType, gaPreviewData.targetMonth || ''),
                        appName:         tp.appName     || app.repoName,
                        teamName:        tp.teamName    || gaPreviewData.teamName,
                        version:         tp.version     || app.newVersion,
                        releaseType:     tp.releaseType || gaPreviewData.releaseLabel,
                        assignedTo:      tp.assignedTo  || getDefaultAssignee(),
                        assignedToName:  GA_TASK_ASSIGNEES.find(a => a.email === (tp.assignedTo || getDefaultAssignee()))?.name || ''
                    }
                });
            }
        });
    });

    const createBtn = document.getElementById('gaCreateTasksBtn');
    if (createBtn) { createBtn.disabled = true; createBtn.textContent = 'Creating tasks…'; }

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CreateGATask`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, apps: appsPayload, releaseWiId: gaPreviewData.releaseWiId || '' })
        });
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || `API returned ${response.status}`);

        gaCreatedTasks = {};
        gaTaskCreationResults = data.tasks || [];
        (data.tasks || []).forEach(t => {
            if (t.success) {
                gaCreatedTasks[`${t.repoId}|${t.sourceBranch}`] = {
                    taskId:        t.taskId,
                    taskUrl:       t.taskUrl || '',
                    epicId:        t.epicId,
                    consolidated:  t.consolidated,
                    mergedTeamName: t.mergedTeamName || '',
                    previousTeam:  t.previousTeam || ''
                };
            }
        });

        renderGAPreview(gaPreviewData, false);
        showToast(
            data.success ? 'Tasks created — now review and create PRs' : 'Tasks created with some errors',
            data.success ? 'success' : 'error'
        );
    } catch (err) {
        showToast(`Task creation failed: ${err.message}`, 'error');
        if (createBtn) { createBtn.disabled = false; createBtn.textContent = 'Create Tasks →'; }
    }
}

function closeGAProcessModal() {
    document.getElementById('gaProcessModal').style.display = 'none';
    gaPreviewData = null;
    gaModalPhase = 'task';
    gaCreatedTasks = {};
    gaTaskCreationResults = [];
}

// ---- GA PR Modal (Dialog 2) ----

function openGAPRModal(requestId) {
    if (!gaPreviewData) return;
    const data = gaPreviewData;
    const isHotfix = data.releaseType === 'hotfix';

    // Build task summary strip
    const taskSummaryHtml = renderTaskCreationSummary();

    // Build PR details per epic/app
    let prHtml = '';
    (data.epics || []).forEach(epic => {
        const appRows = (epic.apps || []).filter(a => !a.error);
        if (!appRows.length) return;
        appRows.forEach(app => {
            const targetBr  = app._targetBranch || 'main';
            const commitMsg = isHotfix
                ? `AppSourceCop update (Hotfix) — ${sanitize(app.appShortName || app.repoName)} from BC GA team`
                : `v${sanitize(app.newVersion)} ${sanitize(data.releaseLabel)} Release from BC GA team`;
            const ascVer    = app.appSourceCopVersion ? sanitize(app.appSourceCopVersion) : 'N/A';
            const curVer    = sanitize(app.currentVersion || '—');
            const newVer    = isHotfix ? curVer : sanitize(app.newVersion || '—');

            prHtml += `
            <div class="ga-pr-detail-card">
                <div class="ga-pr-detail-header">
                    <span class="ga-pr-repo">${sanitize(app.repoName)}</span>
                    <span class="ga-pr-arrow">→</span>
                    <code class="ga-pr-branch">${sanitize(app.sourceBranch)}</code>
                    <span class="ga-pr-arrow">→</span>
                    <code class="ga-pr-branch">${sanitize(targetBr)}</code>
                    <span class="ga-pr-commit">${commitMsg}</span>
                </div>
                <div class="ga-pr-detail-checks">
                    <div class="ga-pr-check-item">
                        <span class="ga-pr-check-label">app.json</span>
                        <span class="ga-pr-check-value">${curVer} → <strong>${newVer}</strong></span>
                    </div>
                    <div class="ga-pr-check-item">
                        <span class="ga-pr-check-label">appsourcecop.json</span>
                        <span class="ga-pr-check-value"><strong>${ascVer}</strong></span>
                    </div>
                    <div class="ga-pr-check-item">
                        <span class="ga-pr-check-label">Permissionset</span>
                        <span class="ga-pr-check-value ga-pr-check-auto">Updated automatically if present</span>
                    </div>
                </div>
            </div>`;
        });
    });

    const reviewersHtml = `
        <div class="ga-pr-reviewers">
            <strong>Reviewers:</strong> kapilkumar@aptean.com, subhavarman.rs@aptean.com
        </div>`;

    const translationNoteHtml = `
        <div class="ga-pr-preflight-note">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm0 1.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11zm-.75 3.25h1.5v4h-1.5v-4zm0 5h1.5v1.5h-1.5v-1.5z"/></svg>
            Translation check will run automatically before PRs are created. If missing translations are found you will be prompted to confirm or halt.
        </div>`;

    const body   = document.getElementById('gaPRModalBody');
    const footer = document.getElementById('gaPRModalFooter');

    body.innerHTML = taskSummaryHtml +
        `<div class="ga-pr-preview"><h3>PR Preview</h3><div class="ga-pr-preview-content">${prHtml}</div>${reviewersHtml}</div>` +
        translationNoteHtml;

    footer.innerHTML = `
        <button class="btn btn-secondary btn-sm" onclick="closeGAPRModal()">Close</button>
        <button class="btn-initiate" onclick="approveAndProcess('${sanitize(requestId)}')">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>
            Create PRs
        </button>`;

    document.getElementById('gaPRModal').style.display = 'flex';
}

function closeGAPRModal() {
    document.getElementById('gaPRModal').style.display = 'none';
}

function collectAppsForValidation() {
    const seen = new Set();
    const out = [];
    (gaPreviewData?.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (!app.error && app.repoId && app.sourceBranch) {
                const key = `${app.repoId}|${app.sourceBranch}`;
                if (!seen.has(key)) {
                    seen.add(key);
                    out.push({
                        repoId: app.repoId,
                        repoName: app.repoName,
                        sourceBranch: app.sourceBranch,
                        epicNumber: epic.epicId
                    });
                }
            }
        });
    });
    return out;
}

function openValidationModalAtProgress() {
    document.getElementById('gaValidationModal').style.display = 'flex';
    document.getElementById('gaValidationProgressBody').style.display = '';
    document.getElementById('gaValidationIssuesBody').style.display = 'none';
    document.getElementById('gaValidationIssuesFooter').style.display = 'none';
    document.getElementById('gaValidationTitle').textContent = 'Validating translations…';
    setValidationProgress(0, 'Initializing…');
}
function closeValidationModal() {
    document.getElementById('gaValidationModal').style.display = 'none';
}
function setValidationProgress(pct, statusText) {
    const fill = document.getElementById('validationProgressFill');
    const txt  = document.getElementById('validationProgressPercent');
    const stat = document.getElementById('validationProgressStatus');
    if (fill) fill.style.width = `${pct}%`;
    if (txt)  txt.textContent  = `${pct}%`;
    if (stat) stat.textContent = statusText;
}
// Switch the SAME modal from "validating" to "issues found" view.
function transitionValidationModalToIssues(missing) {
    document.getElementById('gaValidationProgressBody').style.display = 'none';
    document.getElementById('gaValidationIssuesBody').style.display = '';
    document.getElementById('gaValidationIssuesFooter').style.display = 'flex';
    document.getElementById('gaValidationTitle').textContent = 'Translation check — confirmation needed';

    // Render the per-app grouped table
    const count = document.getElementById('missingTranslationsCount');
    const body  = document.getElementById('missingTranslationsBody');
    count.textContent = `${missing.length} missing item${missing.length === 1 ? '' : 's'}`;

    const byApp = {};
    missing.forEach(m => {
        const app = m.appName || 'Unknown';
        (byApp[app] = byApp[app] || []).push(m);
    });
    let html = '';
    Object.keys(byApp).sort().forEach(app => {
        html += `<tr class="missing-app-header"><td colspan="3"><strong>${sanitize(app)}</strong></td></tr>`;
        byApp[app].forEach(m => {
            html += `<tr>
                <td><code>${sanitize(m.file || '')}:${sanitize(String(m.line || ''))}</code></td>
                <td>${sanitize(m.type || '')}</td>
                <td>${sanitize(m.text || '')}</td>
            </tr>`;
        });
    });
    body.innerHTML = html || '<tr><td colspan="3" class="empty-state">No items.</td></tr>';
}

async function validateOneApp(requestId, app) {
    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/ValidateTranslations`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                requestId,
                repoId:       app.repoId,
                sourceBranch: app.sourceBranch,
                appName:      app.repoName,
                epicNumber:   app.epicNumber
            })
        });
        if (!res.ok) return { missing: [] };
        return await res.json();
    } catch (e) {
        console.warn(`Translation validation failed for ${app.repoName}:`, e);
        return { missing: [] };
    }
}

async function approveAndProcess(requestId) {
    if (!gaPreviewData) return;

    const apps = collectAppsForValidation();
    if (apps.length === 0) {
        // Nothing to check — proceed straight to InitiateGA
        runInitiateGA(requestId, /* skipTranslationCheck */ false);
        return;
    }

    // Open the unified validation modal in "progress" mode
    openValidationModalAtProgress();
    setValidationProgress(0, `Preparing to check ${apps.length} app${apps.length === 1 ? '' : 's'}…`);

    let allMissing = [];
    for (let i = 0; i < apps.length; i++) {
        const a = apps[i];
        const startPct = Math.round((i / apps.length) * 100);
        setValidationProgress(startPct, `Validating: ${a.repoName} (${i + 1} of ${apps.length})`);

        const result = await validateOneApp(requestId, a);
        if (result.missing && result.missing.length > 0) {
            allMissing = allMissing.concat(result.missing);
        }

        const endPct = Math.round(((i + 1) / apps.length) * 100);
        setValidationProgress(endPct, `Validated: ${a.repoName}`);
    }

    setValidationProgress(100, 'Validation complete');
    await new Promise(r => setTimeout(r, 350));   // brief pause so the user sees 100%

    if (allMissing.length > 0) {
        // Stay in the same modal — swap to the "issues found + confirmation" view
        pendingTranslationContext = { requestId, missing: allMissing };
        transitionValidationModalToIssues(allMissing);
    } else {
        closeValidationModal();
        runInitiateGA(requestId, /* skipTranslationCheck */ false);
    }
}

function buildAppOverridesFromPreview() {
    const appOverrides = [];
    (gaPreviewData.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (!app.error) {
                const key      = `${app.repoId}|${app.sourceBranch}`;
                const taskInfo = gaCreatedTasks[key];
                appOverrides.push({
                    repoId:             app.repoId,
                    repoName:           app.repoName,
                    sourceBranch:       app.sourceBranch,
                    targetBranch:       app._targetBranch || 'main',
                    newVersion:         app.newVersion,
                    epicId:             epic.epicId,
                    appSourceCopVersion: app.appSourceCopVersion || null,
                    taskPreview:        app.taskPreview || null,
                    existingTaskId:     taskInfo ? String(taskInfo.taskId) : ''
                });
            }
        });
    });
    return appOverrides;
}

async function runInitiateGA(requestId, skipTranslationCheck) {
    if (!gaPreviewData) return;
    const appOverrides = buildAppOverridesFromPreview();

    closeGAPRModal();
    closeGAProcessModal();

    // Show progress modal
    const progressLog = document.getElementById('gaProgressLog');
    const closeBtn = document.getElementById('gaProgressCloseBtn');
    progressLog.innerHTML = '';
    closeBtn.disabled = true;
    document.getElementById('gaProgressModal').style.display = 'flex';

    function addLog(msg, type = 'info') {
        const line = document.createElement('div');
        line.className = `log-${type}`;
        line.textContent = msg;
        progressLog.appendChild(line);
        progressLog.scrollTop = progressLog.scrollHeight;
    }

    addLog(`Starting GA-Initial process for ${requestId}...`, 'info');
    addLog(`Apps to process: ${appOverrides.length}`, 'info');
    if (skipTranslationCheck) {
        addLog(`[AUDIT] Translation validation was skipped by initiator`, 'warn');
    }
    addLog(`Reviewers will be assigned dynamically (excluding initiator)`, 'info');
    addLog('');

    try {
        const initiatorEmail = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '') || '';
        const initiatorName  = GA_TASK_ASSIGNEES.find(a => a.email.toLowerCase() === initiatorEmail.toLowerCase())?.name || initiatorEmail;
        const response = await fetch(`${CONFIG.apiBaseUrl}/InitiateGA`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, appOverrides, initiatorEmail, initiatorName, skipTranslationCheck: !!skipTranslationCheck, releaseWiId: gaPreviewData?.releaseWiId || '' })
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `API returned ${response.status}`);
        }

        const data = await response.json();

        (data.results || []).forEach(r => {
            addLog(`── ${r.repoName} (Epic #${r.epicId}) ──`, 'info');

            if (r.log && Array.isArray(r.log)) {
                r.log.forEach(logLine => {
                    let type = 'info';
                    if (logLine.startsWith('[SUCCESS]')) type = 'success';
                    else if (logLine.startsWith('[ERROR]')) type = 'error';
                    else if (logLine.startsWith('[WARN]')) type = 'warn';
                    addLog(logLine, type);
                });
            }

            if (r.success) {
                addLog(`Result: ${r.oldVersion} → ${r.newVersion} | Commit: ${r.commitMsg}`, 'success');
            } else {
                addLog(`Failed: ${r.error || 'Unknown error'}`, 'error');
            }
            addLog('');
        });

        if (data.success) {
            addLog('=== All apps processed successfully! ===', 'success');
            showToast('GA-Initial process completed successfully', 'success');
        } else {
            addLog('=== Process completed with errors ===', 'error');
            showToast('GA-Initial process completed with errors', 'error');
        }
    } catch (error) {
        addLog(`FATAL ERROR: ${error.message}`, 'error');
        showToast(`GA-Initial failed: ${error.message}`, 'error');
    }

    closeBtn.disabled = false;
    loadGARequests();
}

function closeGAProgressModal() {
    document.getElementById('gaProgressModal').style.display = 'none';
}

// ---- Missing-translations gate (rendered inside the unified validation modal) ----
let pendingTranslationContext = null;   // { requestId, missing }

// User clicked "Yes — Proceed without translations"
function proceedWithoutTranslations() {
    if (!pendingTranslationContext) return;
    const { requestId } = pendingTranslationContext;
    closeValidationModal();
    pendingTranslationContext = null;
    runInitiateGA(requestId, /* skipTranslationCheck */ true);
}

// User clicked "No — Notify submitter & halt"
async function notifySubmitterMissingTranslations() {
    if (!pendingTranslationContext) return;
    const { requestId, missing } = pendingTranslationContext;

    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/NotifyMissingTranslations`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, missing })
        });
        if (!res.ok) throw new Error('API returned ' + res.status);
        const data = await res.json();
        if (data.notified) {
            showToast(`Submitter notified at ${data.recipient}. GA halted.`, 'info');
        } else {
            showToast(`GA halted. Email could not be sent (check POWER_AUTOMATE_WEBHOOK_URL).`, 'warn');
        }
    } catch (e) {
        showToast(`Failed to notify submitter: ${e.message}`, 'error');
    } finally {
        closeValidationModal();
        pendingTranslationContext = null;
    }
}

// ---- Target Month Helpers ----
const MONTH_NAMES = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

function populateTargetMonths() {
    const select = document.getElementById('targetMonth');
    const now = new Date();
    const currentMonth = now.getMonth();
    const currentYear = now.getFullYear();

    for (let i = 0; i < 12; i++) {
        const mIdx = (currentMonth + i) % 12;
        const year = currentYear + Math.floor((currentMonth + i) / 12);
        // Format: "MAY GA2026" — both stored value and display label.
        const value = `${MONTH_NAMES[mIdx]} GA${year}`;
        const opt = document.createElement('option');
        opt.value = value;
        opt.textContent = value;
        if (i === 0) opt.selected = true;
        select.appendChild(opt);
    }
}

function formatTargetMonth(value) {
    // New format ("MAY GA2026") needs no transformation. Legacy values
    // ("JAN-2026") are normalized to "JAN GA2026" so dashboards stay consistent.
    if (!value) return '';
    const m = String(value).match(/^([A-Z]{3,})[-\s]+(GA)?(\d{4})$/i);
    if (m) return `${m[1].toUpperCase()} GA${m[3]}`;
    return value;
}

// ============================================
//  GA Subtab Navigation
// ============================================
function showGASubtab(subtabName) {
    document.querySelectorAll('.ga-subtab').forEach(btn => btn.classList.remove('active'));
    document.querySelectorAll('.ga-subtab-content').forEach(el => el.classList.remove('active'));

    const btn = document.querySelector(`.ga-subtab[data-subtab="${subtabName}"]`);
    const content = document.getElementById(`subtab-${subtabName}`);
    if (btn) btn.classList.add('active');
    if (content) content.classList.add('active');

    // Lazy-load data for certain tabs
    if (subtabName === 'ga-livestatus') {
        populateLiveStatusRepoDropdown();
    }
    if (subtabName === 'ga-closure') {
        // Auto-discover GA Validation epics + their BC GA tasks on first open
        // (skip if results are already loaded from a previous click)
        if (!closureTasks || closureTasks.length === 0) {
            loadClosureEpics();
        }
    }
}

// ============================================
//  Rebase Tool
// ============================================
const IGNORED_REPOS = [
    'Aptean.FB.DevOps', 'Aptean.Translations', 'FB-DataVerse-Integration',
    'FB-Translations', 'FB.Migration', 'FBConfiguration', 'FBBusinessInsights',
    'FBDataLake', 'FBDeliverySW', 'FBECommerce', 'FBField', 'FBMasterPlanning',
    'FBPowerAutomate', 'FBSRE', 'FBTranslation', 'FBWarehouseSW', 'ManualTests',
    'Aptean.Common', 'FB-BCOnPrem-DevOps', 'FB-DevOps', 'FB.Infrastructure',
    'FB.PrivateExtensions'
];

let rebaseRepos = []; // scanned repos with sync data

async function scanRebaseRepos() {
    const statusEl = document.getElementById('rebaseStatus');
    const tbody = document.getElementById('rebaseBody');
    const actionsEl = document.getElementById('rebaseActions');

    statusEl.textContent = 'Loading repository list…';
    tbody.innerHTML = '<tr><td colspan="7" class="empty-state"><span class="spinner"></span> Loading repository list…</td></tr>';
    actionsEl.style.display = 'none';

    try {
        // 1) Get the list of repos to scan
        const listRes = await fetch(`${CONFIG.apiBaseUrl}/ScanRebaseList`);
        if (!listRes.ok) throw new Error('Failed to list repos');
        const repoList = await listRes.json();
        const total = repoList.length;

        if (total === 0) {
            tbody.innerHTML = '<tr><td colspan="7" class="empty-state">No repositories found.</td></tr>';
            statusEl.textContent = '';
            return;
        }

        // 2) Scan each repo, render results incrementally with live progress
        rebaseRepos = [];
        let skippedInactive = 0;
        const renderProgress = () => {
            statusEl.textContent = `Scanning ${rebaseRepos.length} / ${total}…`;
        };
        const renderTable = () => {
            if (rebaseRepos.length === 0) {
                tbody.innerHTML = `<tr><td colspan="7" class="empty-state"><span class="spinner"></span> Scanning ${rebaseRepos.length + 1} / ${total}…</td></tr>`;
                return;
            }
            tbody.innerHTML = rebaseRepos.map((repo, idx) => {
                const isOutOfSync = repo.behindBy > 0;
                // Out-of-sync rows: render an action button instead of a passive badge
                let statusCell;
                if (repo._rebaseState === 'rebasing') {
                    statusCell = '<span class="sync-badge rebasing">Rebasing…</span>';
                } else if (repo._rebaseState === 'done') {
                    statusCell = '<span class="sync-badge done">Rebased</span>';
                } else if (repo._rebaseState === 'failed') {
                    statusCell = `<span class="sync-badge failed" title="${sanitize(repo._rebaseError || '')}">Failed</span>`;
                } else if (isOutOfSync) {
                    statusCell = `<button type="button" class="sync-badge out-of-sync sync-badge-button" onclick="rebaseOneRepo(${idx})" title="Click to start rebase for this repo">Out of Sync — Rebase ▶</button>`;
                } else {
                    statusCell = '<span class="sync-badge in-sync">In Sync</span>';
                }
                return `<tr>
                    <td>${isOutOfSync && !repo._rebaseState ? `<input type="checkbox" class="rebase-check" data-idx="${idx}">` : ''}</td>
                    <td>${idx + 1}</td>
                    <td><strong>${sanitize(repo.name || '')}</strong></td>
                    <td><span class="commit-hash">${sanitize((repo.developCommit || '').substring(0, 8))}</span></td>
                    <td><span class="commit-hash">${sanitize((repo.mainCommit || '').substring(0, 8))}</span></td>
                    <td>${repo.behindBy || 0}</td>
                    <td>${statusCell}</td>
                </tr>`;
            }).join('');
        };

        for (let i = 0; i < total; i++) {
            const r = repoList[i];
            statusEl.textContent = `Scanning ${i + 1} / ${total} — ${r.name}`;
            try {
                const oneRes = await fetch(`${CONFIG.apiBaseUrl}/ScanRebaseOne?repoId=${encodeURIComponent(r.id)}&repoName=${encodeURIComponent(r.name)}`);
                if (oneRes.ok) {
                    const oneData = await oneRes.json();
                    if (oneData.row && !oneData.skipped) {
                        rebaseRepos.push(oneData.row);
                        renderTable();
                    } else if (oneData.skipped) {
                        skippedInactive++;
                    }
                }
            } catch (e) {
                console.warn(`Scan failed for ${r.name}:`, e);
            }
        }

        // 3) Final sort and summary
        rebaseRepos.sort((a, b) => (b.behindBy || 0) - (a.behindBy || 0) || a.name.localeCompare(b.name));
        renderTable();

        const outOfSync = rebaseRepos.filter(r => r.behindBy > 0).length;
        const parts = [`${rebaseRepos.length} / ${total} repos scanned`, `${outOfSync} out of sync`];
        if (skippedInactive > 0) parts.push(`${skippedInactive} skipped (inactive 1y+)`);
        statusEl.textContent = parts.join(' — ');
        actionsEl.style.display = outOfSync > 0 ? 'flex' : 'none';
    } catch (error) {
        tbody.innerHTML = `<tr><td colspan="7" class="empty-state" style="color:#f87171">Error: ${error.message}</td></tr>`;
        statusEl.textContent = '';
    }
}

function toggleRebaseSelectAll(checkbox) {
    document.querySelectorAll('.rebase-check').forEach(cb => cb.checked = checkbox.checked);
}

function toggleRebaseSelection(selectOutOfSync) {
    document.querySelectorAll('.rebase-check').forEach(cb => {
        cb.checked = selectOutOfSync;
    });
}

// Live filter the rebase table by repo name. Triggered by the search input.
function filterRebaseRepos() {
    renderRebaseTable();
}

// Re-render the rebase table from the current rebaseRepos state (used after
// per-row state flips so the cell becomes "Rebasing…" / "Rebased" / "Failed").
// Honors the #rebaseSearch input as a case-insensitive substring filter on name.
function renderRebaseTable() {
    const tbody = document.getElementById('rebaseBody');
    if (!tbody || !rebaseRepos) return;

    const searchInput = document.getElementById('rebaseSearch');
    const q = (searchInput && searchInput.value || '').trim().toLowerCase();

    // Build a view list keeping the original index of each repo so onclick
    // handlers + checkboxes still reference the canonical rebaseRepos[idx].
    const visible = rebaseRepos
        .map((repo, idx) => ({ repo, idx }))
        .filter(({ repo }) => !q || (repo.name || '').toLowerCase().includes(q));

    if (visible.length === 0) {
        tbody.innerHTML = `<tr><td colspan="7" class="empty-state">${q ? 'No repos match "' + sanitize(q) + '"' : 'No scan results yet.'}</td></tr>`;
        return;
    }

    tbody.innerHTML = visible.map(({ repo, idx }) => {
        const isOutOfSync = repo.behindBy > 0;
        let statusCell;
        if (repo._rebaseState === 'rebasing') {
            statusCell = '<span class="sync-badge rebasing">Rebasing…</span>';
        } else if (repo._rebaseState === 'done') {
            statusCell = '<span class="sync-badge done">Rebased</span>';
        } else if (repo._rebaseState === 'failed') {
            statusCell = `<span class="sync-badge failed" title="${sanitize(repo._rebaseError || '')}">Failed</span>`;
        } else if (isOutOfSync) {
            statusCell = `<button type="button" class="sync-badge out-of-sync sync-badge-button" onclick="rebaseOneRepo(${idx})" title="Click to start rebase for this repo">Out of Sync — Rebase ▶</button>`;
        } else {
            statusCell = '<span class="sync-badge in-sync">In Sync</span>';
        }
        return `<tr>
            <td>${isOutOfSync && !repo._rebaseState ? `<input type="checkbox" class="rebase-check" data-idx="${idx}">` : ''}</td>
            <td>${idx + 1}</td>
            <td><strong>${sanitize(repo.name || '')}</strong></td>
            <td><span class="commit-hash">${sanitize((repo.developCommit || '').substring(0, 8))}</span></td>
            <td><span class="commit-hash">${sanitize((repo.mainCommit || '').substring(0, 8))}</span></td>
            <td>${repo.behindBy || 0}</td>
            <td>${statusCell}</td>
        </tr>`;
    }).join('');
}

// Rebase a single repo (called from the per-row Out-of-Sync button).
async function rebaseOneRepo(idx) {
    const repo = rebaseRepos[idx];
    if (!repo) return;
    if (!confirm(`Rebase develop onto main for "${repo.name}"?`)) return;

    repo._rebaseState = 'rebasing';
    renderRebaseTable();

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/RebaseRepos`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ repos: [{ id: repo.id, name: repo.name }] })
        });
        if (!response.ok) throw new Error('Rebase API failed');
        const results = await response.json();
        const r = (Array.isArray(results) ? results : [])[0] || {};
        if (r.success) {
            repo._rebaseState = 'done';
            repo._rebaseError = null;
            showToast(`Rebased ${repo.name}.`, 'success');
        } else {
            repo._rebaseState = 'failed';
            repo._rebaseError = r.error || 'Unknown error';
            showToast(`Rebase failed for ${repo.name}: ${repo._rebaseError}`, 'error');
        }
    } catch (e) {
        repo._rebaseState = 'failed';
        repo._rebaseError = e.message;
        showToast(`Rebase failed for ${repo.name}: ${e.message}`, 'error');
    }
    renderRebaseTable();
}

// Bulk rebase from the toolbar — calls rebaseOneRepo for each selected repo.
async function startRebase() {
    const selectedIdxs = [];
    document.querySelectorAll('.rebase-check:checked').forEach(cb => {
        const idx = parseInt(cb.dataset.idx);
        if (rebaseRepos[idx]) selectedIdxs.push(idx);
    });

    if (selectedIdxs.length === 0) {
        alert('Please select at least one out-of-sync repository.');
        return;
    }
    if (!confirm(`Rebase ${selectedIdxs.length} repo(s)? This will rebase develop onto main for each.`)) return;

    // Mark each row as rebasing up-front for fast UX feedback
    selectedIdxs.forEach(i => { rebaseRepos[i]._rebaseState = 'rebasing'; });
    renderRebaseTable();

    try {
        const repos = selectedIdxs.map(i => ({ id: rebaseRepos[i].id, name: rebaseRepos[i].name }));
        const response = await fetch(`${CONFIG.apiBaseUrl}/RebaseRepos`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ repos })
        });
        if (!response.ok) throw new Error('Rebase API failed');
        const results = await response.json();

        results.forEach(result => {
            const i = rebaseRepos.findIndex(r => r.id === result.repoId);
            if (i >= 0) {
                rebaseRepos[i]._rebaseState = result.success ? 'done' : 'failed';
                rebaseRepos[i]._rebaseError = result.error || null;
            }
        });
        renderRebaseTable();
    } catch (error) {
        selectedIdxs.forEach(i => { rebaseRepos[i]._rebaseState = 'failed'; rebaseRepos[i]._rebaseError = error.message; });
        renderRebaseTable();
        alert('Rebase failed: ' + error.message);
    }
}

// ============================================
//  Branch Management
// ============================================
let branchRepoList = []; // loaded repos for branch mgmt

const BRANCH_PROTECTED = ['main', 'master', 'develop', 'development', 'uat', 'testing', 'production', 'release'];

// Currently-drilled-in repo + its branches
let currentRepoDetail = null;       // { id, name, defaultBranch }
let currentRepoBranches = [];        // string[]

async function loadBranchRepos() {
    const tbody = document.getElementById('branchRepoBody');
    tbody.innerHTML = '<tr><td colspan="3" class="empty-state"><span class="spinner"></span> Loading...</td></tr>';

    try {
        const repos = await loadRepos();
        branchRepoList = repos || [];

        if (branchRepoList.length === 0) {
            tbody.innerHTML = '<tr><td colspan="3" class="empty-state">No repositories found.</td></tr>';
            return;
        }

        renderBranchRepoTable(branchRepoList);
    } catch (error) {
        tbody.innerHTML = `<tr><td colspan="3" class="empty-state" style="color:#dc2626">Error: ${error.message}</td></tr>`;
    }
}

function renderBranchRepoTable(repos) {
    const tbody = document.getElementById('branchRepoBody');
    tbody.innerHTML = repos.map(repo => {
        const repoIdAttr = sanitize(repo.id);
        const repoNameAttr = sanitize(repo.name);
        const defaultBranch = sanitize(repo.defaultBranch || 'main');
        return `<tr>
            <td><strong>${sanitize(repo.name)}</strong></td>
            <td>${defaultBranch}</td>
            <td class="branch-row-actions">
                <button class="btn btn-success btn-xs" onclick="openBranchRepoDetail('${repoIdAttr}','${repoNameAttr}','${defaultBranch}','create')">
                    <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M8 2a.5.5 0 0 1 .5.5v5h5a.5.5 0 0 1 0 1h-5v5a.5.5 0 0 1-1 0v-5h-5a.5.5 0 0 1 0-1h5v-5A.5.5 0 0 1 8 2z"/></svg>
                    Create
                </button>
                <button class="btn btn-danger btn-xs" onclick="openBranchRepoDetail('${repoIdAttr}','${repoNameAttr}','${defaultBranch}','delete')">
                    <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0V6z"/><path d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1 0-2h3a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1h3a1 1 0 0 1 1 1zM4.118 4L4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4H4.118z"/></svg>
                    Delete
                </button>
            </td>
        </tr>`;
    }).join('');
}

function filterBranchRepos() {
    const search = (document.getElementById('branchRepoSearch').value || '').toLowerCase();
    const filtered = branchRepoList.filter(r => r.name.toLowerCase().includes(search));
    renderBranchRepoTable(filtered);
}

// ---- Per-Repo Branch Detail View ----
async function openBranchRepoDetail(repoId, repoName, defaultBranch, focus) {
    currentRepoDetail = { id: repoId, name: repoName, defaultBranch: defaultBranch || 'main' };

    // Swap views
    document.getElementById('branchReposView').style.display = 'none';
    document.getElementById('branchRepoDetailView').style.display = 'block';
    document.getElementById('branchDetailTitle').textContent = `Branches in ${repoName}`;
    document.getElementById('branchDetailNewName').value = '';
    document.getElementById('branchDetailFilter').value = '';

    const tbody = document.getElementById('branchDetailBody');
    tbody.innerHTML = '<tr><td colspan="2" class="empty-state"><span class="spinner"></span> Loading branches...</td></tr>';

    // Clear cache for this repo so we get fresh data
    delete branchCache[repoId];

    try {
        const branches = await loadBranches(repoId);
        currentRepoBranches = (branches || []).map(b => typeof b === 'string' ? b : (b.name || b.branchName || ''));
        currentRepoBranches = currentRepoBranches.filter(Boolean).sort();
        renderRepoBranchList(currentRepoBranches);
        populateBranchSourceDropdown(currentRepoBranches, currentRepoDetail.defaultBranch);
    } catch (e) {
        tbody.innerHTML = `<tr><td colspan="2" class="empty-state" style="color:#dc2626">Failed to load branches: ${e.message}</td></tr>`;
    }

    // Focus hint based on which button was clicked
    if (focus === 'create') {
        setTimeout(() => document.getElementById('branchDetailNewName')?.focus(), 50);
    }
}

function closeBranchRepoDetail() {
    document.getElementById('branchRepoDetailView').style.display = 'none';
    document.getElementById('branchReposView').style.display = '';
    currentRepoDetail = null;
    currentRepoBranches = [];
}

function populateBranchSourceDropdown(branches, defaultBranch) {
    const sel = document.getElementById('branchDetailSource');
    if (!sel) return;
    sel.innerHTML = branches.map(b => `<option value="${sanitize(b)}"${b === defaultBranch ? ' selected' : ''}>${sanitize(b)}</option>`).join('');
}

function renderRepoBranchList(branches) {
    const tbody = document.getElementById('branchDetailBody');
    const countEl = document.getElementById('branchDetailCount');
    if (countEl) countEl.textContent = `(${branches.length})`;

    if (branches.length === 0) {
        tbody.innerHTML = '<tr><td colspan="2" class="empty-state">No branches found.</td></tr>';
        return;
    }

    tbody.innerHTML = branches.map(name => {
        const isProtected = BRANCH_PROTECTED.includes(name.toLowerCase());
        const safeName = sanitize(name);
        const deleteBtn = isProtected
            ? `<span class="protected-tag" title="Protected branch — cannot be deleted">protected</span>`
            : `<button class="btn btn-danger btn-xs" onclick="deleteBranchFromRepo('${safeName}')">
                    <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M5.5 5.5A.5.5 0 0 1 6 6v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm2.5 0a.5.5 0 0 1 .5.5v6a.5.5 0 0 1-1 0V6a.5.5 0 0 1 .5-.5zm3 .5a.5.5 0 0 0-1 0v6a.5.5 0 0 0 1 0V6z"/><path d="M14.5 3a1 1 0 0 1-1 1H13v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V4h-.5a1 1 0 0 1 0-2h3a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1h3a1 1 0 0 1 1 1zM4.118 4L4 4.059V13a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1V4.059L11.882 4H4.118z"/></svg>
                    Delete
               </button>`;
        return `<tr>
            <td><code>${safeName}</code></td>
            <td class="branch-row-actions">${deleteBtn}</td>
        </tr>`;
    }).join('');
}

function filterRepoBranches() {
    const q = (document.getElementById('branchDetailFilter').value || '').toLowerCase();
    const filtered = q ? currentRepoBranches.filter(b => b.toLowerCase().includes(q)) : currentRepoBranches;
    renderRepoBranchList(filtered);
}

async function createBranchInRepo() {
    if (!currentRepoDetail) return;
    const branchName = document.getElementById('branchDetailNewName').value.trim();
    const sourceBranch = document.getElementById('branchDetailSource').value;

    if (!branchName) { showToast('Enter a branch name.', 'error'); return; }
    if (currentRepoBranches.includes(branchName)) {
        showToast(`Branch "${branchName}" already exists.`, 'error');
        return;
    }
    if (!confirm(`Create branch "${branchName}" from "${sourceBranch}" in ${currentRepoDetail.name}?`)) return;

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/ManageBranch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'create',
                branchName,
                sourceBranch,
                repos: [{ id: currentRepoDetail.id, name: currentRepoDetail.name }]
            })
        });
        if (!response.ok) throw new Error('Create branch failed');
        const results = await response.json();
        const r = results[0] || {};
        if (r.success) {
            showToast(`Branch "${branchName}" created in ${currentRepoDetail.name}.`, 'success');
            // Refresh branch list
            delete branchCache[currentRepoDetail.id];
            const branches = await loadBranches(currentRepoDetail.id);
            currentRepoBranches = (branches || []).map(b => typeof b === 'string' ? b : (b.name || b.branchName || '')).filter(Boolean).sort();
            renderRepoBranchList(currentRepoBranches);
            populateBranchSourceDropdown(currentRepoBranches, currentRepoDetail.defaultBranch);
            document.getElementById('branchDetailNewName').value = '';
        } else {
            showToast(`Failed: ${r.error || 'unknown error'}`, 'error');
        }
    } catch (error) {
        showToast('Error: ' + error.message, 'error');
    }
}

async function deleteBranchFromRepo(branchName) {
    if (!currentRepoDetail) return;
    if (BRANCH_PROTECTED.includes(branchName.toLowerCase())) {
        showToast('Cannot delete a protected branch.', 'error');
        return;
    }
    if (!confirm(`DELETE branch "${branchName}" from ${currentRepoDetail.name}? This cannot be undone.`)) return;

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/ManageBranch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action: 'delete',
                branchName,
                repos: [{ id: currentRepoDetail.id, name: currentRepoDetail.name }]
            })
        });
        if (!response.ok) throw new Error('Delete branch failed');
        const results = await response.json();
        const r = results[0] || {};
        if (r.success) {
            showToast(`Branch "${branchName}" deleted from ${currentRepoDetail.name}.`, 'success');
            currentRepoBranches = currentRepoBranches.filter(b => b !== branchName);
            renderRepoBranchList(currentRepoBranches);
            populateBranchSourceDropdown(currentRepoBranches, currentRepoDetail.defaultBranch);
        } else {
            showToast(`Failed: ${r.error || 'unknown error'}`, 'error');
        }
    } catch (error) {
        showToast('Error: ' + error.message, 'error');
    }
}

// ============================================
//  Task / Epic Closure
// ============================================
let closureTasks = []; // flattened list of tasks with epicId

async function loadClosureEpics() {
    const epicIdsRaw = document.getElementById('closureEpicIds').value.trim();
    // Empty input → auto-discover Epics with Custom.FactoryStatus = "70 GA Validations".
    const epicIds = epicIdsRaw
        ? epicIdsRaw.split(/[,;\s]+/).map(s => s.trim()).filter(Boolean)
        : [];

    const statusEl = document.getElementById('closureStatus');
    const tbody = document.getElementById('closureBody');
    const actionsEl = document.getElementById('closureActions');

    statusEl.textContent = epicIds.length
        ? 'Loading…'
        : 'Discovering GA Validation epics…';
    tbody.innerHTML = '<tr><td colspan="12" class="empty-state"><span class="spinner"></span> Loading tasks (BC GA area path only)…</td></tr>';
    actionsEl.style.display = 'none';

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetClosureTasks`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ epicIds })   // empty array = auto-discover on the backend
        });
        if (!response.ok) {
            // Surface the real backend error so we can debug what's failing
            let detail = `HTTP ${response.status}`;
            try {
                const errBody = await response.json();
                detail = errBody.message || errBody.error || detail;
            } catch {
                try { detail = await response.text() || detail; } catch {}
            }
            console.error('GetClosureTasks failed:', detail);
            throw new Error(detail);
        }
        closureTasks = await response.json();

        if (closureTasks.length === 0) {
            const msg = epicIds.length
                ? 'No open BC GA tasks found under the given epic(s).'
                : 'No open BC GA tasks found in any GA Validation epic.';
            tbody.innerHTML = `<tr><td colspan="12" class="empty-state">${msg}</td></tr>`;
            statusEl.textContent = '';
            return;
        }

        const distinctEpics = new Set(closureTasks.map(t => t.epicId)).size;
        statusEl.textContent = `${distinctEpics} epic${distinctEpics === 1 ? '' : 's'} · ${closureTasks.length} open BC GA task${closureTasks.length === 1 ? '' : 's'}`;
        actionsEl.style.display = openTasks > 0 ? 'flex' : 'none';

        const cell = (val) => {
            if (val === null || val === undefined || String(val).trim() === '') {
                return `<span class="ga-field-missing" title="Missing — required for closure">— missing —</span>`;
            }
            return sanitize(String(val));
        };

        const renderTags = (tags) => {
            if (!Array.isArray(tags) || tags.length === 0) {
                return `<span class="ga-tag-empty">—</span>`;
            }
            return tags
                .map(t => `<span class="ga-tag">${sanitize(t)}</span>`)
                .join(' ');
        };

        tbody.innerHTML = closureTasks.map((task, idx) => {
            return `<tr>
                <td><input type="checkbox" class="closure-check" data-idx="${idx}"></td>
                <td>${task.epicId}</td>
                <td><a href="${CONFIG.adoOrg}/${encodeURIComponent(CONFIG.adoProject)}/_workitems/edit/${task.id}" target="_blank">${task.id}</a></td>
                <td>${sanitize(task.title || '')}</td>
                <td><span class="status-badge status-${task.state?.toLowerCase().replace(/\s+/g,'-') || ''}">${sanitize(task.state || '')}</span></td>
                <td>${sanitize(task.assignedTo || '')}</td>
                <td>${cell(task.appName)}</td>
                <td>${cell(task.teamName)}</td>
                <td>${cell(task.version)}</td>
                <td>${cell(task.releaseType)}</td>
                <td>${renderTags(task.tags)}</td>
                <td>
                    <button class="btn-icon btn-edit-task" onclick="openEditTaskModal(${idx})" title="Edit task">
                        <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M12.146.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1 0 .708l-10 10a.5.5 0 0 1-.168.11l-5 2a.5.5 0 0 1-.65-.65l2-5a.5.5 0 0 1 .11-.168l10-10zM11.207 2.5 13.5 4.793 14.793 3.5 12.5 1.207 11.207 2.5zm1.586 3L10.5 3.207 4 9.707V10h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.293l6.5-6.5zm-9.761 5.175-.106.106-1.528 3.821 3.821-1.528.106-.106A.5.5 0 0 1 5 12.5V12h-.5a.5.5 0 0 1-.5-.5V11h-.5a.5.5 0 0 1-.468-.325z"/></svg>
                    </button>
                </td>
            </tr>`;
        }).join('');
    } catch (error) {
        tbody.innerHTML = `<tr><td colspan="12" class="empty-state" style="color:#f87171">Error: ${error.message}</td></tr>`;
        statusEl.textContent = '';
    }
}

// ---- Edit Task modal (single-task inline edit on the closure subtab) ----
let editingTaskIdx = -1;

function openEditTaskModal(idx) {
    const task = closureTasks[idx];
    if (!task) return;
    editingTaskIdx = idx;

    document.getElementById('editTaskTitleSuffix').textContent = `· #${task.id} · Epic ${task.epicId}`;
    document.getElementById('editTaskEpic').value         = task.epicId || '';
    document.getElementById('editTaskIdField').value      = task.id || '';
    document.getElementById('editTaskTitle').value        = task.title || '';
    document.getElementById('editTaskState').value        = task.state || 'Active';
    document.getElementById('editTaskAssignedTo').value   = task.assignedTo || '';
    document.getElementById('editTaskApp').value          = task.appName || '';
    document.getElementById('editTaskTeam').value         = task.teamName || '';
    document.getElementById('editTaskVersion').value      = task.version || '';
    document.getElementById('editTaskReleaseType').value  = task.releaseType || '';

    // Tags: comma-joined for the input. If empty AND we have suggestedTags from
    // the parent request's targetMonth, pre-fill them.
    const existingTags = Array.isArray(task.tags) ? task.tags : [];
    const suggested = Array.isArray(task.suggestedTags) ? task.suggestedTags : [];
    const tagsToShow = existingTags.length > 0 ? existingTags : suggested;
    document.getElementById('editTaskTags').value = tagsToShow.join(', ');

    const hint = document.getElementById('editTaskSuggestedTagsHint');
    if (suggested.length > 0) {
        const src = task.requestTargetMonth ? ` from request target month "${task.requestTargetMonth}"` : '';
        hint.innerHTML = `Suggested${src}: <code>${suggested.join(', ')}</code>`;
        hint.style.display = '';
    } else {
        hint.textContent = '';
        hint.style.display = 'none';
    }

    document.getElementById('editTaskValidation').style.display = 'none';
    document.getElementById('editTaskValidation').textContent = '';

    document.getElementById('editTaskModal').style.display = 'flex';
    onEditTaskStateChange();   // update visual hints based on initial state
}

function closeEditTaskModal() {
    document.getElementById('editTaskModal').style.display = 'none';
    editingTaskIdx = -1;
}

// When the user picks "Closed", warn that App/Team/Release Type/Tags are required.
function onEditTaskStateChange() {
    const state = document.getElementById('editTaskState').value;
    const validationEl = document.getElementById('editTaskValidation');
    if (state === 'Closed') {
        validationEl.style.display = '';
        validationEl.classList.add('validation-info');
        validationEl.textContent = 'Closing requires App, Team, Release Type, and Tags to be filled.';
    } else {
        validationEl.style.display = 'none';
        validationEl.classList.remove('validation-info');
    }
}

async function saveEditTask() {
    if (editingTaskIdx < 0) return;
    const task = closureTasks[editingTaskIdx];
    if (!task) return;

    const fields = {
        title:       document.getElementById('editTaskTitle').value.trim(),
        state:       document.getElementById('editTaskState').value,
        assignedTo:  document.getElementById('editTaskAssignedTo').value.trim(),
        appName:     document.getElementById('editTaskApp').value.trim(),
        teamName:    document.getElementById('editTaskTeam').value.trim(),
        version:     document.getElementById('editTaskVersion').value.trim(),
        releaseType: document.getElementById('editTaskReleaseType').value,
        tags:        document.getElementById('editTaskTags').value.split(',').map(t => t.trim()).filter(Boolean)
    };

    // Client-side gate matches the backend's gate so the user gets fast feedback
    if (fields.state === 'Closed') {
        const missing = [];
        if (!fields.appName)     missing.push('App');
        if (!fields.teamName)    missing.push('Team');
        if (!fields.releaseType) missing.push('Release Type');
        if (fields.tags.length === 0) missing.push('Tags');
        if (missing.length > 0) {
            const v = document.getElementById('editTaskValidation');
            v.classList.remove('validation-info');
            v.classList.add('validation-error-active');
            v.style.display = '';
            v.textContent = `Cannot close — missing: ${missing.join(', ')}`;
            return;
        }
    }

    const saveBtn = document.getElementById('editTaskSaveBtn');
    saveBtn.disabled = true;
    saveBtn.innerHTML = '<span class="spinner"></span> Saving…';

    try {
        const res = await fetch(`${CONFIG.apiBaseUrl}/UpdateClosureTask`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ taskId: task.id, fields })
        });
        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.message || `HTTP ${res.status}`);
        }
        showToast(`Task #${task.id} updated.`, 'success');
        closeEditTaskModal();
        loadClosureEpics();   // refresh; closed tasks will drop off the list
    } catch (e) {
        const v = document.getElementById('editTaskValidation');
        v.classList.remove('validation-info');
        v.classList.add('validation-error-active');
        v.style.display = '';
        v.textContent = e.message;
    } finally {
        saveBtn.disabled = false;
        saveBtn.textContent = 'Save';
    }
}

function toggleClosureSelectAll(checkbox) {
    document.querySelectorAll('.closure-check').forEach(cb => cb.checked = checkbox.checked);
}

async function closeSelectedTasks() {
    const selected = [];
    document.querySelectorAll('.closure-check:checked').forEach(cb => {
        const idx = parseInt(cb.dataset.idx);
        if (closureTasks[idx]) selected.push(closureTasks[idx]);
    });

    if (selected.length === 0) { alert('Select at least one task.'); return; }
    if (!confirm(`Close ${selected.length} task(s)?`)) return;

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CloseWorkItems`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ workItemIds: selected.map(t => t.id), type: 'Task' })
        });
        if (!response.ok) throw new Error('Failed to close tasks');
        const results = await response.json();

        const succeeded = results.filter(r => r.success).length;
        alert(`Closed ${succeeded}/${results.length} tasks.`);
        loadClosureEpics(); // refresh
    } catch (error) {
        alert('Error: ' + error.message);
    }
}

async function closeParentEpics() {
    // Collect unique epic IDs
    const epicIdsRaw = document.getElementById('closureEpicIds').value.trim();
    const epicIds = epicIdsRaw.split(/[,;\s]+/).map(s => s.trim()).filter(Boolean);

    if (epicIds.length === 0) { alert('No epic IDs.'); return; }

    // Check if all tasks are closed
    const openTasks = closureTasks.filter(t => t.state !== 'Closed');
    if (openTasks.length > 0) {
        if (!confirm(`There are still ${openTasks.length} open task(s). Close the parent epic(s) anyway?`)) return;
    } else {
        if (!confirm(`Close ${epicIds.length} epic(s)?`)) return;
    }

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CloseWorkItems`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ workItemIds: epicIds.map(Number), type: 'Epic' })
        });
        if (!response.ok) throw new Error('Failed to close epics');
        const results = await response.json();

        const succeeded = results.filter(r => r.success).length;
        alert(`Closed ${succeeded}/${results.length} epic(s).`);
    } catch (error) {
        alert('Error: ' + error.message);
    }
}

// ============================================
//  Live Status at AppSource
// ============================================
async function populateLiveStatusRepoDropdown() {
    const select = document.getElementById('liveStatusRepo');
    if (select.options.length > 1) return; // already populated

    try {
        const repos = await loadRepos();
        (repos || []).forEach(repo => {
            const opt = document.createElement('option');
            opt.value = repo.id;
            opt.textContent = repo.name;
            opt.dataset.name = repo.name;
            select.appendChild(opt);
        });
    } catch (e) { /* ignore */ }
}

async function checkLiveStatus() {
    const select = document.getElementById('liveStatusRepo');
    const repoId = select.value;
    const repoName = select.selectedOptions[0]?.dataset?.name || '';
    const resultsEl = document.getElementById('liveStatusResults');

    if (!repoId) { alert('Select a repository.'); return; }

    resultsEl.innerHTML = '<div class="empty-state"><span class="spinner"></span> Checking live status...</div>';

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CheckLiveStatus?repoId=${repoId}&repoName=${encodeURIComponent(repoName)}`);
        if (!response.ok) throw new Error('Failed to check live status');
        const data = await response.json();

        const versionMatch = data.appSourceVersion && data.stableTagVersion && data.appSourceVersion === data.stableTagVersion;
        const liveTagExists = !!data.liveTag;

        resultsEl.innerHTML = `
            <div class="live-status-card">
                <div class="status-row">
                    <span class="status-label">Repository</span>
                    <span class="status-value">${repoName}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">App.json Version</span>
                    <span class="status-value">${data.appJsonVersion || 'N/A'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Latest Stable Tag</span>
                    <span class="status-value">${data.stableTagVersion || 'None'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">AppSource Version</span>
                    <span class="status-value ${data.appSourceVersion ? '' : 'mismatch'}">${data.appSourceVersion || 'Not found'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Versions Match?</span>
                    <span class="status-value ${versionMatch ? 'match' : 'mismatch'}">${versionMatch ? 'Yes — Live!' : 'No'}</span>
                </div>
                <div class="status-row">
                    <span class="status-label">Live Tag</span>
                    <span class="status-value ${liveTagExists ? 'match' : ''}">${data.liveTag || 'Not created yet'}</span>
                </div>
            </div>
            ${versionMatch && !liveTagExists ? `
                <div class="live-status-actions">
                    <button class="btn btn-primary btn-sm" onclick="createLiveTag('${repoId}', '${encodeURIComponent(repoName)}', '${data.stableTagVersion}')">
                        Create live-${data.stableTagVersion} Tag
                    </button>
                    <button class="btn btn-secondary btn-sm" onclick="createLiveTagAndNotify('${repoId}', '${encodeURIComponent(repoName)}', '${data.stableTagVersion}')">
                        Create Tag &amp; Send Notification
                    </button>
                </div>
            ` : ''}
        `;
    } catch (error) {
        resultsEl.innerHTML = `<div class="empty-state" style="color:#dc2626">Error: ${error.message}</div>`;
    }
}

async function createLiveTag(repoId, repoNameEncoded, version) {
    const repoName = decodeURIComponent(repoNameEncoded);
    if (!confirm(`Create tag "live-${version}" in ${repoName}?`)) return;

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CreateLiveTag`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ repoId, repoName, version, notify: false })
        });
        if (!response.ok) throw new Error('Failed to create tag');
        alert(`Tag "live-${version}" created successfully.`);
        checkLiveStatus(); // refresh
    } catch (error) {
        alert('Error: ' + error.message);
    }
}

async function createLiveTagAndNotify(repoId, repoNameEncoded, version) {
    const repoName = decodeURIComponent(repoNameEncoded);
    if (!confirm(`Create tag "live-${version}" in ${repoName} and send Teams notification?`)) return;

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/CreateLiveTag`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ repoId, repoName, version, notify: true })
        });
        if (!response.ok) throw new Error('Failed to create tag');
        alert(`Tag "live-${version}" created and notification sent.`);
        checkLiveStatus(); // refresh
    } catch (error) {
        alert('Error: ' + error.message);
    }
}

// Find the soonest upcoming release across BOTH feature and stability types,
// based on today's date. Returns { type, releaseMonth, releaseYear, batchPrefix,
// isPastCutoff } or null.
function getNextUpcomingReleaseAcrossTypes() {
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    const candidates = [];
    for (let yearOffset = 0; yearOffset <= 1; yearOffset++) {
        const baseYear = now.getFullYear() + yearOffset;
        for (const entry of RELEASE_SCHEDULE) {
            const releaseYear = entry.releaseMonth < entry.cutoffMonth ? baseYear + 1 : baseYear;
            const releaseDate = new Date(releaseYear, entry.releaseMonth, entry.releaseDay);
            const cutoffDate  = new Date(baseYear, entry.cutoffMonth, entry.cutoffDay, 23, 59, 59);
            if (releaseDate >= today) {
                candidates.push({
                    type:         entry.type,
                    releaseMonth: entry.releaseMonth,
                    releaseYear,
                    releaseDate,
                    cutoffDate,
                    isPastCutoff: !CUTOFF_DISABLED && (now > cutoffDate),
                    batchPrefix:  entry.batchPrefix
                });
            }
        }
    }
    candidates.sort((a, b) => a.releaseDate - b.releaseDate);
    return candidates.length > 0 ? candidates[0] : null;
}

// On page load, infer Release Type + Target Month from the local calendar.
// Whichever release (feature or stability) lands soonest from today becomes
// the default. User can still change either dropdown manually.
function applyCalendarDefaults() {
    const next = getNextUpcomingReleaseAcrossTypes();
    if (!next) return;

    const rt = document.getElementById('releaseType');
    if (!rt) return;

    rt.value = next.type;
    // Existing handler will:
    //   - auto-assign + lock the matching Target Month for feature/stability
    //   - show the cutoff banner if we're past cutoff
    //   - reveal hotfix fields if needed (won't fire here since we set feature/stability)
    if (typeof onReleaseTypeChange === 'function') {
        onReleaseTypeChange();
    }

    const label = next.type === 'feature' ? 'Feature / Major' : 'Stability / Minor';
    const monthLabel = `${MONTH_NAMES[next.releaseMonth]} GA${next.releaseYear}`;
    console.info(`[calendar default] today=${(new Date()).toDateString()} → ${label} · ${monthLabel}${next.isPastCutoff ? ' (past cutoff)' : ''}`);
}

// ---- Initialize ----
document.addEventListener('DOMContentLoaded', async () => {
    // Populate target month dropdown (12 months from current)
    populateTargetMonths();

    // Pre-load repos in background
    loadRepos();

    // Fetch ADO teams for searchable dropdown
    fetchAdoTeams();

    // Load active release config — if set, show epic section immediately
    await loadActiveRelease();
    if (!activeRelease) hideEpicSection();

    // Load task parent WI config (used by GA-Initial task creation)
    loadTaskParentWi();

    // Auto-fill Release Type + Target Month from today's calendar (user can override)
    applyCalendarDefaults();

    // Apply dashboard ACL after auth initializes (small delay for MSAL)
    setTimeout(applyDashboardACL, 500);

    // Initialize file upload zone
    initUploadZone();

    initTheme();
    restoreSidebarState();
    initAppParticles();

    // Show submit view
    showView('submit');
});
