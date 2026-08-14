import { onScopeDispose, readonly, ref, shallowRef } from 'vue'
import { parseOutbound, type ChatMessage, type Inbound } from '@/protocol'

/**
 * WebSocket client for the chat.
 *
 * Written by hand because the question is about WebSockets, and the parts
 * worth showing are the backoff schedule, the heartbeat and the
 * reconnect-and-rehydrate cycle, which a library hides. In a production app I
 * would use VueUse's `useWebSocket`; see the README.
 *
 * The status has five states where the socket has three. `CONNECTING` on a
 * first attempt and `CONNECTING` on the ninth retry mean very different things
 * to a user, and only one of them warrants a "connection lost" banner.
 */
export type Status = 'connecting' | 'open' | 'reconnecting' | 'closed' | 'failed'

export interface ChatSocketOptions {
  url: string
  /** Attempts before giving up and surfacing `failed`. */
  maxRetries?: number
  /**
   * Heartbeat period. Tuned to API Gateway's 10-minute idle timeout rather
   * than the usual 30 seconds: on API Gateway every heartbeat is a billed
   * message, so a chatty keep-alive is the one way this demo could cost money.
   */
  heartbeatMs?: number
  /** Injectable for tests; defaults to the global. */
  socketFactory?: (url: string) => WebSocket
}

const BASE_DELAY_MS = 500
const MAX_DELAY_MS = 30_000

/**
 * Exponential backoff with full jitter.
 *
 * The jitter is the part that matters and the part libraries routinely omit.
 * When a server restarts, every client is disconnected in the same instant; an
 * un-jittered schedule has them all retry in the same instant too, so the
 * server is hit by the whole population at once, fails again, and the herd
 * re-forms. Randomising across the window spreads them out.
 *
 * Exported so the schedule can be tested directly, without a socket.
 */
export function backoffDelay(attempt: number, random: () => number = Math.random): number {
  const capped = Math.min(BASE_DELAY_MS * 2 ** attempt, MAX_DELAY_MS)
  return Math.round(random() * capped)
}

export function useChatSocket(options: ChatSocketOptions) {
  const { url, maxRetries = 8, heartbeatMs = 240_000, socketFactory } = options

  const status = ref<Status>('connecting')
  const messages = ref<ChatMessage[]>([])
  const peerCount = ref(0)
  const lastError = ref<string | null>(null)

  // shallowRef: the socket is a large non-plain object with its own internal
  // state. Deep-proxying it is pure overhead and can break native objects
  // that check their own identity.
  const socket = shallowRef<WebSocket | null>(null)

  let attempt = 0
  let heartbeatTimer: ReturnType<typeof setInterval> | undefined
  let retryTimer: ReturnType<typeof setTimeout> | undefined
  let disposed = false

  const clearTimers = () => {
    clearInterval(heartbeatTimer)
    clearTimeout(retryTimer)
    heartbeatTimer = undefined
    retryTimer = undefined
  }

  function connect() {
    if (disposed) return

    const ws = socketFactory ? socketFactory(url) : new WebSocket(url)
    socket.value = ws

    ws.onopen = () => {
      attempt = 0
      status.value = 'open'
      lastError.value = null
      // Ask for the transcript. Every reconnect repeats it, which is how the
      // client rehydrates after API Gateway's 10-minute idle timeout or
      // 2-hour hard connection cap.
      send({ type: 'hello' })
      heartbeatTimer = setInterval(() => send({ type: 'ping' }), heartbeatMs)
    }

    ws.onmessage = (event: MessageEvent) => {
      const frame = parseOutbound(event.data)
      if (!frame) return // malformed; dropped rather than thrown

      switch (frame.type) {
        case 'history':
          // Replace, not append. This arrives on every (re)connect, and
          // appending would duplicate the transcript after a reconnect.
          messages.value = frame.messages
          break
        case 'message': {
          const incoming = frame.message
          // Reconcile the optimistic copy the sender already rendered, keyed
          // on clientId. Without this the sender sees its own message twice.
          const optimistic = incoming.clientId
            ? messages.value.findIndex((m) => m.clientId === incoming.clientId)
            : -1
          if (optimistic >= 0) messages.value.splice(optimistic, 1, incoming)
          else messages.value.push(incoming)
          break
        }
        case 'presence':
          peerCount.value = frame.count
          break
        case 'error':
          lastError.value = frame.error
          break
        case 'pong':
          break
      }
    }

    // `error` carries no detail by design, because it would leak cross-origin
    // information, so the close handler does the real work.
    ws.onerror = () => {
      lastError.value = 'connection error'
    }

    ws.onclose = () => {
      clearTimers()
      socket.value = null
      if (disposed) return

      if (attempt >= maxRetries) {
        status.value = 'failed'
        return
      }
      status.value = 'reconnecting'
      retryTimer = setTimeout(connect, backoffDelay(attempt))
      attempt += 1
    }
  }

  function send(frame: Inbound): boolean {
    const ws = socket.value
    if (!ws || ws.readyState !== WebSocket.OPEN) return false
    ws.send(JSON.stringify(frame))
    return true
  }

  /**
   * Send a chat message, rendering it optimistically so the input feels
   * instant. Returns the clientId used, or null if the socket was not open, so
   * the caller surfaces that rather than silently dropping the message.
   */
  function sendMessage(author: string, body: string): string | null {
    const clientId = crypto.randomUUID()
    if (!send({ type: 'send', author, body, clientId })) return null

    messages.value.push({ id: `pending-${clientId}`, author, body, sentAtMs: Date.now(), clientId })
    return clientId
  }

  /** Reset the backoff and reconnect now, for a retry button after `failed`. */
  function reconnectNow() {
    clearTimers()
    attempt = 0
    status.value = 'connecting'
    socket.value?.close()
    connect()
  }

  connect()

  // onScopeDispose rather than onUnmounted, so this also cleans up when used
  // inside an effectScope outside a component. A socket and an interval that
  // outlive their owner are two of the most common Vue memory leaks.
  onScopeDispose(() => {
    disposed = true
    clearTimers()
    socket.value?.close(1000, 'component unmounted')
    socket.value = null
    status.value = 'closed'
  })

  return {
    status: readonly(status),
    messages: readonly(messages),
    peerCount: readonly(peerCount),
    lastError: readonly(lastError),
    sendMessage,
    reconnectNow,
  }
}
