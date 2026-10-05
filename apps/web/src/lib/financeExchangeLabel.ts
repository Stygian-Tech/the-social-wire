import type { FinanceInstrument } from "@/lib/financeFeedClient";

/** Exchange names come from the reviewed catalog; codes are never guessed. */
export function financeExchangeLabel(instrument: Pick<FinanceInstrument, "exchange" | "exchangeName">): string | undefined {
  const name = instrument.exchangeName?.trim();
  const code = instrument.exchange?.trim();
  if (name) return code && name !== code ? `${name} (${code})` : name;
  return code ? `Exchange: ${code}` : undefined;
}
