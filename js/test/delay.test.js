import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cancellableDelay, delay } from '../src/delay.js';

// Fake timers, not wall-clock tolerance. Asserting `Date.now()` deltas against a
// tolerance is the classic source of flaky CI: the test passes locally, then a
// loaded runner adds 40ms and it fails. It also cannot prove the *absence* of
// resolution, so a `delay` that resolved immediately would still pass.
describe('delay', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('does not resolve before the delay has elapsed', async () => {
    let resolved = false;
    delay(3000).then(() => {
      resolved = true;
    });

    // `advanceTimersByTimeAsync` — the Async variant is required. The
    // synchronous one fires the timer but never flushes the microtask queue, so
    // the `.then` callback would not have run yet and this assertion would pass
    // even when the implementation is correct.
    await vi.advanceTimersByTimeAsync(2999);
    expect(resolved).toBe(false);

    await vi.advanceTimersByTimeAsync(1);
    expect(resolved).toBe(true);
  });

  it('returns a promise', async () => {
    const promise = delay(0);
    expect(promise).toBeInstanceOf(Promise);
    await vi.advanceTimersByTimeAsync(0);
    await promise;
  });

  it('resolves with undefined', async () => {
    const promise = delay(10);
    await vi.advanceTimersByTimeAsync(10);
    await expect(promise).resolves.toBeUndefined();
  });
});

describe('cancellableDelay', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('rejects when the signal aborts mid-flight', async () => {
    const controller = new AbortController();
    const promise = cancellableDelay(1000, { signal: controller.signal });

    await vi.advanceTimersByTimeAsync(500);
    controller.abort(new Error('cancelled'));

    await expect(promise).rejects.toThrow('cancelled');
  });

  it('rejects immediately if the signal is already aborted', async () => {
    const controller = new AbortController();
    controller.abort(new Error('already gone'));

    await expect(cancellableDelay(1000, { signal: controller.signal })).rejects.toThrow(
      'already gone',
    );
  });

  it('resolves normally when nothing aborts it', async () => {
    const promise = cancellableDelay(1000);
    await vi.advanceTimersByTimeAsync(1000);
    await expect(promise).resolves.toBeUndefined();
  });

  it('calls clearTimeout on abort, not just reject', async () => {
    // A version that only rejected on abort (and left the timer running)
    // would still pass every test above. Spying on the global is the only
    // way to prove the timer itself was actually cancelled.
    const clearTimeoutSpy = vi.spyOn(globalThis, 'clearTimeout');
    const controller = new AbortController();
    const promise = cancellableDelay(1000, { signal: controller.signal });

    controller.abort(new Error('cancelled'));
    await expect(promise).rejects.toThrow('cancelled');

    expect(clearTimeoutSpy).toHaveBeenCalled();
    clearTimeoutSpy.mockRestore();
  });

  it('rejects with an AbortError when the signal carries no explicit reason', async () => {
    const controller = new AbortController();
    const promise = cancellableDelay(1000, { signal: controller.signal });

    controller.abort(); // no reason argument
    await expect(promise).rejects.toMatchObject({ name: 'AbortError' });
  });

  it('is a no-op to abort after the timer has already fired', async () => {
    const controller = new AbortController();
    const promise = cancellableDelay(10, { signal: controller.signal });

    await vi.advanceTimersByTimeAsync(10);
    await expect(promise).resolves.toBeUndefined();

    // Aborting a signal whose delay already resolved must not turn the
    // already-settled promise into a rejection, and must not throw.
    expect(() => controller.abort(new Error('too late'))).not.toThrow();
    await expect(promise).resolves.toBeUndefined();
  });

  it('resolves immediately with ms = 0', async () => {
    const promise = cancellableDelay(0);
    await vi.advanceTimersByTimeAsync(0);
    await expect(promise).resolves.toBeUndefined();
  });

  it('treats a negative ms the same as 0, per setTimeout semantics', async () => {
    const promise = cancellableDelay(-100);
    await vi.advanceTimersByTimeAsync(0);
    await expect(promise).resolves.toBeUndefined();
  });
});
