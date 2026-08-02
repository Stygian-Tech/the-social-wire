"use client";

import { ActorTypeaheadInput } from "@/components/ActorTypeaheadInput";

interface LoginHandleTypeaheadProps {
  value: string;
  onValueChange: (value: string) => void;
  disabled?: boolean;
}

export function LoginHandleTypeahead({
  value,
  onValueChange,
  disabled,
}: LoginHandleTypeaheadProps) {
  return (
    <ActorTypeaheadInput
      id="handle"
      value={value}
      onValueChange={onValueChange}
      placeholder="you.bsky.social"
      autoComplete="username"
      required
      disabled={disabled}
      className="h-11"
    />
  );
}
