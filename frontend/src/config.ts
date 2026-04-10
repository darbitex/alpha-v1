import { Network } from "@aptos-labs/ts-sdk";

export const PACKAGE = "0x810693eb5e17185ee7d80e548a48edcb60be4b1d56d33f8c1be716d9fb422d2e";
export const RPC = "https://fullnode.mainnet.aptoslabs.com/v1";
export const NETWORK = Network.MAINNET;
export const SLIPPAGE = 0.005;

export type TokenConfig = {
  meta: string;
  decimals: number;
  symbol: string;
};

export const TOKENS: Record<string, TokenConfig> = {
  APT: {
    meta: "0x000000000000000000000000000000000000000000000000000000000000000a",
    decimals: 8,
    symbol: "APT",
  },
  USDC: {
    meta: "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b",
    decimals: 6,
    symbol: "USDC",
  },
  USDT: {
    meta: "0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b",
    decimals: 6,
    symbol: "USDT",
  },
};
