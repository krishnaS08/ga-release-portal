/* ============================================
   GA Release Portal — Application Logic
   ============================================ */

// Configuration
const CONFIG = {
    apiBaseUrl: '/api',
    adoOrg: 'https://schouw.visualstudio.com',
    adoProject: 'Foodware 365 BC',
    gaReviewers: [
        'krishna.s@aptean.com',
        'kapilkumar@aptean.com',
        'subhavarman.rs@aptean.com'
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

// ---- Dashboard Access Control ----
function isAdmin() {
    const email = (typeof getCurrentUserEmail === 'function' ? getCurrentUserEmail() : '').toLowerCase();
    return GA_ADMINS.includes(email);
}

function applyDashboardACL() {
    const dashBtn = document.querySelector('.nav-btn[data-view="dashboard"]');
    const gaBtn = document.querySelector('.nav-btn[data-view="ga-initial"]');
    if (dashBtn) {
        dashBtn.style.display = isAdmin() ? '' : 'none';
    }
    if (gaBtn) {
        gaBtn.style.display = isAdmin() ? '' : 'none';
    }
}

// ---- View Navigation ----
function showView(viewName) {
    if ((viewName === 'dashboard' || viewName === 'ga-initial') && !isAdmin()) {
        viewName = 'submit';
    }

    document.querySelectorAll('.content').forEach(el => el.style.display = 'none');
    document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));

    const view = document.getElementById(`view-${viewName}`);
    const btn = document.querySelector(`.nav-btn[data-view="${viewName}"]`);

    if (view) view.style.display = 'block';
    if (btn) btn.classList.add('active');

    if (viewName === 'dashboard') {
        loadRequests();
    }
    if (viewName === 'ga-initial') {
        loadGARequests();
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

// ---- Epic Loading from ADO ----
async function loadEpics(teamName) {
    if (!teamName) {
        cachedEpics = null;
        epicLoadingTeam = '';
        hideEpicSection();
        return;
    }

    // Don't reload if same team
    if (epicLoadingTeam === teamName && cachedEpics !== null) return;
    epicLoadingTeam = teamName;

    const section = document.getElementById('epicSection');
    const container = document.getElementById('epicBlocksContainer');
    section.style.display = '';
    container.innerHTML = '<div class="epic-loading"><span class="spinner"></span> Loading epics with GA Validation status...</div>';

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

function hideEpicSection() {
    const section = document.getElementById('epicSection');
    if (section) section.style.display = 'none';
}

let teamNameDebounce = null;
function onTeamNameChange() {
    clearTimeout(teamNameDebounce);
    const teamName = document.getElementById('teamName').value.trim();
    teamNameDebounce = setTimeout(() => loadEpics(teamName), 400);
}

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
                <div class="form-group" style="max-width: 420px;">
                    <label>Epic <span class="required">*</span></label>
                    <select class="epic-select" onchange="onEpicSelect(${epic.id}, this.value)">
                        <option value="">Select an epic...</option>
                        ${getEpicOptions(epic.epicNumber)}
                    </select>
                </div>

                <div class="apps-section">
                    <div class="apps-header">
                        <label>Apps in this Epic</label>
                        <button type="button" class="btn btn-add-app" onclick="addAppToEpic(${epic.id})" title="Add app">
                            <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a1 1 0 0 1 1 1v5h5a1 1 0 1 1 0 2H9v5a1 1 0 1 1-2 0V9H2a1 1 0 0 1 0-2h5V2a1 1 0 0 1 1-1z"/></svg>
                            Add App
                        </button>
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
    // Re-render to refresh other dropdowns (remove used epics)
    renderEpicBlocks();
}

function renderAppsForEpic(epic) {
    if (epic.apps.length === 0) {
        return '<div class="empty-app-hint">Click "Add App" to add apps for this epic.</div>';
    }

    return epic.apps.map((app, appIdx) => `
        <div class="app-row" data-app-idx="${appIdx}">
            <div class="app-row-fields">
                <div class="form-group">
                    <label>App / Repo <span class="required">*</span></label>
                    <select class="app-repo-select" onchange="onRepoChange(${epic.id}, ${appIdx}, this.value)">
                        <option value="">Select repository...</option>
                        ${getRepoOptions(app.repoId)}
                    </select>
                </div>
                <div class="form-group">
                    <label>Source Branch <span class="required">*</span></label>
                    <select class="app-branch-select" id="branch-${epic.id}-${appIdx}" onchange="onBranchChange(${epic.id}, ${appIdx}, this.value)">
                        <option value="">Select branch...</option>
                        ${getBranchOptions(app.repoId, app.branch)}
                    </select>
                </div>
            </div>
            <button type="button" class="btn-icon btn-remove-app" onclick="removeAppFromEpic(${epic.id}, ${appIdx})" title="Remove app">
                <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708z"/></svg>
            </button>
        </div>
    `).join('');
}

function getRepoOptions(selectedRepoId) {
    if (!cachedRepos) return '';
    return cachedRepos.map(repo =>
        `<option value="${sanitize(repo.id)}" ${repo.id === selectedRepoId ? 'selected' : ''}>${sanitize(repo.name)}</option>`
    ).join('');
}

function getBranchOptions(repoId, selectedBranch) {
    if (!repoId || !branchCache[repoId]) return '';
    return branchCache[repoId].map(branch =>
        `<option value="${sanitize(branch.name)}" ${branch.name === selectedBranch ? 'selected' : ''}>${sanitize(branch.name)}</option>`
    ).join('');
}

async function addAppToEpic(epicId) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic) return;
    await loadRepos();
    epic.apps.push({ repoId: '', repoName: '', branch: '' });
    renderEpicBlocks();
}

function removeAppFromEpic(epicId, appIdx) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (epic) {
        epic.apps.splice(appIdx, 1);
        renderEpicBlocks();
    }
}

async function onRepoChange(epicId, appIdx, repoId) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (!epic || !epic.apps[appIdx]) return;

    const repo = (cachedRepos || []).find(r => r.id === repoId);
    epic.apps[appIdx].repoId = repoId;
    epic.apps[appIdx].repoName = repo ? repo.name : '';
    epic.apps[appIdx].branch = '';

    if (repoId) {
        await loadBranches(repoId);
    }
    renderEpicBlocks();
}

function onBranchChange(epicId, appIdx, branchName) {
    const epic = epicBlocks.find(e => e.id === epicId);
    if (epic && epic.apps[appIdx]) {
        epic.apps[appIdx].branch = branchName;
    }
}

// ---- Form Submission ----
async function handleSubmit(event) {
    event.preventDefault();

    if (epicBlocks.length === 0) {
        showToast('Please add at least one Epic', 'error');
        return false;
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

    const payload = {
        teamName: formData.get('teamName'),
        releaseType: formData.get('releaseType'),
        submitterEmail: formData.get('submitterEmail'),
        targetMonth: formData.get('targetMonth'),
        epics: epicBlocks.map(epic => ({
            epicNumber: epic.epicNumber,
            epicTitle: epic.epicTitle,
            apps: epic.apps.map(app => ({
                repoId: app.repoId,
                repoName: app.repoName,
                sourceBranch: app.branch
            }))
        })),
        notes: formData.get('notes') || '',
        submittedAt: new Date().toISOString()
    };

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/SubmitRequest`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.message || 'Failed to submit request');
        }

        const result = await response.json();
        showSuccessModal(payload, result.requestId);
    } catch (error) {
        showToast(`Error: ${error.message}`, 'error');
    } finally {
        submitBtn.disabled = false;
        submitBtn.innerHTML = `<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M14.5 1.5l-13 5.5 5 2 2.5 5.5z"/></svg> Submit GA Request`;
    }

    return false;
}

function resetForm() {
    document.getElementById('gaRequestForm').reset();
    epicBlocks = [];
    epicIdCounter = 0;
    cachedEpics = null;
    epicLoadingTeam = '';
    hideEpicSection();
}

// ---- Dashboard ----
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
        renderRequestsTable(allRequests);
        updateStats(allRequests);
    } catch (error) {
        const sampleData = getSampleData();
        allRequests = sampleData;
        renderRequestsTable(sampleData);
        updateStats(sampleData);
    }
}

function renderRequestsTable(requests) {
    const tbody = document.getElementById('requestsBody');

    if (requests.length === 0) {
        tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No requests found matching your filters.</td></tr>';
        return;
    }

    tbody.innerHTML = requests.map(req => {
        const statusClass = `status-${req.status.replace(/\s+/g, '-')}`;
        const releaseClass = req.releaseType === 'feature' ? 'release-feature' : 'release-stability';
        const releaseLabel = req.releaseType === 'feature' ? 'Feature' : 'Stability';
        const epics = (req.epics || []).map(e => `#${sanitize(e.epicNumber)}`).join(', ');
        const totalApps = (req.epics || []).reduce((sum, e) => sum + (e.apps || []).length, 0);
        const date = new Date(req.submittedAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

        return `<tr>
            <td><strong>${sanitize(req.id || req.requestId)}</strong></td>
            <td>${sanitize(req.teamName)}</td>
            <td><span class="release-type-badge ${releaseClass}">${releaseLabel}</span></td>
            <td>${epics}</td>
            <td>${totalApps} app${totalApps !== 1 ? 's' : ''}</td>
            <td><span class="status-badge ${statusClass}">${sanitize(capitalizeFirst(req.status))}</span></td>
            <td>${date}</td>
            <td>
                <button class="btn btn-secondary btn-sm" onclick='showDetail(${JSON.stringify(req).replace(/'/g, "&#39;")})'>View</button>
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
        const appsRows = (epic.apps || []).map(app =>
            `<div class="detail-app-row">
                <span class="detail-app-repo">${sanitize(app.repoName)}</span>
                <span class="detail-app-branch"><code>${sanitize(app.sourceBranch)}</code></span>
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
            <dd><span class="release-type-badge ${request.releaseType === 'feature' ? 'release-feature' : 'release-stability'}">
                ${request.releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor'}
            </span></dd>

            <dt>Submitted By</dt>
            <dd>${sanitize(request.submitterEmail)}</dd>

            <dt>Submitted At</dt>
            <dd>${new Date(request.submittedAt).toLocaleString()}</dd>

            <dt>Status</dt>
            <dd><span class="status-badge status-${request.status}">${sanitize(capitalizeFirst(request.status))}</span></dd>

            ${request.notes ? `<dt>Notes</dt><dd>${sanitize(request.notes)}</dd>` : ''}
        </dl>

        <div class="detail-epics-section">
            <h3>Epics & Apps</h3>
            ${epicsHtml}
        </div>
    `;

    if (request.status === 'pending' && isAdmin()) {
        footer.innerHTML = `
            <button class="btn btn-reject btn-sm" onclick="handleAction('${sanitize(request.id || request.requestId)}', 'rejected')">Reject</button>
            <button class="btn btn-approve btn-sm" onclick="handleAction('${sanitize(request.id || request.requestId)}', 'approved')">
                Approve & Start GA Process
            </button>
        `;
    } else {
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeDetailModal()">Close</button>`;
    }

    document.getElementById('detailModal').style.display = 'flex';
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

// ---- Sample data for demo mode ----
function getSampleData() {
    return [
        {
            id: 'GA-20260428-001',
            teamName: 'Advanced Attributes',
            releaseType: 'feature',
            epics: [
                {
                    epicNumber: '45231', epicTitle: 'New Attribute Types for Food Safety',
                    apps: [
                        { repoName: 'FBAdvancedAttributes', sourceBranch: 'feature/new-attribute-types' },
                        { repoName: 'FBBase', sourceBranch: 'feature/base-attr-support' }
                    ]
                },
                {
                    epicNumber: '45298', epicTitle: 'Attribute Validation Engine',
                    apps: [
                        { repoName: 'FBAdvancedAttributes', sourceBranch: 'feature/attr-validation' }
                    ]
                }
            ],
            submitterEmail: 'developer@aptean.com',
            submittedAt: '2026-04-28T09:30:00Z',
            status: 'pending',
            notes: 'New attribute types for food safety compliance'
        },
        {
            id: 'GA-20260427-003',
            teamName: 'Quality Control',
            releaseType: 'stability',
            epics: [
                {
                    epicNumber: '44890', epicTitle: 'QC Inspection Improvements',
                    apps: [
                        { repoName: 'FBQualityControl', sourceBranch: 'bugfix/qc-inspection-fix' }
                    ]
                }
            ],
            submitterEmail: 'qcdev@aptean.com',
            submittedAt: '2026-04-27T14:15:00Z',
            status: 'approved',
            notes: ''
        },
        {
            id: 'GA-20260425-002',
            teamName: 'Lot Management',
            releaseType: 'feature',
            epics: [
                {
                    epicNumber: '44500', epicTitle: 'Lot Tracking v2',
                    apps: [
                        { repoName: 'FBLotManagement', sourceBranch: 'feature/lot-tracking-v2' },
                        { repoName: 'FBBase', sourceBranch: 'feature/lot-base-changes' }
                    ]
                },
                {
                    epicNumber: '44612', epicTitle: 'Lot Serialization',
                    apps: [
                        { repoName: 'FBLotManagement', sourceBranch: 'feature/lot-serialization' }
                    ]
                }
            ],
            submitterEmail: 'lotdev@aptean.com',
            submittedAt: '2026-04-25T10:00:00Z',
            status: 'in-progress'
        },
        {
            id: 'GA-20260420-001',
            teamName: 'Packaging',
            releaseType: 'stability',
            epics: [
                {
                    epicNumber: '43900', epicTitle: 'Label Printing Fixes',
                    apps: [
                        { repoName: 'FBPackaging', sourceBranch: 'bugfix/label-print-fix' }
                    ]
                }
            ],
            submitterEmail: 'packdev@aptean.com',
            submittedAt: '2026-04-20T16:30:00Z',
            status: 'completed'
        }
    ];
}

// ---- GA-Initial Tab ----
let gaRequests = [];
let gaPreviewData = null;   // cached preview response

async function loadGARequests() {
    const statusFilter = document.getElementById('gaFilterStatus')?.value || 'in-progress';
    const params = new URLSearchParams({ status: statusFilter });

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/GetRequests?${params.toString()}`);
        if (!response.ok) throw new Error('Failed to load requests');
        gaRequests = await response.json();
    } catch (error) {
        gaRequests = [];
    }

    renderGARequestsTable(gaRequests);
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
        const releaseClass = req.releaseType === 'feature' ? 'release-feature' : 'release-stability';
        const releaseLabel = req.releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor';
        const epics = (req.epics || []).map(e => `#${sanitize(e.epicNumber)}`).join(', ');
        const totalApps = (req.epics || []).reduce((sum, e) => sum + (e.apps || []).length, 0);
        const date = new Date(req.submittedAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
        const reqId = sanitize(req.id || req.requestId);

        return `<tr>
            <td><strong>${reqId}</strong></td>
            <td>${sanitize(req.teamName)}</td>
            <td><span class="release-type-badge ${releaseClass}">${releaseLabel}</span></td>
            <td>${epics}</td>
            <td>${totalApps} app${totalApps !== 1 ? 's' : ''}</td>
            <td><span class="status-badge ${statusClass}">${sanitize(capitalizeFirst(req.status))}</span></td>
            <td>${date}</td>
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
        renderGAPreview(gaPreviewData, false);
    } catch (error) {
        body.innerHTML = `<div class="ga-error-state">Failed to load preview: ${sanitize(error.message)}</div>`;
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>`;
    }
}

function renderGAPreview(data, editMode) {
    const body = document.getElementById('gaProcessModalBody');
    const footer = document.getElementById('gaProcessModalFooter');

    const releaseLabel = data.releaseType === 'feature' ? 'Feature / Major' : 'Stability / Minor';
    const canApprove = (data.status === 'in-progress' || data.status === 'approved') && isAdmin();

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
        // Task summary
        const taskCount = (epic.existingTasks || []).length;
        const taskSummary = taskCount > 0
            ? `<span class="ga-task-count">${taskCount} task${taskCount !== 1 ? 's' : ''}</span>`
            : '<span class="ga-task-count none">No tasks yet</span>';

        html += `<div class="ga-epic-card">
            <div class="ga-epic-card-header">
                <span>Epic #${sanitize(epic.epicId)}${epic.epicTitle ? ' — ' + sanitize(epic.epicTitle) : ''}</span>
                ${taskSummary}
            </div>`;

        // Show existing tasks if any
        if (taskCount > 0) {
            html += `<div class="ga-tasks-strip">`;
            epic.existingTasks.forEach(t => {
                const stateClass = (t.state || '').toLowerCase().replace(/\s+/g, '-');
                html += `<span class="ga-task-chip ${stateClass}" title="${sanitize(t.title)}">
                    <strong>#${t.id}</strong> ${sanitize(t.title.length > 40 ? t.title.substring(0, 40) + '...' : t.title)}
                </span>`;
            });
            html += `</div>`;
        }

        // App preview table
        html += `<table class="ga-app-table">
            <thead><tr>
                <th>Repository</th>
                <th>Source Branch</th>
                <th>App Name</th>
                <th>Current Version</th>
                <th>New Version</th>
                <th>AppSourceCop</th>
                <th>Target Branch</th>
                <th>Task</th>
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

            // Task status badge
            let taskBadge;
            if (app.task) {
                taskBadge = `<span class="ga-task-badge created">#${app.task.id}</span>`;
            } else {
                taskBadge = `<span class="ga-task-badge pending">Auto-create</span>`;
            }

            // Version display — editable in edit mode
            let newVersionHtml;
            if (editMode && !hasError) {
                newVersionHtml = `<input type="text" class="ga-version-input" data-epic="${epicIdx}" data-app="${appIdx}" value="${sanitize(app.newVersion || '')}" onchange="onGAVersionChange(${epicIdx}, ${appIdx}, this.value)">`;
            } else {
                newVersionHtml = hasError ? '—' : `<strong class="ga-version-new">${sanitize(app.newVersion)}</strong>`;
            }

            html += `<tr class="${rowClass}">
                <td>${sanitize(app.repoName)}</td>
                <td><code>${sanitize(app.sourceBranch)}</code></td>
                <td>${hasError ? `<span class="ga-error-text">${sanitize(app.error)}</span>` : sanitize(app.appShortName || app.appName || '—')}</td>
                <td>${hasError ? '—' : sanitize(app.currentVersion)}</td>
                <td>${newVersionHtml}</td>
                <td>${app.appSourceCopVersion ? sanitize(app.appSourceCopVersion) : '<em>N/A</em>'}</td>
                <td>${targetBranchHtml}</td>
                <td>${taskBadge}</td>
            </tr>`;
        });

        html += `</tbody></table></div>`;
    });

    // PR preview section
    html += `<div class="ga-pr-preview">
        <h3>PR Preview</h3>
        <div class="ga-pr-preview-content">`;

    (data.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (app.error) return;
            const targetBr = app._targetBranch || 'main';
            const commitMsg = `v${app.newVersion} ${data.releaseLabel} Release from BC GA team`;
            html += `<div class="ga-pr-item">
                <span class="ga-pr-repo">${sanitize(app.repoName)}</span>
                <span class="ga-pr-arrow">→</span>
                <span class="ga-pr-branch">${sanitize(app.sourceBranch)}</span>
                <span class="ga-pr-arrow">→</span>
                <span class="ga-pr-branch">${sanitize(targetBr)}</span>
                <span class="ga-pr-commit">${sanitize(commitMsg)}</span>
            </div>`;
        });
    });

    html += `</div>
        <div class="ga-pr-reviewers">
            <strong>Reviewers:</strong> kapilkumar@aptean.com, subhavarman.rs@aptean.com
        </div>
    </div>`;

    body.innerHTML = html;

    // Footer buttons
    if (canApprove) {
        if (editMode) {
            footer.innerHTML = `
                <button class="btn btn-secondary btn-sm" onclick="renderGAPreview(gaPreviewData, false)">Cancel Edit</button>
                <button class="btn btn-primary btn-sm" onclick="renderGAPreview(gaPreviewData, false)">Save Changes</button>
                <button class="btn-initiate" onclick="approveAndProcess('${sanitize(data.requestId)}')">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>
                    Approve &amp; Create PR
                </button>
            `;
        } else {
            footer.innerHTML = `
                <button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>
                <button class="btn btn-edit btn-sm" onclick="renderGAPreview(gaPreviewData, true)">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M12.146.854a.5.5 0 0 1 .708 0l2.292 2.292a.5.5 0 0 1 0 .708l-9.5 9.5a.5.5 0 0 1-.168.11l-4 1.5a.5.5 0 0 1-.65-.65l1.5-4a.5.5 0 0 1 .11-.168l9.5-9.5zM11.207 2.5L13.5 4.793 14.793 3.5 12.5 1.207 11.207 2.5zm1.586 3L10.5 3.207 3 10.707V11h.5a.5.5 0 0 1 .5.5v.5h.5a.5.5 0 0 1 .5.5v.5h.293l7.5-7.5z"/></svg>
                    Edit
                </button>
                <button class="btn-initiate" onclick="approveAndProcess('${sanitize(data.requestId)}')">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.75.75 0 0 1 1.06-1.06L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0z"/></svg>
                    Approve &amp; Create PR
                </button>
            `;
        }
    } else {
        footer.innerHTML = `<button class="btn btn-secondary btn-sm" onclick="closeGAProcessModal()">Close</button>`;
    }
}

function onGATargetChange(epicIdx, appIdx, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        gaPreviewData.epics[epicIdx].apps[appIdx]._targetBranch = value;
    }
}

function onGAVersionChange(epicIdx, appIdx, value) {
    if (gaPreviewData && gaPreviewData.epics[epicIdx] && gaPreviewData.epics[epicIdx].apps[appIdx]) {
        gaPreviewData.epics[epicIdx].apps[appIdx].newVersion = value;
    }
}

function closeGAProcessModal() {
    document.getElementById('gaProcessModal').style.display = 'none';
    gaPreviewData = null;
}

async function approveAndProcess(requestId) {
    if (!gaPreviewData) return;

    // Collect per-app overrides (custom versions, target branches)
    const appOverrides = [];
    (gaPreviewData.epics || []).forEach(epic => {
        (epic.apps || []).forEach(app => {
            if (!app.error) {
                appOverrides.push({
                    repoId:       app.repoId,
                    repoName:     app.repoName,
                    sourceBranch: app.sourceBranch,
                    targetBranch: app._targetBranch || 'main',
                    newVersion:   app.newVersion,
                    epicId:       epic.epicId
                });
            }
        });
    });

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
    addLog(`Reviewers: kapilkumar@aptean.com, subhavarman.rs@aptean.com`, 'info');
    addLog('');

    try {
        const response = await fetch(`${CONFIG.apiBaseUrl}/InitiateGA`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, appOverrides })
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

// ---- Initialize ----
document.addEventListener('DOMContentLoaded', async () => {
    // Set default target month
    const now = new Date();
    const monthStr = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    document.getElementById('targetMonth').value = monthStr;

    // Pre-load repos in background
    loadRepos();

    // Hide epic section until team name is entered
    hideEpicSection();

    // Apply dashboard ACL after auth initializes (small delay for MSAL)
    setTimeout(applyDashboardACL, 500);

    // Show submit view
    showView('submit');
});
