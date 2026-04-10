// ===== DARBITEX CONFIG =====
const PACKAGE = '0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e';
const RPC = 'https://fullnode.mainnet.aptoslabs.com/v1';
const SLIPPAGE = 0.005;
const GOOGLE_CLIENT_ID = '729568688759-4tpttmq42rhr0ibc1sfbnssjc9tucbfl.apps.googleusercontent.com';

const TOKENS = {
  APT:  { meta: '0x000000000000000000000000000000000000000000000000000000000000000a', decimals: 8, symbol: 'APT' },
  USDC: { meta: '0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b', decimals: 6, symbol: 'USDC' },
  USDT: { meta: '0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b', decimals: 6, symbol: 'USDT' },
};

let wallet = null;
let pools = [];

// ===== APTOS SDK (Keyless) =====
let aptosSDK = null;
let aptosClient = null;
let keylessAccount = null;
let EphemeralKeyPair = null;

async function loadSDK() {
  try {
    const sdk = await import('https://esm.sh/@aptos-labs/ts-sdk@1.33.1');
    aptosSDK = sdk;
    EphemeralKeyPair = sdk.EphemeralKeyPair;
    const config = new sdk.AptosConfig({ fullnode: RPC, network: sdk.Network.MAINNET });
    aptosClient = new sdk.Aptos(config);
    // Try restore session
    await restoreKeylessSession();
  } catch(e) { console.warn('SDK load failed:', e); }
}

// ===== WALLET — AIP-62 Aptos Wallet Standard =====
// Discovery IIFE lives inline in <head> of index.html so it runs before
// any extension content_script dispatches 'register-wallet'. It populates
// window.__APTOS_WALLETS__ (Map keyed by wallet name).
const APTOS_WALLETS = (window.__APTOS_WALLETS__ = window.__APTOS_WALLETS__ || new Map());

function listWallets() { return Array.from(APTOS_WALLETS.values()); }

function pickWallet(preferName) {
  if (preferName && APTOS_WALLETS.has(preferName)) return APTOS_WALLETS.get(preferName);
  const petra = APTOS_WALLETS.get('Petra');
  if (petra) return petra;
  const first = listWallets()[0];
  return first || null;
}

async function waitForWallet(timeoutMs = 1500) {
  if (listWallets().length > 0) return pickWallet();
  // Re-dispatch app-ready once in case a wallet injected between head
  // script and now — defensive, doesn't hurt if no one is listening.
  try {
    const api = { register: (w) => { if (w?.name) APTOS_WALLETS.set(w.name, w); } };
    window.dispatchEvent(new CustomEvent('aptos:app-ready', { detail: api }));
    window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: api }));
  } catch {}
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    await new Promise(r => setTimeout(r, 50));
    if (listWallets().length > 0) return pickWallet();
  }
  return null;
}

function getFeature(wallet, name) {
  const feats = wallet.features || {};
  const f = feats[name];
  if (!f) return null;
  // Features expose their action under a key matching the last segment.
  // e.g. 'aptos:connect' -> { version, connect }
  const key = name.split(':').pop();
  return typeof f[key] === 'function' ? f[key].bind(f) : null;
}

function extractAddress(resp) {
  // AIP-62: connect returns UserResponse<AccountInfo>
  // { status: 'Approved', args: { address, publicKey, ... } } OR AccountInfo directly
  const info = resp?.args || resp?.account || resp;
  const addr = info?.address;
  if (!addr) return null;
  if (typeof addr === 'string') return addr;
  if (typeof addr.toString === 'function') return addr.toString();
  return null;
}

async function connectExtension() {
  const w = await waitForWallet();
  if (!w) {
    toast('No Aptos wallet detected — install Petra: petra.app', true);
    return false;
  }
  try {
    const connect = getFeature(w, 'aptos:connect');
    if (!connect) throw new Error(`${w.name} missing aptos:connect feature`);
    const resp = await connect();
    if (resp && resp.status && resp.status !== 'Approved') {
      throw new Error('Connect rejected');
    }
    const address = extractAddress(resp);
    if (!address) throw new Error('No address returned from wallet');
    wallet = address;
    window._walletProvider = w;
    window._walletName = w.name;
    window._walletType = 'extension';
    updateWalletUI();
    toast('Connected: ' + w.name);
    return true;
  } catch(e) {
    console.error('Connect failed:', e);
    toast(e.message || 'Rejected', true);
    return false;
  }
}

// ===== GOOGLE KEYLESS LOGIN =====
async function googleSignIn() {
  if (!EphemeralKeyPair) { toast('Loading SDK...', true); return; }
  const ekp = EphemeralKeyPair.generate();
  localStorage.setItem('darbitex_ekp', ekp.toString());

  const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  url.searchParams.set('client_id', GOOGLE_CLIENT_ID);
  url.searchParams.set('redirect_uri', window.location.origin + window.location.pathname);
  url.searchParams.set('response_type', 'id_token');
  url.searchParams.set('scope', 'openid email profile');
  url.searchParams.set('nonce', ekp.nonce);
  url.searchParams.set('prompt', 'select_account');
  window.location.href = url.toString();
}

async function handleKeylessCallback() {
  const hash = window.location.hash;
  if (!hash.includes('id_token')) return false;
  if (!aptosClient || !EphemeralKeyPair) return false;

  const params = new URLSearchParams(hash.substring(1));
  const jwt = params.get('id_token');
  if (!jwt) return false;

  const ekpStr = localStorage.getItem('darbitex_ekp');
  if (!ekpStr) return false;

  try {
    const ekp = EphemeralKeyPair.fromString(ekpStr);
    keylessAccount = await aptosClient.deriveKeylessAccount({ jwt, ephemeralKeyPair: ekp });
    localStorage.setItem('darbitex_jwt', jwt);
    wallet = keylessAccount.accountAddress.toString();
    window._walletType = 'keyless';
    updateWalletUI();
    window.history.replaceState(null, '', window.location.pathname);
    toast('Google login successful');
    return true;
  } catch(e) {
    console.error('Keyless failed:', e);
    toast('Google login failed', true);
    return false;
  }
}

async function restoreKeylessSession() {
  const jwt = localStorage.getItem('darbitex_jwt');
  const ekpStr = localStorage.getItem('darbitex_ekp');
  if (!jwt || !ekpStr || !aptosClient || !EphemeralKeyPair) return;

  try {
    const ekp = EphemeralKeyPair.fromString(ekpStr);
    if (ekp.isExpired()) { clearKeylessSession(); return; }
    keylessAccount = await aptosClient.deriveKeylessAccount({ jwt, ephemeralKeyPair: ekp });
    wallet = keylessAccount.accountAddress.toString();
    window._walletType = 'keyless';
    updateWalletUI();
  } catch { clearKeylessSession(); }
}

function clearKeylessSession() {
  localStorage.removeItem('darbitex_ekp');
  localStorage.removeItem('darbitex_jwt');
  keylessAccount = null;
}

// ===== CONNECT UI =====
function updateWalletUI() {
  const btn = document.getElementById('walletBtn');
  const gBtn = document.getElementById('googleBtn');
  if (!btn) return;
  if (wallet) {
    btn.textContent = wallet.slice(0,6) + '...' + wallet.slice(-4);
    btn.classList.add('connected');
    if (gBtn) gBtn.style.display = 'none';
  } else {
    btn.textContent = 'Connect';
    btn.classList.remove('connected');
    if (gBtn) gBtn.style.display = '';
  }
}

async function connectWallet() {
  if (wallet) { await disconnectWallet(); return; }
  await connectExtension();
}

async function disconnectWallet() {
  const w = window._walletProvider;
  if (w) {
    try {
      const fn = getFeature(w, 'aptos:disconnect');
      if (fn) await fn();
    } catch (e) { console.warn('disconnect feature failed:', e); }
  }
  wallet = null; keylessAccount = null;
  window._walletProvider = null; window._walletName = null; window._walletType = null;
  clearKeylessSession();
  updateWalletUI();
}

// ===== RPC =====
async function viewFn(fn, typeArgs, args) {
  const body = { function: `${PACKAGE}::${fn}`, type_arguments: typeArgs || [], arguments: args || [] };
  const res = await fetch(`${RPC}/view`, { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(body) });
  return await res.json();
}

function toRaw(amount, dec) { return Math.floor(amount * (10 ** dec)); }
function fromRaw(raw, dec) { return Number(raw) / (10 ** dec); }

// Cache for tokens not in the static TOKENS config, keyed by normalized meta.
// Populated lazily via FA metadata view — avoids hardcoding decimals for
// arbitrary FA tokens encountered in on-chain pools.
const TOKEN_CACHE = {};

function normMeta(m) { return m.replace(/^0x0+/, '0x').toLowerCase(); }

async function getTokenInfo(meta) {
  const key = normMeta(meta);
  // Static config first (APT/USDC/USDT)
  for (const [, t] of Object.entries(TOKENS)) {
    if (normMeta(t.meta) === key) return t;
  }
  // Cached?
  if (TOKEN_CACHE[key]) return TOKEN_CACHE[key];
  // Fetch FA metadata from chain
  try {
    const res = await fetch(`${RPC}/accounts/${meta}/resource/0x1::fungible_asset::Metadata`);
    if (!res.ok) throw new Error('FA metadata 404');
    const d = await res.json();
    const info = {
      meta,
      symbol: d.data.symbol || meta.slice(0, 6) + '...',
      decimals: parseInt(d.data.decimals) || 0,
    };
    TOKEN_CACHE[key] = info;
    return info;
  } catch {
    // Last-resort fallback: mark decimals=0 so raw value displays as integer
    const info = { meta, symbol: meta.slice(0, 6) + '...', decimals: 0 };
    TOKEN_CACHE[key] = info;
    return info;
  }
}

// ===== POOLS =====
async function loadPools() {
  try {
    const res = await viewFn('pool_factory::get_all_pools', [], []);
    const addrs = res[0] || res;
    pools = [];
    for (const addr of addrs) {
      try {
        const [info, tokens, hook] = await Promise.all([
          viewFn('pool::pool_info', [], [addr]),
          viewFn('pool::pool_tokens', [], [addr]),
          viewFn('pool::pool_hook', [], [addr]),
        ]);
        const metaA = tokens[0]?.inner || tokens[0];
        const metaB = tokens[1]?.inner || tokens[1];
        const [tokenA, tokenB] = await Promise.all([
          getTokenInfo(metaA),
          getTokenInfo(metaB),
        ]);
        pools.push({
          addr, reserve_a: info[0], reserve_b: info[1],
          lp_supply: info[2], paused: info[3],
          meta_a: metaA, meta_b: metaB,
          token_a: tokenA, token_b: tokenB,
          hooked: hook[0]?.vec?.length > 0,
        });
      } catch(e) { console.error('Pool error:', addr, e); }
    }
  } catch(e) { console.error('loadPools error:', e); }
  return pools;
}

function findPool(metaIn, metaOut) {
  const c = m => m.replace(/^0x0+/, '0x').toLowerCase();
  return pools.find(p =>
    (c(p.meta_a) === c(metaIn) && c(p.meta_b) === c(metaOut)) ||
    (c(p.meta_a) === c(metaOut) && c(p.meta_b) === c(metaIn))
  );
}

// ===== TX =====
async function submitTx(module, fn, args) {
  if (!wallet) { toast('Connect wallet first', true); return null; }

  const fnId = `${PACKAGE}::${module}::${fn}`;

  // Keyless account — use SDK
  if (window._walletType === 'keyless' && keylessAccount && aptosClient) {
    try {
      const tx = await aptosClient.transaction.build.simple({
        sender: keylessAccount.accountAddress,
        data: { function: fnId, typeArguments: [], functionArguments: args },
      });
      const signed = await aptosClient.transaction.sign({ signer: keylessAccount, transaction: tx });
      const result = await aptosClient.transaction.submit.simple(signed);
      toast('TX: ' + result.hash.slice(0,12) + '...');
      return result;
    } catch(e) { toast(e.message || 'TX failed', true); return null; }
  }

  // Extension wallet via AIP-62 Wallet Standard
  const w = window._walletProvider;
  if (!w) { toast('Wallet disconnected', true); return null; }

  // AIP-62 signAndSubmitTransaction expects a transaction input payload,
  // not a built RawTransaction. Petra accepts the SimpleTransactionInput shape.
  const txInput = {
    payload: {
      function: fnId,
      typeArguments: [],
      functionArguments: args,
    },
  };

  try {
    const signSubmit = getFeature(w, 'aptos:signAndSubmitTransaction');
    if (signSubmit) {
      const resp = await signSubmit(txInput);
      if (resp?.status && resp.status !== 'Approved') throw new Error('Rejected');
      const hash = resp?.args?.hash || resp?.hash;
      toast('TX: ' + String(hash).slice(0,12) + '...');
      return resp;
    }
    // Fallback: build + sign + submit via SDK
    if (!aptosClient) throw new Error('SDK not loaded yet');
    const built = await aptosClient.transaction.build.simple({
      sender: wallet,
      data: { function: fnId, typeArguments: [], functionArguments: args },
    });
    const signFn = getFeature(w, 'aptos:signTransaction');
    if (!signFn) throw new Error(`${w.name} missing sign feature`);
    const signResp = await signFn({ transaction: built });
    const senderAuth = signResp?.args?.authenticator || signResp?.authenticator;
    const submitted = await aptosClient.transaction.submit.simple({ transaction: built, senderAuthenticator: senderAuth });
    toast('TX: ' + submitted.hash.slice(0,12) + '...');
    return submitted;
  } catch(e) {
    console.error('TX failed:', e);
    toast(e.message || 'TX failed', true);
    return null;
  }
}

// ===== TOAST =====
function toast(msg, err) {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = msg;
  t.className = 'toast show' + (err ? ' error' : '');
  setTimeout(() => t.classList.remove('show'), 3000);
}

// ===== INIT =====
document.addEventListener('DOMContentLoaded', async () => {
  // Highlight active nav
  const path = location.pathname.replace(/\/$/, '') || '/';
  document.querySelectorAll('.nav a').forEach(a => {
    const href = a.getAttribute('href').replace(/\/$/, '') || '/';
    if (href === path) a.classList.add('active');
  });

  // Load SDK + handle Google callback
  await loadSDK();
  await handleKeylessCallback();
});
