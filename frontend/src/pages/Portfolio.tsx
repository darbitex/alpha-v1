import { useEffect, useState } from "react";
import { fromRaw, viewFn } from "../chain/client";
import { loadPools, type Pool } from "../chain/pools";
import { PACKAGE } from "../config";
import { useAddress } from "../wallet/useConnect";

type Position = {
  pool: Pool;
  lp: number;
  share: number;
  valA: number;
  valB: number;
};

export function PortfolioPage() {
  const address = useAddress();
  const [loading, setLoading] = useState(true);
  const [positions, setPositions] = useState<Position[]>([]);

  useEffect(() => {
    let cancelled = false;
    async function run() {
      if (!address) {
        setPositions([]);
        setLoading(false);
        return;
      }
      setLoading(true);
      try {
        const pools = await loadPools();
        const rows: Position[] = [];
        for (const pool of pools) {
          try {
            const bal = await viewFn<[string | number]>("lp_coin::balance", [], [
              PACKAGE,
              pool.addr,
              address,
            ]);
            const lp = Number(bal[0] ?? 0);
            if (lp <= 0) continue;
            const supply = Number(pool.lp_supply);
            const share = supply > 0 ? (lp / supply) * 100 : 0;
            const valA = fromRaw((Number(pool.reserve_a) * lp) / supply, pool.token_a.decimals);
            const valB = fromRaw((Number(pool.reserve_b) * lp) / supply, pool.token_b.decimals);
            rows.push({ pool, lp, share, valA, valB });
          } catch {
            // skip
          }
        }
        if (!cancelled) setPositions(rows);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    run();
    return () => {
      cancelled = true;
    };
  }, [address]);

  if (!address) {
    return (
      <div className="container">
        <div className="empty">
          <div className="icon">💰</div>
          Connect wallet to view LP positions
        </div>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="container">
        <div className="empty">
          <div className="icon">⚙</div>
          Loading positions...
        </div>
      </div>
    );
  }

  if (positions.length === 0) {
    return (
      <div className="container">
        <div className="empty">
          <div className="icon">💧</div>
          No LP positions found
        </div>
      </div>
    );
  }

  return (
    <div className="container">
      {positions.map(({ pool, lp, share, valA, valB }) => (
        <div className="card" key={pool.addr}>
          <div className="pool-pair">
            {pool.token_a.symbol}/{pool.token_b.symbol}
            {pool.hooked && <span className="badge badge-hook">HOOKED</span>}
          </div>
          <div className="pool-grid">
            <div>
              <span className="label">LP Balance</span>
              <br />
              <span className="value">{lp.toLocaleString()}</span>
            </div>
            <div>
              <span className="label">Pool Share</span>
              <br />
              <span className="value">{share.toFixed(2)}%</span>
            </div>
            <div>
              <span className="label">{pool.token_a.symbol} Value</span>
              <br />
              <span className="value">{valA.toFixed(4)}</span>
            </div>
            <div>
              <span className="label">{pool.token_b.symbol} Value</span>
              <br />
              <span className="value">{valB.toFixed(4)}</span>
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}
