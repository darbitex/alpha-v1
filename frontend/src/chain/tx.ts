import type { InputTransactionData } from "@aptos-labs/wallet-adapter-react";
import { PACKAGE } from "../config";

export function buildEntryTx(
  module: string,
  fn: string,
  functionArguments: unknown[],
  typeArguments: string[] = [],
): InputTransactionData {
  return {
    data: {
      function: `${PACKAGE}::${module}::${fn}` as `${string}::${string}::${string}`,
      typeArguments,
      functionArguments: functionArguments as never,
    },
  };
}
