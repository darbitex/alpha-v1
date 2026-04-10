import { useWallet } from "@aptos-labs/wallet-adapter-react";
import { useState } from "react";
import { toRaw } from "../chain/client";
import type { Pool } from "../chain/pools";
import { buildEntryTx } from "../chain/tx";
import { Modal } from "./Modal";
import { useToast } from "./Toast";

export function AddLiquidityModal({
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
  const [amtA, setAmtA] = useState("");
  const [amtB, setAmtB] = useState("");
  const [busy, setBusy] = useState(false);

  if (!pool) return null;

  async function submit() {
    if (!connected || !pool) {
      toast("Connect wallet first", true);
      return;
    }
    const a = Number.parseFloat(amtA);
    const b = Number.parseFloat(amtB);
    if (!a || !b || a <= 0 || b <= 0) {
      toast("Amounts must be > 0", true);
      return;
    }
    setBusy(true);
    try {
      const module = pool.hooked ? "hook_wrapper" : "pool";
      const tx = buildEntryTx(module, "add_liquidity", [
        pool.addr,
        toRaw(a, pool.token_a.decimals).toString(),
        toRaw(b, pool.token_b.decimals).toString(),
      ]);
      const resp = await signAndSubmitTransaction(tx);
      toast(`TX: ${String(resp.hash).slice(0, 12)}...`);
      setAmtA("");
      setAmtB("");
      onDone();
    } catch (e: unknown) {
      toast((e as Error)?.message ?? "TX failed", true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={!!pool} onClose={onClose} title={`Add ${pool.token_a.symbol}/${pool.token_b.symbol}`}>
      <input
        type="number"
        placeholder={`Amount ${pool.token_a.symbol}`}
        value={amtA}
        onChange={(e) => setAmtA(e.target.value)}
      />
      <input
        type="number"
        placeholder={`Amount ${pool.token_b.symbol}`}
        value={amtB}
        onChange={(e) => setAmtB(e.target.value)}
      />
      <div className="modal-note">Deposit ratio must be within 5% of current pool reserves.</div>
      <button type="button" className="btn btn-primary" onClick={submit} disabled={busy}>
        {busy ? "Submitting..." : "Add Liquidity"}
      </button>
    </Modal>
  );
}
