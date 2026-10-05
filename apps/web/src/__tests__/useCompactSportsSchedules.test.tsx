import { afterEach, describe, expect, it } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useCompactSportsSchedules } from "@/hooks/useCompactSportsSchedules";

afterEach(cleanup);
function Fixture() {
  const { section, compact } = useCompactSportsSchedules();
  return <div data-testid="host" data-sports-scroll style={{ overflowAnchor: "auto" }}><section ref={section} data-testid="section" data-compact={compact} /></div>;
}
describe("Compact sports schedules", () => {
 it("uses the owning pane, ignores small offset noise, expands at the top and restores anchoring", async () => {
  const previousRequest = window.requestAnimationFrame;
  const previousCancel = window.cancelAnimationFrame;
  let queued:FrameRequestCallback | undefined;
  window.requestAnimationFrame = callback => { queued=callback;return 1; };
  window.cancelAnimationFrame = () => { queued=undefined; };
  try {
   const view=render(<Fixture />);
   const host=screen.getByTestId("host");const section=screen.getByTestId("section");
   expect(host.style.overflowAnchor).toBe("none");expect(section.dataset.compact).toBe("false");
   const scroll=async(offset:number)=>{host.scrollTop=offset;fireEvent.scroll(host);await act(()=>{queued?.(0);queued=undefined;});};
   await scroll(49);expect(section.dataset.compact).toBe("true");
   await scroll(30);expect(section.dataset.compact).toBe("true");
   await scroll(0);expect(section.dataset.compact).toBe("false");
   await scroll(30);expect(section.dataset.compact).toBe("false");
   fireEvent.scroll(window);expect(section.dataset.compact).toBe("false");
   view.unmount();expect(host.style.overflowAnchor).toBe("auto");
  } finally { window.requestAnimationFrame=previousRequest;window.cancelAnimationFrame=previousCancel; }
 });
});
