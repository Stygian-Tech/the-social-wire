import { financeExchangeLabel } from "@/lib/financeExchangeLabel";
import type { FinanceInstrument, FinanceSelection } from "@/lib/financeFeedClient";

export function financeInterestLabel(selection: Pick<FinanceSelection, "kind" | "reference">, instruments: FinanceInstrument[], sectors: {id:string;name:string}[]): string {
    if (selection.kind === "sector") return sectors.find(item => item.id === selection.reference)?.name ?? "Unavailable Sector";
    const instrument = instruments.find(item => item.id === selection.reference);
    return instrument ? `${instrument.name} · ${instrument.symbol} · ${[financeExchangeLabel(instrument),instrument.kind].filter(Boolean).join(" · ")}` : "Unavailable Instrument";
}
