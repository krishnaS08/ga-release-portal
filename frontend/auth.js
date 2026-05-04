/* ============================================
   GA Release Portal — Azure AD Authentication
   Uses MSAL.js for Aptean corporate SSO
   ============================================ */

// MSAL Configuration — Update these values after Azure AD app registration
const msalConfig = {
    auth: {
        clientId: 'f701ecca-3db1-455c-915e-dee7da6c9d44',                     // Azure AD App Registration Client ID
        authority: 'https://login.microsoftonline.com/a61938d6-3ccf-4a84-8a39-09a5e867b0ea',  // Aptean tenant
        redirectUri: window.location.origin
    },
    cache: {
        cacheLocation: 'sessionStorage',
        storeAuthStateInCookie: false
    }
};

const loginRequest = {
    scopes: ['User.Read', 'openid', 'profile', 'email']
};

const apiRequest = {
    scopes: ['api://f701ecca-3db1-455c-915e-dee7da6c9d44/access_as_user']     // Custom API scope
};

// Try to initialize MSAL if library is loaded
let msalInstance = null;
let currentAccount = null;

function initAuth() {
    // Check if MSAL library is available
    if (typeof msal !== 'undefined') {
        msalInstance = new msal.PublicClientApplication(msalConfig);
        handleRedirect();
    } else {
        // MSAL not loaded — run in demo mode
        console.log('MSAL not loaded — running in demo mode');
        setDemoUser();
    }
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
            // Pre-fill email
            const emailInput = document.getElementById('submitterEmail');
            if (emailInput && !emailInput.value) {
                emailInput.value = currentAccount.username;
            }
        }
    } catch (error) {
        console.error('Auth redirect error:', error);
    }
}

async function signIn() {
    if (!msalInstance) {
        console.log('Auth not available in demo mode');
        return;
    }
    try {
        await msalInstance.loginRedirect(loginRequest);
    } catch (error) {
        console.error('Login failed:', error);
    }
}

async function signOut() {
    if (!msalInstance) return;
    await msalInstance.logoutRedirect();
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

    if (name) {
        const initials = name.split(' ').map(n => n[0]).join('').substring(0, 2).toUpperCase();
        avatar.textContent = initials;
        userName.textContent = name;
    }
}

function setDemoUser() {
    updateUserUI('Krishna S', 'krishna.s@aptean.com');
    const emailInput = document.getElementById('submitterEmail');
    if (emailInput) {
        emailInput.value = 'krishna.s@aptean.com';
    }
}

function getCurrentUserEmail() {
    if (currentAccount) return currentAccount.username;
    // Demo mode — return the pre-filled email or demo default
    const emailInput = document.getElementById('submitterEmail');
    if (emailInput && emailInput.value) return emailInput.value;
    return 'krishna.s@aptean.com';
}

// Auto-init when DOM is ready
document.addEventListener('DOMContentLoaded', initAuth);
