import { effectScope } from 'vue'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { backoffDelay, useChatSocket } from './useChatSocket'

/**
 * jsdom has no WebSocket, so the socket is injected rather than stubbed
 * globally. That is also what makes the reconnect *schedule* assertable:
 * combined with fake timers, the test can prove the client waits the right
 * amount of time before each retry, which is the single highest-value unit
 * test in this project, because a backoff bug only shows up in production
 * under exactly the conditions you cannot reproduce by hand.
 */
class MockWebSocket {
  static instances: MockWebSocket[] = []
  static readonly OPEN = 1

  readyState = 0
  sent: string[] = []
  onopen: (() => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  onmessage: ((e: MessageEvent) => void) | null = null

  constructor(public url: string) {
    MockWebSocket.instances.push(this)
  }

  open() {
    this.readyState = 1
    this.onopen?.()
  }

  drop() {
    this.readyState = 3
    this.onclose?.()
  }

  deliver(frame: unknown) {
    this.onmessage?.({ data: JSON.stringify(frame) } as MessageEvent)
  }

  send(data: string) {
    this.sent.push(data)
  }

  close() {
    this.readyState = 3
  }
}

const factory = (url: string) => new MockWebSocket(url) as unknown as WebSocket
const latest = () => MockWebSocket.instances.at(-1)!

/** Runs the composable inside a scope, so onScopeDispose can be exercised. */
function withScope<T>(fn: () => T): { value: T; stop: () => void } {
  const scope = effectScope()
  const value = scope.run(fn)!
  return { value, stop: () => scope.stop() }
}

beforeEach(() => {
  MockWebSocket.instances = []
  vi.stubGlobal('WebSocket', MockWebSocket)
  vi.stubGlobal('crypto', { randomUUID: () => 'uuid-1' })
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('backoffDelay', () => {
  it('doubles the window each attempt and caps it', () => {
    // random() pinned to 1 gives the top of the jitter window, which is the
    // window itself, so this asserts the schedule, not the randomness.
    const top = (n: number) => backoffDelay(n, () => 1)
    expect([top(0), top(1), top(2), top(3)]).toEqual([500, 1000, 2000, 4000])
    expect(top(20)).toBe(30_000) // capped, not 500 * 2^20
  })

  it('jitters within the window rather than always waiting the full delay', () => {
    expect(backoffDelay(3, () => 0)).toBe(0)
    expect(backoffDelay(3, () => 0.5)).toBe(2000)
    expect(backoffDelay(3, () => 1)).toBe(4000)
  })
})

describe('useChatSocket', () => {
  it('reports open, then reconnects on an unexpected close', () => {
    vi.spyOn(Math, 'random').mockReturnValue(1) // deterministic jitter
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))

    latest().open()
    expect(chat.status.value).toBe('open')

    latest().drop()
    expect(chat.status.value).toBe('reconnecting')
    expect(MockWebSocket.instances).toHaveLength(1) // has not retried yet

    vi.advanceTimersByTime(499)
    expect(MockWebSocket.instances).toHaveLength(1) // still waiting out the backoff
    vi.advanceTimersByTime(1)
    expect(MockWebSocket.instances).toHaveLength(2)

    stop()
  })

  it('gives up after maxRetries instead of retrying forever', () => {
    vi.spyOn(Math, 'random').mockReturnValue(1)
    const { value: chat, stop } = withScope(() =>
      useChatSocket({ url: 'ws://x', maxRetries: 2, socketFactory: factory }),
    )

    latest().drop()
    vi.advanceTimersByTime(500)
    latest().drop()
    vi.advanceTimersByTime(1000)
    latest().drop()

    expect(chat.status.value).toBe('failed')
    stop()
  })

  it('replaces the transcript on history so a reconnect does not duplicate it', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    const history = [{ id: '1', author: 'A', body: 'one', sentAtMs: 1 }]
    latest().deliver({ type: 'history', messages: history })
    latest().deliver({ type: 'history', messages: history })

    expect(chat.messages.value).toHaveLength(1)
    stop()
  })

  it('reconciles the optimistic copy with the server echo', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    chat.sendMessage('Hafiz', 'hello')
    expect(chat.messages.value).toHaveLength(1)
    expect(chat.messages.value[0].id).toBe('pending-uuid-1')

    latest().deliver({
      type: 'message',
      message: { id: 'server-1', author: 'Hafiz', body: 'hello', sentAtMs: 5, clientId: 'uuid-1' },
    })

    // One message, not two: the echo replaced the optimistic entry.
    expect(chat.messages.value).toHaveLength(1)
    expect(chat.messages.value[0].id).toBe('server-1')
    stop()
  })

  it('drops malformed frames instead of throwing', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    expect(() => {
      latest().onmessage?.({ data: 'not json' } as MessageEvent)
      latest().deliver({ type: 'message' }) // no message payload
      latest().deliver({ type: 'nonsense' })
    }).not.toThrow()
    expect(chat.messages.value).toHaveLength(0)
    stop()
  })

  it('asks for the transcript as its first frame on every connect', () => {
    // The server cannot volunteer the history: on API Gateway a connection
    // does not exist for the management API until $connect has returned, so a
    // push from inside $connect comes back 410 Gone. If this frame stops being
    // sent, the client silently shows an empty room on every reconnect.
    const { stop } = withScope(() =>
      useChatSocket({ url: 'ws://x', heartbeatMs: 1000, socketFactory: factory }),
    )
    latest().open()
    expect(latest().sent[0]).toBe('{"type":"hello"}')

    latest().drop()
    vi.advanceTimersByTime(60_000)
    latest().open()
    expect(latest().sent[0]).toBe('{"type":"hello"}')

    stop()
  })

  it('reconnectNow resets the attempt count and reconnects immediately', () => {
    vi.spyOn(Math, 'random').mockReturnValue(1)
    const { value: chat, stop } = withScope(() =>
      useChatSocket({ url: 'ws://x', socketFactory: factory }),
    )
    latest().open()
    latest().drop() // schedules a 500ms retry and bumps attempt to 1

    chat.reconnectNow()
    expect(chat.status.value).toBe('connecting')
    expect(MockWebSocket.instances).toHaveLength(2) // reconnected without waiting

    // A drop right after reconnectNow uses the attempt-0 delay (500ms), which
    // proves the counter was reset rather than left at 1.
    latest().drop()
    vi.advanceTimersByTime(499)
    expect(MockWebSocket.instances).toHaveLength(2)
    vi.advanceTimersByTime(1)
    expect(MockWebSocket.instances).toHaveLength(3)

    stop()
  })

  it('sets lastError on a socket error event', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    latest().onerror?.()
    expect(chat.lastError.value).toBe('connection error')
    stop()
  })

  it('updates peerCount on a presence frame', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    latest().deliver({ type: 'presence', count: 3 })
    expect(chat.peerCount.value).toBe(3)
    stop()
  })

  it('sets lastError on an error frame', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    latest().open()

    latest().deliver({ type: 'error', error: 'boom' })
    expect(chat.lastError.value).toBe('boom')
    stop()
  })

  it('sendMessage returns null on a closed socket instead of queueing it', () => {
    const { value: chat, stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))
    // Never opened, so readyState stays 0 (CONNECTING), not OPEN.
    expect(chat.sendMessage('Hafiz', 'hello')).toBeNull()
    expect(chat.messages.value).toHaveLength(0)
    stop()
  })

  it('resets attempt to 0 after a successful re-open, so the next disconnect starts the backoff over', () => {
    vi.spyOn(Math, 'random').mockReturnValue(1)
    const { stop } = withScope(() => useChatSocket({ url: 'ws://x', socketFactory: factory }))

    latest().open()
    latest().drop() // uses backoffDelay(0)=500ms, bumps attempt to 1
    vi.advanceTimersByTime(500)
    expect(MockWebSocket.instances).toHaveLength(2)
    latest().open() // successful re-open should reset attempt to 0

    latest().drop()
    vi.advanceTimersByTime(499)
    expect(MockWebSocket.instances).toHaveLength(2) // still the reconnected socket, no retry yet
    vi.advanceTimersByTime(1) // 500 * 2^0, proving attempt was reset rather than left at 1
    expect(MockWebSocket.instances).toHaveLength(3)

    stop()
  })

  it('closes the socket and clears the heartbeat when its scope is disposed', () => {
    const { value: chat, stop } = withScope(() =>
      useChatSocket({ url: 'ws://x', heartbeatMs: 1000, socketFactory: factory }),
    )
    latest().open()

    // The opening hello is not a heartbeat, so count only the pings.
    const pings = () => latest().sent.filter((f: string) => f.includes('"ping"'))

    vi.advanceTimersByTime(2000)
    expect(pings()).toHaveLength(2) // two heartbeats

    stop()
    expect(chat.status.value).toBe('closed')

    // The leak test: after disposal nothing keeps ticking and nothing retries.
    vi.advanceTimersByTime(10_000)
    expect(pings()).toHaveLength(2)
    expect(MockWebSocket.instances).toHaveLength(1)
  })
})
