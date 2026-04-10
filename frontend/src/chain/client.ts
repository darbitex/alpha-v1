import { Aptos, AptosConfig, type InputViewFunctionData, type MoveValue } from "@aptos-labs/ts-sdk";
import { NETWORK, PACKAGE, RPC } from "../config";

export const aptos = new Aptos(new AptosConfig({ network: NETWORK, fullnode: RPC }));

export async function viewFn<T extends MoveValue[] = MoveValue[]>(
  fn: string,
  typeArguments: string[] = [],
  functionArguments: unknown[] = [],
): Promise<T> {
  const payload: InputViewFunctionData = {
    function: `${PACKAGE}::${fn}` as `${string}::${string}::${string}`,
    typeArguments,
    functionArguments: functionArguments as InputViewFunctionData["functionArguments"],
  };
  const res = await aptos.view({ payload });
  return res as T;
}

export function toRaw(amount: number, decimals: number): bigint {
  return BigInt(Math.floor(amount * 10 ** decimals));
}

export function fromRaw(raw: bigint | string | number, decimals: number): number {
  return Number(raw) / 10 ** decimals;
}

export function normMeta(m: string): string {
  return m.replace(/^0x0+/, "0x").toLowerCase();
}

export function metaEq(a: string, b: string): boolean {
  return normMeta(a) === normMeta(b);
}

export function metaCmp(a: string, b: string): -1 | 0 | 1 {
  const norm = (s: string) => s.replace(/^0x/i, "").padStart(64, "0").toLowerCase();
  const na = norm(a);
  const nb = norm(b);
  return na < nb ? -1 : na > nb ? 1 : 0;
}
