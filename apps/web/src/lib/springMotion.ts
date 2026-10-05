/** Damped spring state. Retargeting preserves velocity, including during a reversal. */
export class SpringMotion {
  velocity = 0;
  constructor(public value: number, public target = value) {}
  advance(seconds: number) {
    let remaining = Math.min(Math.max(seconds, 0), 0.064);
    while (remaining > 0) {
      const step = Math.min(remaining, 1 / 240);
      this.velocity += ((this.target - this.value) * 260 - this.velocity * 28) * step;
      this.value += this.velocity * step;
      remaining -= step;
    }
    const settled = Math.abs(this.target - this.value) < 0.001 && Math.abs(this.velocity) < 0.01;
    if (settled) { this.value = this.target; this.velocity = 0; }
    return settled;
  }
  finish() { this.value = this.target; this.velocity = 0; }
}
