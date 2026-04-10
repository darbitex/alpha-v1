import { PACKAGE } from "../config";

export function AboutPage() {
  const explorer = `https://explorer.aptoslabs.com/account/${PACKAGE}/modules/code/pool_factory?network=mainnet`;
  return (
    <div className="manifesto">
      <h1>Darbitex</h1>
      <div className="tagline">Permissionless Hooks DEX on Aptos — 0.01% fee</div>

      <div className="num-grid">
        <div className="num-box"><div className="big">1</div><div className="label">BPS FEE (0.01%)</div></div>
        <div className="num-box"><div className="big">V4</div><div className="label">HOOKS</div></div>
        <div className="num-box"><div className="big">6</div><div className="label">MODULES</div></div>
        <div className="num-box"><div className="big">3/5</div><div className="label">MULTISIG</div></div>
      </div>

      <h2>What is Darbitex?</h2>
      <p>
        Darbitex is an automated market maker on <strong>Aptos</strong> that introduces{" "}
        <span className="highlight">permissionless V4-style hooks</span> — allowing anyone to extend pool behavior
        without modifying the core protocol.
      </p>
      <p>
        Pools are <strong>canonical</strong> (one per pair), <strong>unowned</strong> (no admin can rug), and{" "}
        <strong>composable</strong> by default. Every swap returns a FungibleAsset that any contract can use.
      </p>

      <h2>Why 1 BPS?</h2>
      <p>
        Total swap fee is <span className="highlight">0.01%</span> — that's <strong>30x cheaper</strong> than Uniswap
        (0.3%). Designed for high-frequency, high-volume trading where fee sensitivity matters.
      </p>
      <p>
        <strong>Fee split:</strong> 90% to LPs, 5% to hook operators, 5% to protocol. On plain pools: 90% LP, 10%
        protocol.
      </p>

      <h2>Permissionless Hooks</h2>
      <p>
        Anyone can deploy a Move module and attach it to a pool via <strong>public auction</strong>. Your hook runs on
        every swap — MEV capture, dynamic fees, limit orders, TWAMM, anything you can code.
      </p>
      <p>
        Hooks are <strong>tradeable assets</strong>. Win the auction, build value, resell. This creates a market for
        pool-level innovation.
      </p>

      <h2>Architecture</h2>
      <table className="arch-table">
        <thead>
          <tr>
            <th>Module</th>
            <th>Role</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>pool</td><td>Core AMM, swap, flash loans, TWAP oracle, fee accounting</td></tr>
          <tr><td>pool_factory</td><td>Canonical pool creation, hook auctions, registry</td></tr>
          <tr><td>hook_wrapper</td><td>Aggregator gateway for hooked pools</td></tr>
          <tr><td>router</td><td>Multi-hop routing (plain + hooked mixed)</td></tr>
          <tr><td>bridge</td><td>CPMM bridge for pegged assets</td></tr>
          <tr><td>lp_coin</td><td>Per-pool LP tracking (soulbound)</td></tr>
        </tbody>
      </table>

      <h2>Fully Decentralized</h2>
      <p>Darbitex has <strong>no servers</strong>. Zero. The entire stack is decentralized:</p>
      <p><strong>Smart contracts</strong> — on Aptos mainnet, governed by a 3/5 multisig publisher.</p>
      <p>
        <strong>Frontend</strong> — hosted on <span className="highlight">Walrus</span> (decentralized storage on Sui).
        No AWS, no Vercel, no single point of failure.
      </p>
      <p>
        <strong>Backend</strong> — there is none. All state lives on-chain. Pool data, reserves, LP balances, fee
        accounting — all queried directly from Aptos RPC.
      </p>

      <h2>Governance</h2>
      <p>
        Darbitex is published from a <strong>3-of-5 multisig</strong>. Package upgrades and admin actions (pause,
        force-remove hook, protocol fee withdrawal) both require the same 3-of-5 threshold — no single key can rewrite
        the contract or touch reserves.
      </p>
      <p>
        Treasury is a separate <strong>2-of-3 multisig</strong>, passive receiver of protocol fees. <code>ADMIN</code>{" "}
        and <code>TREASURY</code> addresses are hardcoded as Move constants — changing either requires a package
        upgrade, which itself needs the threshold.
      </p>
      <p>
        <strong>Why this matters:</strong> on Aptos, the package upgrade key can rewrite function bodies. A multisig
        admin without a multisig publisher is security theater. Darbitex V1 fixes that at the foundation.
      </p>

      <h2>Audit</h2>
      <p>
        One comprehensive audit run post-deploy, committed in the repo. <strong>Zero CRITICAL findings</strong> and{" "}
        <strong>zero fund-theft vectors</strong>. Non-critical issues (DoS and governance foot-guns) are tracked in the
        audit report and patched via on-chain upgrades through the multisig.
      </p>
      <p>
        Key protections: reentrancy guards · internal reserve tracking · hot-potato flash receipts · hardcoded
        admin/treasury consts · witness-based hook claiming · overflow-safe TWAP · anti-snipe auctions.
      </p>
      <p className="dim" style={{ fontSize: 12, marginTop: 8 }}>Audits are aids, not guarantees. Read the code.</p>

      <h2>FungibleAsset Native</h2>
      <p>100% <strong>FungibleAsset</strong> — no CoinStore legacy. Works with any Aptos FA token.</p>
      <p>Zero external dependencies. Only <strong>AptosFramework</strong>.</p>

      <h2>For Builders</h2>
      <p><strong>Hook devs:</strong> write a Move module, win the auction, earn 5% of swap fees.</p>
      <p>
        <strong>Aggregators:</strong> call <code>pool_factory::get_all_pools()</code> → quote via{" "}
        <code>pool::get_amount_out()</code> → route through <code>pool::swap_entry()</code> or{" "}
        <code>hook_wrapper::swap_entry()</code>.
      </p>
      <p><strong>LPs:</strong> deposit into any pool. Earn 90% of fees automatically.</p>

      <h2>Links</h2>
      <div className="links-row">
        <a href={explorer} target="_blank" rel="noopener noreferrer">Explorer</a>
        <a href="https://github.com/darbitex/alpha-v1" target="_blank" rel="noopener noreferrer">Source Code</a>
      </div>

      <div
        style={{
          marginTop: 40,
          padding: 20,
          borderTop: "1px solid #1a1a1a",
          textAlign: "center",
          fontSize: 11,
          color: "#555",
          lineHeight: 1.8,
        }}
      >
        <strong style={{ color: "#ff8800" }}>Disclaimer:</strong> Experimental DeFi software.{" "}
        <strong>Use at your own discretion.</strong> Do not deposit more than you can afford to lose.
      </div>
    </div>
  );
}
