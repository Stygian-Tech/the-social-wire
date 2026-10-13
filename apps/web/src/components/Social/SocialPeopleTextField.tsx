"use client";

import { forwardRef, useId, useRef, useState, type InputHTMLAttributes, type TextareaHTMLAttributes } from "react";
import { insertSocialMention, socialMentionAtCaret } from "@/lib/socialMentionTypeahead";
import { SocialPeopleSuggestions, type PeopleSuggestionControl } from "./SocialPeopleSuggestions";

type FieldProps = { recipient?: boolean; onValueChange: (value: string) => void } & (TextareaHTMLAttributes<HTMLTextAreaElement> & InputHTMLAttributes<HTMLInputElement>);
export const SocialPeopleTextField = forwardRef<HTMLTextAreaElement, FieldProps>(function SocialPeopleTextField({ recipient = false, onValueChange, ...props }, ref) {
  const element = useRef<HTMLTextAreaElement | HTMLInputElement>(null);
  const suggestions = useRef<PeopleSuggestionControl>(null);
  const [caret, setCaret] = useState(0);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState<string>();
  const id = useId();
  const [activeId, setActiveId] = useState<string>();
  const text = String(props.value ?? "");
  const range = recipient ? undefined : socialMentionAtCaret(text, caret);
  const query = recipient ? text.replace(/^@/, "").trim() : range?.query;
  const token = `${text}:${caret}`;
  const visible = focused && !props.disabled && query !== undefined && (!recipient || !!query && !query.startsWith("did:")) && dismissed !== token;
  const common = { ...props, ref: (value: HTMLTextAreaElement | HTMLInputElement | null) => {
    element.current = value;
    if (typeof ref === "function") ref(value as HTMLTextAreaElement | null);
    else if (ref) ref.current = value as HTMLTextAreaElement | null;
  }, role: recipient ? "combobox" : "textbox", "aria-autocomplete": "list" as const, "aria-haspopup": "listbox" as const, "aria-controls": visible ? id : undefined, "aria-expanded": visible, "aria-activedescendant": visible ? activeId : undefined,
  onFocus: (event: React.FocusEvent<HTMLTextAreaElement & HTMLInputElement>) => { setFocused(true); setCaret(event.target.selectionStart ?? 0); props.onFocus?.(event); },
  onBlur: (event: React.FocusEvent<HTMLTextAreaElement & HTMLInputElement>) => { setFocused(false); props.onBlur?.(event); },
  onChange: (event: React.ChangeEvent<HTMLTextAreaElement & HTMLInputElement>) => { setCaret(event.target.selectionStart ?? 0); onValueChange(event.target.value); props.onChange?.(event); },
  onSelect: (event: React.SyntheticEvent<HTMLTextAreaElement & HTMLInputElement>) => { setCaret(event.currentTarget.selectionStart ?? 0); props.onSelect?.(event); },
  onKeyDown: (event: React.KeyboardEvent<HTMLTextAreaElement & HTMLInputElement>) => {
    if (visible && !event.metaKey && !event.ctrlKey && !event.nativeEvent.isComposing && event.keyCode !== 229 && suggestions.current?.keyDown(event.key)) { event.preventDefault(); return; }
    props.onKeyDown?.(event);
  } };
  return <div className={`relative min-w-0 ${recipient ? "w-full" : "flex-1"}`}>
    {recipient ? <input {...common} /> : <textarea {...common} />}
    {visible ? <SocialPeopleSuggestions key={`${query}:${token}`} ref={suggestions} query={query} id={id} below={recipient} onActiveChange={setActiveId} onDismiss={() => setDismissed(token)} onSelect={actor => {
      const next = recipient ? { text: actor.handle, caret: actor.handle.length } : insertSocialMention(text, range!, actor.handle);
      const input = element.current;
      if (!input) return;
      onValueChange(next.text);
      setDismissed(`${next.text}:${next.caret}`);
      requestAnimationFrame(() => { input.focus(); input.setSelectionRange(next.caret, next.caret); setCaret(next.caret); });
    }} /> : null}
  </div>;
});
