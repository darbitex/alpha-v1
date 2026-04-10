import { useWallet } from "@aptos-labs/wallet-adapter-react";
import { useState } from "react";
import { metaCmp, toRaw, viewFn } from "../chain/client";
import { getTokenInfo } from "../chain/tokens";
import { buildEntryTx } from "../chain/tx";
import { TOKENS, type TokenConfig } from "../config";
import { Modal } from "./Modal";
import { useToast } from "./Toast";

const CUSTOM = "__custom__";

function TokenPicker({
  label,
  symbol,
  onSymbol,
  customMeta,
  onCustomMeta,
}: {
  label: string;
  symbol: string;
  onSymbol: (s: string) => void;
  customMeta: string;
  onCustomMeta: (v: string) => void;
}) {
  return (
    <>
      <label>{label}</label>
      <select value={symbol} onChange={(e) => onSymbol(e.target.value)}>
        {Object.keys(TOKENS).map((s) => (
          <option key={s} value={s}>{s}</option>
        ))}
        <option value={CUSTOM}>Custom...</option>
      </select>
      {symbol === CUSTOM && (
        <input
          type="text"
          placeholder="0x... custom metadata address"
          value={customMeta}
          onChange={(e) => onCustomMeta(e.target.value)}
        />
      )}
    </>
  );
}

async function resolveToken(symbol: string, customMeta: string): Promise<TokenConfig> {
  if (symbol === CUSTOM) {
    if (!/^0x[0-9a-fA-F]+$/.test(customMeta.trim())) throw new Error("Invalid metadata address");
    return getTokenInfo(customMeta.trim());
  }
  const t = TOKENS[symbol];
  if (!t) throw new Error("Unknown symbol");
  return t;
}

export function CreatePoolModal({
  open,
  onClose,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  onDone: () => void;
}) {
  const toast = useToast();
  const { signAndSubmitTransaction, connected } = useWallet();
  const [symA, setSymA] = useState("APT");
  const [symB, setSymB] = useState("USDC");
  const [customA, setCustomA] = useState("");
  const [customB, setCustomB] = useState("");
  const [amtA, setAmtA] = useState("");
  const [amtB, setAmtB] = useState("");
  const [status, setStatus] = useState("");
  const [err, setErr] = useState(false);
  const [busy, setBusy] = useState(false);

  function setStatusMsg(msg: string, isErr = false) {
    setStatus(msg);
    setErr(isErr);
  }

  async function submit() {
    setBusy(true);
    setStatusMsg("");
    try {
      if (!connected) throw new Error("Connect wallet first");
      setStatusMsg("Resolving tokens...");
      let tA = await resolveToken(symA, customA);
      let tB = await resolveToken(symB, customB);
      if (tA.meta.toLowerCase() === tB.meta.toLowerCase()) throw new Error("Tokens must differ");

      const numA = Number.parseFloat(amtA);
      const numB = Number.parseFloat(amtB);
      if (!numA || !numB || numA <= 0 || numB <= 0) throw new Error("Amounts must be > 0");

      let rawA = toRaw(numA, tA.decimals);
      let rawB = toRaw(numB, tB.decimals);

      if (metaCmp(tA.meta, tB.meta) > 0) {
        [tA, tB] = [tB, tA];
        [rawA, rawB] = [rawB, rawA];
      }

      const lpInit = Math.floor(Math.sqrt(Number(rawA) * Number(rawB)));
      if (lpInit <= 1000) throw new Error(`Too small: sqrt(${rawA}×${rawB})=${lpInit}, need > 1000`);

      setStatusMsg("Checking for existing pool...");
      const addrRes = await viewFn<[string]>("pool_factory::canonical_pool_address", [], [
        tA.meta,
        tB.meta,
      ]);
      const canonical = String(addrRes[0] ?? "").toLowerCase();
      const allRes = await viewFn<[string[]]>("pool_factory::get_all_pools");
      const allPools = (allRes[0] ?? []).map((a) => a.toLowerCase());
      if (allPools.includes(canonical)) {
        throw new Error(`Pool already exists: ${canonical.slice(0, 14)}...`);
      }

      setStatusMsg("Submitting transaction...");
      const tx = buildEntryTx("pool_factory", "create_canonical_pool", [
        tA.meta,
        tB.meta,
        rawA.toString(),
        rawB.toString(),
      ]);
      const resp = await signAndSubmitTransaction(tx);
      toast(`TX: ${String(resp.hash).slice(0, 12)}...`);
      setStatusMsg("✓ Pool created");
      setTimeout(onDone, 3000);
    } catch (e: unknown) {
      setStatusMsg(`✗ ${(e as Error)?.message ?? e}`, true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="Create Canonical Pool">
      <TokenPicker label="Token A" symbol={symA} onSymbol={setSymA} customMeta={customA} onCustomMeta={setCustomA} />
      <input type="number" placeholder="Amount A" value={amtA} onChange={(e) => setAmtA(e.target.value)} />
      <TokenPicker label="Token B" symbol={symB} onSymbol={setSymB} customMeta={customB} onCustomMeta={setCustomB} />
      <input type="number" placeholder="Amount B" value={amtB} onChange={(e) => setAmtB(e.target.value)} />
      <div className="modal-note">
        Canonical: 1 pool per pair. Metadata order auto-sorted bytewise. sqrt(rawA × rawB) must be &gt; 1000 or TX reverts.
      </div>
      {status && <div className={`modal-status${err ? " error" : ""}`}>{status}</div>}
      <button type="button" className="btn btn-primary" onClick={submit} disabled={busy}>
        {busy ? "Working..." : "Create Pool"}
      </button>
    </Modal>
  );
}
