"use client";
import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { getFinanceSectors, searchFinanceInstruments, type FinanceSelection, type FinanceInstrument } from "@/lib/financeFeedClient";
import { financeInterestLabel } from "@/lib/financeInterestLabel";
export function FinanceCustomize({ open, onOpenChange, selections, save, saving, signedIn }: {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    selections: FinanceSelection[];
    save: (args: {
        selection: FinanceSelection;
        remove: boolean;
    }) => Promise<unknown>;
    saving: boolean;
    signedIn: boolean;
}) {
    const [search, setSearch] = useState("");
    const queryClient = useQueryClient();
    const [debouncedSearch, setDebouncedSearch] = useState("");
    useEffect(() => { const timer = setTimeout(() => setDebouncedSearch(search.trim()), 300); return () => clearTimeout(timer); }, [search]);
    const [consent, setConsent] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const instruments = useQuery({ queryKey: ["financeInstrumentSearch", debouncedSearch], queryFn: ({ signal }) => searchFinanceInstruments(debouncedSearch, signal), enabled: open && debouncedSearch.length >= 2, staleTime: 60000 });
    const sectors = useQuery({ queryKey: ["financeSectors"], queryFn: ({ signal }) => getFinanceSectors(signal), enabled: open, staleTime: 60 * 60000 });
    const selectedIDs = [...new Set(selections.filter(item => item.kind === "instrument").map(item => item.reference))].sort().slice(0, 100);
    const selectedInstruments = useQuery({
        queryKey: ["financeSelectedInstruments", selectedIDs], enabled: open && selectedIDs.length > 0, staleTime: 60 * 60000, retry: false,
        queryFn: async ({signal}) => {
            const cached = queryClient.getQueriesData<{instruments: FinanceInstrument[]}>({queryKey:["financeInstrumentSearch"]}).flatMap(([,data]) => data?.instruments ?? []);
            const resolved: FinanceInstrument[] = [];
            for (const id of selectedIDs) {
                const existing = cached.find(item => item.id === id);
                if (existing) { resolved.push(existing); continue; }
                const response = await searchFinanceInstruments(id, signal);
                const match = response.instruments.find(item => item.id === id);
                if (match) resolved.push(match);
            }
            return resolved;
        }
    });
    const instrumentLabel = (item: FinanceInstrument) => financeInterestLabel({kind:"instrument",reference:item.id},[item],[]);
    const selectionLabel = (selection: FinanceSelection) => financeInterestLabel(selection,[...(instruments.data?.instruments ?? []),...(selectedInstruments.data ?? [])],sectors.data?.sectors ?? []);
    const toggle = async (kind: FinanceSelection["kind"], reference: string) => { const existing = selections.find(s => s.kind === kind && s.reference === reference); const now = new Date().toISOString(); setError(null); try {
        await save({ selection: existing ?? { kind, reference, createdAt: now, updatedAt: now }, remove: !!existing });
    }
    catch (e) {
        setError(e instanceof Error ? e.message : "Could not save selection.");
    } };
    const choice = (kind: FinanceSelection["kind"], id: string, label: string) => <Button key={`${kind}:${id}`} size="sm" className="h-auto min-h-8 min-w-0 max-w-full whitespace-normal py-2 text-left [overflow-wrap:anywhere]" variant={selections.some(s => s.kind === kind && s.reference === id) ? "secondary" : "outline"} aria-pressed={selections.some(s => s.kind === kind && s.reference === id)} disabled={saving || !signedIn || !consent} onClick={() => void toggle(kind, id)}>{label}</Button>;
    return <Dialog open={open} onOpenChange={value => { if (value) {
        setConsent(false);
        setSearch("");
        setError(null);
    } onOpenChange(value); }}><DialogContent className="max-h-[85svh] min-w-0 grid-cols-[minmax(0,1fr)] overflow-y-auto sm:max-w-2xl [&>*]:min-w-0"><DialogHeader className="pr-8"><DialogTitle>Customize Finance</DialogTitle><DialogDescription>Your selections are public interests, not a statement of ownership. Others may copy these records. Removing a selection deletes it from your PDS and our derived preferences; copies held by others may remain.</DialogDescription></DialogHeader>{signedIn ? <label className="flex items-start gap-2 text-sm"><input type="checkbox" checked={consent} onChange={event => setConsent(event.target.checked)}/>I Understand My Selections Are Public</label> : <p>Sign in to save your interests.</p>}<label className="flex min-w-0 flex-col gap-2 text-sm">Find Instruments<input className="w-full rounded border p-2" value={search} onChange={event => setSearch(event.target.value)} placeholder="Name or Symbol"/></label><div className="flex flex-wrap gap-2">{instruments.data?.instruments.map(item => choice("instrument", item.id, instrumentLabel(item)))}</div><h3 className="font-semibold">Sectors</h3><div className="flex flex-wrap gap-2">{sectors.data?.sectors.map(item => choice("sector", item.id, item.name))}</div><h3 className="font-semibold">Selected Interests</h3><div className="flex flex-wrap gap-2">{selections.map(item => choice(item.kind, item.reference, `${selectionLabel(item)} · Remove`))}</div>{(error || instruments.error || sectors.error) ? <p role="alert" className="text-sm text-destructive">{error ?? "Reference catalog unavailable. Try again."}</p> : null}<DialogClose render={<Button variant="outline"/>}>Close</DialogClose></DialogContent></Dialog>;
}
