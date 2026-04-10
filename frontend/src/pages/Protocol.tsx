import { useEffect, useState } from "react";
import { fromRaw, viewFn } from "../chain/client";
import { loadPools, type Pool } from "../chain/pools";
import { PACKAGE } from "../config";

type ProtoState = {
  admin: string;
  treasury: string;
  factory: string;
  pools: Pool[];
  fees: Record<string, [number, number, number, number]>;
};

function explorer(addr: string, label?: string) {
  return (
    <a
      href={`https://explorer.aptoslabs.com/account/${addr}?network=mainnet`}
      target="_blank"
      rel="noopener noreferrer"
    >
      {label ?? `${addr.slice(0, 10)}...${addr.slice(-6)}`}
    </a>
  );
}

export function ProtocolPage() {
  const [state, setState] = useState<ProtoState | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function run() {
      try {
        const cfg = await viewFn<[string, string, string]>("pool::protocol_config");
        const pools = await loadPools();
        const fees: Record<string, [number, number, number, number]> = {};
        for (const p of pools) {
          try {
            const r = await viewFn<[string, string, string, string]>("pool::pending_fees", [], [
              p.addr,
            ]);
            fees[p.addr] = [Number(r[0]), Number(r[1]), Number(r[2]), Number(r[3])];
          } catch {
            fees[p.addr] = [0, 0, 0, 0];
          }
        }
        setState({ admin: cfg[0], treasury: cfg[1], factory: cfg[2], pools, fees });
      } catch (e: unknown) {
        setError((e as Error)?.message ?? String(e));
      }
    }
    run();
  }, []);

  if (error)
    return (
      <div className="container">
        <div className="empty">
          <div className="icon">⚠</div>
          Failed to load protocol state: {error}
        </div>
      </div>
    );
  if (!state)
    return (
      <div className="container">
        <div className="empty">
          <div className="icon">⚙</div>
          Loading protocol state...
        </div>
      </div>
    );

  const hooked = state.pools.filter((p) => p.hooked).length;
  const paused = state.pools.filter((p) => p.paused).length;

  return (
    <div className="container">
      <div className="card">
        <div className="pool-pair">Protocol</div>
        <div className="pool-grid">
          <div>
            <span className="label">Package</span>
            <br />
            <span className="value mono">{explorer(PACKAGE)}</span>
          </div>
          <div>
            <span className="label">Factory</span>
            <br />
            <span className="value mono">{explorer(state.factory)}</span>
          </div>
          <div>
            <span className="label">Admin (3/5 msig)</span>
            <br />
            <span className="value mono">{explorer(state.admin)}</span>
          </div>
          <div>
            <span className="label">Treasury (2/3 msig)</span>
            <br />
            <span className="value mono">{explorer(state.treasury)}</span>
          </div>
          <div>
            <span className="label">Pools</span>
            <br />
            <span className="value">{state.pools.length}</span>
          </div>
          <div>
            <span className="label">Hooked</span>
            <br />
            <span className="value">{hooked}</span>
          </div>
          <div>
            <span className="label">Paused</span>
            <br />
            <span className="value">{paused}</span>
          </div>
          <div>
            <span className="label">Fee</span>
            <br />
            <span className="value">1 BPS</span>
          </div>
        </div>
      </div>

      {state.pools.map((p) => {
        const f = state.fees[p.addr] ?? [0, 0, 0, 0];
        const sA = p.token_a.symbol;
        const sB = p.token_b.symbol;
        const dA = p.token_a.decimals;
        const dB = p.token_b.decimals;
        return (
          <div className="card" key={p.addr}>
            <div className="pool-pair">
              {sA}/{sB}
              {p.hooked && <span className="badge badge-hook">HOOKED</span>}
              {p.paused && <span className="badge badge-pause">PAUSED</span>}
            </div>
            <div className="pool-grid">
              <div>
                <span className="label">Address</span>
                <br />
                <span className="value mono">{explorer(p.addr)}</span>
              </div>
              <div>
                <span className="label">LP Supply</span>
                <br />
                <span className="value">{Number(p.lp_supply).toLocaleString()}</span>
              </div>
              <div>
                <span className="label">Reserve {sA}</span>
                <br />
                <span className="value">{fromRaw(p.reserve_a, dA).toFixed(4)}</span>
              </div>
              <div>
                <span className="label">Reserve {sB}</span>
                <br />
                <span className="value">{fromRaw(p.reserve_b, dB).toFixed(4)}</span>
              </div>
              <div>
                <span className="label">LP fees {sA}</span>
                <br />
                <span className="value">{fromRaw(f[0], dA).toFixed(6)}</span>
              </div>
              <div>
                <span className="label">LP fees {sB}</span>
                <br />
                <span className="value">{fromRaw(f[1], dB).toFixed(6)}</span>
              </div>
              <div>
                <span className="label">Protocol fees {sA}</span>
                <br />
                <span className="value">{fromRaw(f[2], dA).toFixed(6)}</span>
              </div>
              <div>
                <span className="label">Protocol fees {sB}</span>
                <br />
                <span className="value">{fromRaw(f[3], dB).toFixed(6)}</span>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
