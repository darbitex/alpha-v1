import { AptosWalletAdapterProvider } from "@aptos-labs/wallet-adapter-react";
import { Network } from "@aptos-labs/ts-sdk";
import type { ReactNode } from "react";

export function WalletProvider({ children }: { children: ReactNode }) {
  return (
    <AptosWalletAdapterProvider
      autoConnect
      optInWallets={["Petra", "Continue with Google", "OKX Wallet", "Nightly"]}
      dappConfig={{ network: Network.MAINNET }}
      onError={(err) => {
        console.error("wallet error", err);
      }}
    >
      {children}
    </AptosWalletAdapterProvider>
  );
}
