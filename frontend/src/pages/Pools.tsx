import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { fromRaw } from "../chain/client";
import { loadPools, type Pool } from "../chain/pools";
import { AddLiquidityModal } from "../components/AddLiquidityModal";
import { CreatePoolModal } from "../components/CreatePoolModal";
import { RemoveLiquidityModal } from "../components/RemoveLiquidityModal";
import { StartAuctionModal } from "../components/StartAuctionModal";

export function PoolsPage() {
  const navigate = useNavigate();
  const [pools, setPools] = useState<Pool[]>([]);
  const [loading, setLoading] = useState(true);
  const [addTarget, setAddTarget] = useState<Pool | null>(null);
  const [removeTarget, setRemoveTarget] = useState<Pool | null>(null);
  const [createOpen, setCreateOpen] = useState(false);
  const [auctionOpen, setAuctionOpen] = useState(false);

  async function reload() {
    setLoading(true);
    try {
      setPools(await loadPools());
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
  }, []);

  return (
    <div className="container">
      <div className="pool-actions-top">
        <button type="button" className="btn btn-primary" onClick={() => setCreateOpen(true)}>
          + Create Pool
        </button>
        <button type="button" className="btn btn-secondary" onClick={() => setAuctionOpen(true)}>
          Start Hook Auction
        </button>
      </div>

      {loading ? (
        <div className="empty">
          <div className="icon">⚙</div>
          Loading pools...
        </div>
      ) : pools.length === 0 ? (
        <div className="empty">
          <div className="icon">💧</div>
          No pools yet
        </div>
      ) : (
        pools.map((p) => {
          const sA = p.token_a.symbol;
          const sB = p.token_b.symbol;
          const dA = p.token_a.decimals;
          const dB = p.token_b.decimals;
          return (
            <div className="card" key={p.addr}>
              <div className="pool-pair">
                {sA}/{sB}
                <span className="badge badge-fee">1 BPS</span>
                {p.hooked && <span className="badge badge-hook">HOOKED</span>}
                {p.paused && <span className="badge badge-pause">PAUSED</span>}
              </div>
              <div className="pool-grid">
                <div>
                  <span className="label">{sA}</span>
                  <br />
                  <span className="value">{fromRaw(p.reserve_a, dA).toFixed(4)}</span>
                </div>
                <div>
                  <span className="label">{sB}</span>
                  <br />
                  <span className="value">{fromRaw(p.reserve_b, dB).toFixed(4)}</span>
                </div>
                <div>
                  <span className="label">LP Supply</span>
                  <br />
                  <span className="value">{Number(p.lp_supply).toLocaleString()}</span>
                </div>
                <div>
                  <span className="label">Address</span>
                  <br />
                  <span className="value mono">{p.addr.slice(0, 10)}...</span>
                </div>
              </div>
              <div className="pool-actions">
                <button type="button" className="btn btn-secondary" onClick={() => setAddTarget(p)}>
                  + Add
                </button>
                <button
                  type="button"
                  className="btn btn-secondary"
                  onClick={() => setRemoveTarget(p)}
                >
                  − Remove
                </button>
                <button type="button" className="btn btn-secondary" onClick={() => navigate("/")}>
                  Swap
                </button>
              </div>
            </div>
          );
        })
      )}

      <CreatePoolModal
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        onDone={() => {
          setCreateOpen(false);
          reload();
        }}
      />
      <StartAuctionModal
        open={auctionOpen}
        onClose={() => setAuctionOpen(false)}
        pools={pools}
        onDone={() => {
          setAuctionOpen(false);
          reload();
        }}
      />
      <AddLiquidityModal
        pool={addTarget}
        onClose={() => setAddTarget(null)}
        onDone={() => {
          setAddTarget(null);
          reload();
        }}
      />
      <RemoveLiquidityModal
        pool={removeTarget}
        onClose={() => setRemoveTarget(null)}
        onDone={() => {
          setRemoveTarget(null);
          reload();
        }}
      />
    </div>
  );
}
