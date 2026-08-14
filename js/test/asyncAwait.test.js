import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { fetchDataAsync, processDataAsync, promisify } from '../src/asyncAwait.js';

describe('async/await rewrite', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('produces the same result as the callback version', async () => {
    const promise = (async () => {
      const data = await fetchDataAsync('https://example.com');
      return processDataAsync(data);
    })();

    // Each stage has its own 1s setTimeout, so the chain needs 2s of ticks.
    await vi.advanceTimersByTimeAsync(2000);
    await expect(promise).resolves.toBe('DATA FROM HTTPS://EXAMPLE.COM');
  });

  it('runs the two stages in sequence, not in parallel', async () => {
    let settled = false;
    const promise = (async () => {
      const data = await fetchDataAsync('https://example.com');
      return processDataAsync(data);
    })();
    promise.then(() => {
      settled = true;
    });

    await vi.advanceTimersByTimeAsync(1000);
    expect(settled).toBe(false); // fetch is done, process has not started ticking

    await vi.advanceTimersByTimeAsync(1000);
    expect(settled).toBe(true);
  });

  it('rejects with a real Error, not the bare string the callback passed', async () => {
    const promise = fetchDataAsync('');

    // The assertions are attached *before* the timers are advanced. Attaching
    // them afterwards leaves the rejection unobserved for a tick, which Node
    // reports as an unhandled rejection even though the test itself passes.
    const assertions = Promise.all([
      expect(promise).rejects.toBeInstanceOf(Error),
      expect(promise).rejects.toThrow('URL is required'),
    ]);

    await vi.advanceTimersByTimeAsync(1000);
    await assertions;
  });

  it('lets a single catch cover both stages', async () => {
    const caught = [];
    const run = async (url) => {
      try {
        const data = await fetchDataAsync(url);
        return await processDataAsync(data);
      } catch (error) {
        caught.push(error.message);
        return null;
      }
    };

    const promise = run('');
    await vi.advanceTimersByTimeAsync(2000);

    await expect(promise).resolves.toBeNull();
    expect(caught).toEqual(['URL is required']);
  });

  it('promisify resolves the second callback argument', async () => {
    const asPromise = promisify((value, cb) => setTimeout(() => cb(null, value * 2), 10));
    const promise = asPromise(21);

    await vi.advanceTimersByTimeAsync(10);
    await expect(promise).resolves.toBe(42);
  });

  it('promisify rejects with an Error built from the callback\'s error argument, in isolation', async () => {
    const asPromise = promisify((cb) => setTimeout(() => cb('boom', null), 10));
    const promise = asPromise();

    const assertion = expect(promise).rejects.toThrow('boom');
    await vi.advanceTimersByTimeAsync(10);
    await assertion;
  });

  it('reaches the !data branch of processData via an empty string', async () => {
    // Every other test only exercises processDataAsync with data produced by
    // fetchDataAsync, which is never falsy. Calling it directly with '' is
    // the only way to reach the "Data is required" branch.
    const promise = processDataAsync('');

    const assertion = expect(promise).rejects.toThrow('Data is required');
    await vi.advanceTimersByTimeAsync(1000);
    await assertion;
  });

  it('runs two independent fetchDataAsync calls under Promise.all in about one second, not two', async () => {
    const start = Date.now();
    const promise = Promise.all([fetchDataAsync('https://example.com/a'), fetchDataAsync('https://example.com/b')]);

    await vi.advanceTimersByTimeAsync(1000);
    const [a, b] = await promise;

    expect(a).toBe('Data from https://example.com/a');
    expect(b).toBe('Data from https://example.com/b');
    // Fake timers advanced by exactly 1000ms (one delay's worth), and both
    // calls already resolved by then, proving they ran concurrently rather
    // than sequentially (which would need 2000ms).
    expect(Date.now() - start).toBe(1000);
  });
});
