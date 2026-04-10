import { TOKENS, type TokenConfig, RPC } from "../config";
import { normMeta } from "./client";

const TOKEN_CACHE: Record<string, TokenConfig> = {};

for (const [, t] of Object.entries(TOKENS)) TOKEN_CACHE[normMeta(t.meta)] = t;

export async function getTokenInfo(meta: string): Promise<TokenConfig> {
  const key = normMeta(meta);
  const cached = TOKEN_CACHE[key];
  if (cached) return cached;

  try {
    const res = await fetch(`${RPC}/accounts/${meta}/resource/0x1::fungible_asset::Metadata`);
    if (!res.ok) throw new Error("FA metadata 404");
    const d = await res.json();
    const info: TokenConfig = {
      meta,
      symbol: d.data?.symbol || `${meta.slice(0, 6)}...`,
      decimals: Number.parseInt(d.data?.decimals ?? "0", 10) || 0,
    };
    TOKEN_CACHE[key] = info;
    return info;
  } catch {
    const info: TokenConfig = { meta, symbol: `${meta.slice(0, 6)}...`, decimals: 0 };
    TOKEN_CACHE[key] = info;
    return info;
  }
}
