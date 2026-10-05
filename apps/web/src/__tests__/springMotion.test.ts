import { describe, expect, it } from "bun:test";
import { SpringMotion } from "@/lib/springMotion";

describe("Schedule spring motion", () => {
  it("retains momentum when interrupted instead of restarting a timed tween", () => {
    const spring = new SpringMotion(0, 1);
    for (let frame = 0; frame < 5; frame++) spring.advance(1 / 60);
    const position = spring.value, velocity = spring.velocity;
    expect(velocity).toBeGreaterThan(0);
    spring.target = 0; expect(spring.velocity).toBe(velocity);
    spring.advance(1 / 240); expect(spring.value).toBeGreaterThan(position);
    for (let frame = 0; frame < 240; frame++) spring.advance(1 / 60);
    expect(spring.value).toBe(0); expect(spring.velocity).toBe(0);
  });
  it("settles stably across dropped frames and snaps for reduced motion", () => {
    const spring = new SpringMotion(176, 0);
    for (let frame = 0; frame < 240; frame++) spring.advance(frame % 2 ? 1 / 120 : 10);
    expect(spring.value).toBe(0);
    spring.target = 80; spring.finish();
    expect(spring.value).toBe(80); expect(spring.velocity).toBe(0);
  });
});
