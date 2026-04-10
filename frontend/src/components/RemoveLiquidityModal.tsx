import { useWallet } from "@aptos-labs/wallet-adapter-react";
import { useState } from "react";
import type { Pool } from "../chain/pools";
import { buildEntryTx } from "../chain/tx";
import { Modal } from "./Modal";
import { useToast } from "./Toast";

export function RemoveLiquidityModal({
  pool,
  onClose,
  onDone,
}: {
  pool: Pool | null;
  onClose: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const { signAndSubmitTransaction, connected } = useWallet();
  const [lp, setLp] = useState("");
  const [busy, setBusy] = useState(false);

  if (!pool) return null;

  async function submit() {
    if (!connected || !pool) {
      toast("Connect wallet first", true);
      return;
    }
    if (!lp || Number(lp) <= 0) {
      toast("Enter LP amount", true);
      return;
    }
    setBusy(true);
    try {
      const module = pool.hooked ? "hook_wrapper" : "pool";
      const tx = buildEntryTx(module, "remove_liquidity", [pool.addr, lp]);
      const resp = await signAndSubmitTransaction(tx);
      toast(`TX: ${String(resp.hash).slice(0, 12)}...`);
      setLp("");
      onDone();
    } catch (e: unknown) {
      toast((e as Error)?.message ?? "TX failed", true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={!!pool}
      onClose={onClose}
      title={`Remove ${pool.token_a.symbol}/${pool.token_b.symbol}`}
    >
      <input
        type="number"
        placeholder="LP amount (raw)"
        value={lp}
        onChange={(e) => setLp(e.target.value)}
      />
      <div className="modal-note">LP amount in raw units. Returns tokens proportionally.</div>
      <button type="button" className="btn btn-primary" onClick={submit} disabled={busy}>
        {busy ? "Submitting..." : "Remove Liquidity"}
      </button>
    </Modal>
  );
}
