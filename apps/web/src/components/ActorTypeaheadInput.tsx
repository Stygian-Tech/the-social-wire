"use client";

import { useId, useRef, useState, type KeyboardEvent } from "react";
import { Check, Search } from "lucide-react";
import { Avatar } from "@/components/shared/Avatar";
import { Input } from "@/components/ui/input";
import { useLoginHandleSuggestions } from "@/hooks/useLoginHandleSuggestions";
import type { LoginHandleSuggestion } from "@/lib/loginHandleTypeahead";
import { cn } from "@/lib/utils";

interface ActorTypeaheadInputProps {
  id: string;
  value: string;
  onValueChange: (value: string) => void;
  onSuggestionSelect?: (suggestion: LoginHandleSuggestion) => void;
  placeholder?: string;
  autoComplete?: string;
  autoFocus?: boolean;
  required?: boolean;
  disabled?: boolean;
  className?: string;
}

export function ActorTypeaheadInput({
  id,
  value,
  onValueChange,
  onSuggestionSelect,
  placeholder,
  autoComplete = "off",
  autoFocus,
  required,
  disabled,
  className,
}: ActorTypeaheadInputProps) {
  const listboxId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const { data: suggestions = [], isFetching } =
    useLoginHandleSuggestions(value);
  const [focused, setFocused] = useState(false);
  const [activeIndex, setActiveIndex] = useState(-1);
  const open = focused && suggestions.length > 0;

  const chooseSuggestion = (suggestion: LoginHandleSuggestion) => {
    onValueChange(suggestion.handle);
    onSuggestionSelect?.(suggestion);
    setActiveIndex(-1);
    setFocused(false);
    inputRef.current?.blur();
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (!open) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setActiveIndex((current) => (current + 1) % suggestions.length);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      setActiveIndex((current) =>
        current <= 0 ? suggestions.length - 1 : current - 1
      );
    } else if (event.key === "Enter" && activeIndex >= 0) {
      event.preventDefault();
      chooseSuggestion(suggestions[activeIndex]);
    } else if (event.key === "Escape") {
      setFocused(false);
      setActiveIndex(-1);
    }
  };

  return (
    <div className="relative">
      <div className="relative">
        <Input
          ref={inputRef}
          id={id}
          type="text"
          role="combobox"
          value={value}
          onChange={(event) => {
            onValueChange(event.target.value);
            setActiveIndex(-1);
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          autoCapitalize="none"
          autoCorrect="off"
          autoComplete={autoComplete}
          spellCheck={false}
          autoFocus={autoFocus}
          required={required}
          disabled={disabled}
          aria-autocomplete="list"
          aria-controls={listboxId}
          aria-expanded={open}
          aria-activedescendant={
            open && activeIndex >= 0
              ? `${listboxId}-option-${activeIndex}`
              : undefined
          }
          className={cn("pr-10", className)}
        />
        <Search
          aria-hidden
          className={cn(
            "pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground transition-opacity",
            isFetching && "animate-pulse"
          )}
        />
      </div>
      {open ? (
        <div
          id={listboxId}
          role="listbox"
          aria-label="Actor Suggestions"
          className="absolute inset-x-0 top-[calc(100%+0.375rem)] z-50 max-h-72 overflow-y-auto rounded-xl border bg-popover p-1 shadow-lg"
        >
          {suggestions.map((suggestion, index) => (
            <button
              key={suggestion.did}
              id={`${listboxId}-option-${index}`}
              type="button"
              role="option"
              aria-selected={activeIndex === index}
              className={cn(
                "flex w-full items-center gap-2 rounded-lg px-2 py-2 text-left hover:bg-accent",
                activeIndex === index && "bg-accent"
              )}
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => chooseSuggestion(suggestion)}
            >
              <Avatar
                src={suggestion.avatar}
                alt={suggestion.displayName || suggestion.handle}
                size={32}
                className="size-8 shrink-0"
              />
              <span className="min-w-0 flex-1">
                {suggestion.displayName ? (
                  <span className="block truncate text-sm font-medium">
                    {suggestion.displayName}
                  </span>
                ) : null}
                <span className="block truncate text-xs text-muted-foreground">
                  @{suggestion.handle}
                </span>
              </span>
              {value.trim().replace(/^@/, "") === suggestion.handle ? (
                <Check aria-hidden className="size-4 shrink-0 text-primary" />
              ) : null}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}
