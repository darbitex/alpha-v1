import type { TokenConfig } from "../config";
import { metaEq, viewFn } from "./client";
import { getTokenInfo } from "./tokens";

export type Pool = {
  addr: string;
  reserve_a: string;
  reserve_b: string;
  lp_supply: string;
  paused: boolean;
  meta_a: string;
  meta_b: string;
  token_a: TokenConfig;
  token_b: TokenConfig;
  hooked: boolean;
};

function extractInner(x: unknown): string {
  if (x && typeof x === "object" && "inner" in (x as Record<string, unknown>)) {
    return String((x as { inner: unknown }).inner);
  }
  return String(x);
}

export async function loadPools(): Promise<Pool[]> {
  const addrRes = await viewFn<[string[]]>("pool_factory::get_all_pools");
  const addrs = addrRes[0] ?? [];
  const pools: Pool[] = [];
  for (const addr of addrs) {
    try {
      const [info, tokens, hook] = await Promise.all([
        viewFn<[string, string, string, boolean]>("pool::pool_info", [], [addr]),
        viewFn<[unknown, unknown]>("pool::pool_tokens", [], [addr]),
        viewFn<[{ vec: string[] }, boolean]>("pool::pool_hook", [], [addr]),
      ]);
      const metaA = extractInner(tokens[0]);
      const metaB = extractInner(tokens[1]);
      const [tokenA, tokenB] = await Promise.all([getTokenInfo(metaA), getTokenInfo(metaB)]);
      pools.push({
        addr,
        reserve_a: String(info[0]),
        reserve_b: String(info[1]),
        lp_supply: String(info[2]),
        paused: Boolean(info[3]),
        meta_a: metaA,
        meta_b: metaB,
        token_a: tokenA,
        token_b: tokenB,
        hooked: Array.isArray(hook[0]?.vec) && hook[0].vec.length > 0,
      });
    } catch (e) {
      console.error("pool load failed", addr, e);
    }
  }
  return pools;
}

export function findPool(pools: Pool[], metaIn: string, metaOut: string): Pool | undefined {
  return pools.find(
    (p) =>
      (metaEq(p.meta_a, metaIn) && metaEq(p.meta_b, metaOut)) ||
      (metaEq(p.meta_a, metaOut) && metaEq(p.meta_b, metaIn)),
  );
}
