import { useWallet } from "@aptos-labs/wallet-adapter-react";
import { useEffect, useState } from "react";
import type { Pool } from "../chain/pools";
import { buildEntryTx } from "../chain/tx";
import { useAddress } from "../wallet/useConnect";
import { Modal } from "./Modal";
import { useToast } from "./Toast";

export function StartAuctionModal({
  open,
  onClose,
  pools,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  pools: Pool[];
  onDone: () => void;
}) {
  const toast = useToast();
  const { connected, signAndSubmitTransaction } = useWallet();
  const address = useAddress();
  const [poolKey, setPoolKey] = useState("");
  const [hook, setHook] = useState("");
  const [bid, setBid] = useState("100");
  const [hours, setHours] = useState("24");
  const [status, setStatus] = useState("");
  const [err, setErr] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (open) {
      setHook(address ?? "");
      setStatus("");
      setErr(false);
      if (pools.length && !poolKey) setPoolKey(`${pools[0]!.meta_a}|${pools[0]!.meta_b}`);
    }
  }, [open, address, pools, poolKey]);

  async function submit() {
    setBusy(true);
    setStatus("");
    setErr(false);
    try {
      if (!connected) throw new Error("Connect wallet first");
      if (!poolKey) throw new Error("Select a pool");
      const [metaA, metaB] = poolKey.split("|");
      if (!metaA || !metaB) throw new Error("Invalid pool selection");
      const h = hook.trim();
      if (!/^0x[0-9a-fA-F]+$/.test(h)) throw new Error("Hook address must be 0x...");
      const bidApt = Number.parseFloat(bid);
      if (!bidApt || bidApt < 100) throw new Error("Bid must be ≥ 100 APT");
      const dur = Number.parseInt(hours, 10);
      if (!dur || dur < 24 || dur > 720) throw new Error("Duration 24–720 hours");

      const bidRaw = BigInt(Math.floor(bidApt * 1e8));
      const durSecs = dur * 3600;

      setStatus("Submitting transaction...");
      const tx = buildEntryTx("pool_factory", "start_auction", [
        metaA,
        metaB,
        h,
        bidRaw.toString(),
        durSecs.toString(),
      ]);
      const resp = await signAndSubmitTransaction(tx);
      toast(`TX: ${String(resp.hash).slice(0, 12)}...`);
      setStatus("✓ Auction started");
      setTimeout(onDone, 3000);
    } catch (e: unknown) {
      setStatus(`✗ ${(e as Error)?.message ?? e}`);
      setErr(true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="Start Hook Auction">
      <label>Pool</label>
      {pools.length === 0 ? (
        <div className="modal-note">No pools available</div>
      ) : (
        <select value={poolKey} onChange={(e) => setPoolKey(e.target.value)}>
          {pools.map((p) => (
            <option key={p.addr} value={`${p.meta_a}|${p.meta_b}`}>
              {p.token_a.symbol}/{p.token_b.symbol} — {p.addr.slice(0, 10)}...
              {p.hooked ? " [HOOKED]" : ""}
            </option>
          ))}
        </select>
      )}
      <label>Hook address</label>
      <input type="text" placeholder="0x..." value={hook} onChange={(e) => setHook(e.target.value)} />
      <label>Bid (APT, min 100)</label>
      <input type="number" value={bid} onChange={(e) => setBid(e.target.value)} />
      <label>Duration (hours, 24–720)</label>
      <input type="number" value={hours} onChange={(e) => setHours(e.target.value)} />
      <div className="modal-note">
        Bid escrowed as APT. Refunded if outbid. Paid to treasury on finalize. Anti-snipe: bids in last 10 min extend by 10 min.
      </div>
      {status && <div className={`modal-status${err ? " error" : ""}`}>{status}</div>}
      <button type="button" className="btn btn-primary" onClick={submit} disabled={busy}>
        {busy ? "Working..." : "Start Auction"}
      </button>
    </Modal>
  );
}
