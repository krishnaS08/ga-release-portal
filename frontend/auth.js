/* ============================================
   GA Release Portal — Azure AD Authentication
   Uses MSAL.js for Aptean corporate SSO
   ============================================ */

// ============================================================
// TEMPORARY DEV BYPASS — set to false to re-enable real SSO
// once admin consent is granted for User.Read.All
// =============================================================
const AUTH_DISABLED = false;
const DEV_USER = { name: 'Krishna S', email: 'krishna.s@aptean.com' };

// MSAL Configuration — Update these values after Azure AD app registration
const msalConfig = {
    auth: {
        clientId: 'f701ecca-3db1-455c-915e-dee7da6c9d44',                     // Azure AD App Registration Client ID
        authority: 'https://login.microsoftonline.com/560ec2b0-df0c-4e8c-9848-a15718863bb6',  // Aptean tenant
        redirectUri: window.location.origin
    },
    cache: {
        cacheLocation: 'sessionStorage',
        storeAuthStateInCookie: false
    }
};

const loginRequest = {
    // User.Read.All requires admin consent (already granted by Aptean) — included
    // here so the token issued at sign-in already covers Microsoft Graph user
    // search; subsequent searches hit the MSAL silent-token cache without prompts.
    scopes: ['User.Read', 'User.Read.All', 'openid', 'profile', 'email']
};

const apiRequest = {
    scopes: ['api://f701ecca-3db1-455c-915e-dee7da6c9d44/access_as_user']     // Custom API scope
};

const graphUserSearchRequest = {
    scopes: ['User.Read.All']
};

let msalInstance = null;
let currentAccount = null;

async function initAuth() {
    if (AUTH_DISABLED) {
        currentAccount = { name: DEV_USER.name, username: DEV_USER.email };
        updateUserUI(DEV_USER.name, DEV_USER.email);
        const emailInput = document.getElementById('submitterEmail');
        if (emailInput) emailInput.value = DEV_USER.email;
        showApp();
        console.warn('[auth] AUTH_DISABLED is true — running without SSO. Flip the flag in auth.js to re-enable.');
        return;
    }

    if (typeof msal === 'undefined') {
        // MSAL library failed to load — block access, show error on login page
        showLoginPage();
        const hint = document.getElementById('loginHint');
        if (hint) {
            hint.textContent = 'Authentication library failed to load. Check your network connection and reload the page.';
            hint.style.color = '#d13438';
        }
        const btn = document.getElementById('loginBtn');
        if (btn) btn.disabled = true;
        return;
    }

    msalInstance = new msal.PublicClientApplication(msalConfig);
    // MSAL v3+ requires explicit initialize(); v2 doesn't expose it — optional chain handles both.
    if (typeof msalInstance.initialize === 'function') {
        await msalInstance.initialize();
    }
    await handleRedirect();
}

async function handleRedirect() {
    try {
        const response = await msalInstance.handleRedirectPromise();
        if (response) {
            currentAccount = response.account;
        } else {
            const accounts = msalInstance.getAllAccounts();
            if (accounts.length > 0) {
                currentAccount = accounts[0];
            }
        }

        if (currentAccount) {
            updateUserUI(currentAccount.name, currentAccount.username);
            // Set SSO email (readonly field)
            const emailInput = document.getElementById('submitterEmail');
            if (emailInput) {
                emailInput.value = currentAccount.username;
            }
            showApp();
        } else {
            // No account — show login page
            showLoginPage();
        }
    } catch (error) {
        console.error('Auth redirect error:', error);
        showLoginPage();
    }
}

async function signIn() {
    if (!msalInstance) return;
    try {
        await msalInstance.loginRedirect(loginRequest);
    } catch (error) {
        console.error('Login failed:', error);
    }
}

async function signOut() {
    if (!msalInstance) return;
    await msalInstance.logoutRedirect({
        postLogoutRedirectUri: window.location.origin
    });
}

function confirmSignOut() {
    if (AUTH_DISABLED) return; // sign-out is a no-op while auth is bypassed
    if (!currentAccount) return;
    if (confirm(`Sign out of ${currentAccount.username}?`)) {
        signOut();
    }
}

async function getAccessToken() {
    if (!msalInstance || !currentAccount) return null;

    try {
        const response = await msalInstance.acquireTokenSilent({
            ...apiRequest,
            account: currentAccount
        });
        return response.accessToken;
    } catch (error) {
        // Fall back to interactive
        try {
            const response = await msalInstance.acquireTokenPopup(apiRequest);
            return response.accessToken;
        } catch (popupError) {
            console.error('Token acquisition failed:', popupError);
            return null;
        }
    }
}

function updateUserUI(name, email) {
    const avatar = document.getElementById('userAvatar');
    const userName = document.getElementById('userName');
    const menuName = document.getElementById('userMenuName');
    const menuEmail = document.getElementById('userMenuEmail');

    if (name) {
        const initials = name.split(' ').map(n => n[0]).join('').substring(0, 2).toUpperCase();
        avatar.textContent = initials;
        userName.textContent = name;
        if (menuName) menuName.textContent = name;
    }
    if (menuEmail && email) menuEmail.textContent = email;
}

function toggleUserMenu(event) {
    if (event) event.stopPropagation();
    const dropdown = document.getElementById('userMenuDropdown');
    if (!dropdown) return;
    dropdown.classList.toggle('open');
}

function closeUserMenu() {
    document.getElementById('userMenuDropdown')?.classList.remove('open');
}

// Close on outside click
document.addEventListener('click', (e) => {
    const menu = document.getElementById('userMenu');
    if (menu && !menu.contains(e.target)) closeUserMenu();
});

// Close on Escape
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeUserMenu();
});

function showApp() {
    const loginPage = document.getElementById('loginPage');
    const app = document.getElementById('app');
    if (loginPage) loginPage.style.display = 'none';
    if (app) app.style.display = '';
}

function showLoginPage() {
    const loginPage = document.getElementById('loginPage');
    const app = document.getElementById('app');
    if (loginPage) loginPage.style.display = '';
    if (app) app.style.display = 'none';
}

function getCurrentUserEmail() {
    if (currentAccount) return currentAccount.username;
    return '';
}

/**
 * Search Aptean people via Microsoft Graph (delegated User.Read.All).
 * Returns array of { name, email }.
 * Returns null when Graph isn't reachable (e.g. AUTH_DISABLED, MSAL not signed
 * in, network/CSP blocks) so the caller can fall back to a local list.
 *
 * Note: in delegated mode Graph already scopes results to the signed-in user's
 * tenant, so we don't need to post-filter by domain — that just hid users
 * whose UPN ends in @aptean.onmicrosoft.com instead of @aptean.com.
 */
async function searchApteanPeople(query) {
    if (!query || query.length < 2) return [];

    if (!msalInstance) {
        console.warn('[graph] msalInstance is null — MSAL never initialized (AUTH_DISABLED?). Caller falls back.');
        return null;
    }
    if (!currentAccount) {
        console.warn('[graph] currentAccount is null — user is not signed in. Caller falls back.');
        return null;
    }

    // 1) Acquire a Graph token (silent if possible)
    let token = null;
    try {
        const r = await msalInstance.acquireTokenSilent({
            ...graphUserSearchRequest,
            account: currentAccount
        });
        token = r.accessToken;
        console.info('[graph] silent token acquired for User.Read.All ✓');
    } catch (e) {
        console.warn('[graph] silent token failed (will try popup):', e.errorCode || e.message);
        try {
            const r = await msalInstance.acquireTokenPopup(graphUserSearchRequest);
            token = r.accessToken;
            console.info('[graph] popup token acquired');
        } catch (popupErr) {
            console.error('[graph] token acquisition failed:', popupErr);
            return null;
        }
    }

    // 2) Call our own backend, forwarding the Graph token. The Function then
    //    relays to Microsoft Graph server-side. This dodges browser CSP/CORS
    //    and corporate-firewall interception of graph.microsoft.com.
    let res;
    try {
        res = await fetch('/api/SearchUsers?q=' + encodeURIComponent(query), {
            headers: {
                'Authorization': `Bearer ${token}`
            }
        });
    } catch (netErr) {
        console.error('[graph] /api/SearchUsers network error:', netErr);
        throw new Error('Network error reaching backend');
    }

    if (!res.ok) {
        let detail = '';
        try { detail = await res.text(); } catch {}
        console.error(`[graph] /api/SearchUsers HTTP ${res.status} ${res.statusText}\n${detail}`);
        let parsedMsg = `SearchUsers ${res.status}`;
        try {
            const j = JSON.parse(detail);
            if (j.error || j.message) parsedMsg = `${res.status}: ${j.error || j.message}`;
        } catch {}
        throw new Error(parsedMsg);
    }

    const arr = await res.json().catch(() => []);
    const results = (Array.isArray(arr) ? arr : [])
        .map(u => ({
            name: u.name || u.displayName || '',
            email: (u.email || u.mail || '').toLowerCase()
        }))
        .filter(u => u.email);
    console.info(`[graph] /api/SearchUsers ("${query}") → ${results.length} result(s)`);
    return results;
}

// Auto-init when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    initAuth();
    initLoginParticles();
});

function initLoginParticles() {
    const canvas = document.getElementById('loginParticleCanvas');
    if (!canvas) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    const ctx = canvas.getContext('2d');
    const COLORS = ['#6366f1', '#8b5cf6', '#06b6d4', '#3b82f6', '#a855f7', '#ec4899'];
    const COUNT  = 55;
    const CONNECT = 150;
    let W, H, particles;

    function resize() {
        W = canvas.width  = window.innerWidth;
        H = canvas.height = window.innerHeight;
    }

    function make() {
        particles = Array.from({ length: COUNT }, () => ({
            x:  Math.random() * W,
            y:  Math.random() * H,
            vx: (Math.random() - 0.5) * 0.28,
            vy: (Math.random() - 0.5) * 0.28,
            r:  Math.random() * 1.6 + 1.0,
            a:  Math.random() * 0.55 + 0.25,
            c:  COLORS[Math.floor(Math.random() * COLORS.length)]
        }));
    }

    function frame() {
        ctx.clearRect(0, 0, W, H);
        for (let i = 0; i < COUNT; i++) {
            for (let j = i + 1; j < COUNT; j++) {
                const dx = particles[i].x - particles[j].x;
                const dy = particles[i].y - particles[j].y;
                const d2 = dx * dx + dy * dy;
                if (d2 < CONNECT * CONNECT) {
                    const a = (1 - Math.sqrt(d2) / CONNECT) * 0.28;
                    ctx.strokeStyle = `rgba(99,102,241,${a})`;
                    ctx.lineWidth = 0.75;
                    ctx.beginPath();
                    ctx.moveTo(particles[i].x, particles[i].y);
                    ctx.lineTo(particles[j].x, particles[j].y);
                    ctx.stroke();
                }
            }
        }
        for (const p of particles) {
            ctx.save();
            ctx.shadowBlur  = 12;
            ctx.shadowColor = p.c;
            ctx.globalAlpha = p.a;
            ctx.fillStyle   = p.c;
            ctx.beginPath();
            ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
            ctx.fill();
            ctx.restore();
            p.x += p.vx; p.y += p.vy;
            if (p.x < 0 || p.x > W) p.vx *= -1;
            if (p.y < 0 || p.y > H) p.vy *= -1;
        }
        requestAnimationFrame(frame);
    }

    resize();
    make();
    frame();
    window.addEventListener('resize', () => { resize(); make(); });
}
