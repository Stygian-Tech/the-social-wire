import { afterEach, expect, it } from "bun:test";
import { act, cleanup, render, screen } from "@testing-library/react";
import { renderToString } from "react-dom/server";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";
import { displaySportsEntityName } from "@/lib/sportsDisplayNames";

const original = Object.getOwnPropertyDescriptor(navigator, "languages");
afterEach(() => {
  cleanup();
  if (original) Object.defineProperty(navigator, "languages", original);
  else Reflect.deleteProperty(navigator, "languages");
});
function Labels() {
  const locale = useSportsDisplayLocale();
  return <p>{displaySportsEntityName({kind:"sport",name:"American Football"},locale)} / {displaySportsEntityName({kind:"sport",name:"Football"},locale)}</p>;
}
it("keeps server markup stable and updates live browser language changes", () => {
  Object.defineProperty(navigator,"languages",{configurable:true,value:["en-GB", "en-US"]});
  expect(renderToString(<Labels />)).toContain("Football<!-- --> / <!-- -->Soccer");
  render(<Labels />);
  expect(screen.getByText("American Football / Football")).toBeTruthy();
  act(() => {
    Object.defineProperty(navigator,"languages",{configurable:true,value:["en-US"]});
    window.dispatchEvent(new window.Event("languagechange"));
  });
  expect(screen.getByText("Football / Soccer")).toBeTruthy();
});
