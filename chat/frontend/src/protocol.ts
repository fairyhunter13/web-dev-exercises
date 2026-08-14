/**
 * The wire protocol, mirroring chat/backend/internal/chat/protocol.go.
 *
 * Modelled as a discriminated union on `type` rather than as one interface with
 * every field optional. That is the difference between the compiler proving a
 * `switch` is exhaustive and the compiler letting you read `message.body` off a
 * presence frame.
 */

export interface ChatMessage {
  id: string
  author: string
  body: string
  sentAtMs: number
  /** Echoed back so the sender can reconcile its optimistic copy. */
  clientId?: string
}

export type Inbound =
  | { type: 'send'; author: string; body: string; clientId: string }
  | { type: 'ping' }
  /**
   * Sent once as soon as the socket opens, to ask for the transcript.
   *
   * The server cannot volunteer it: on API Gateway a connection does not exist
   * for the management API until the $connect handler has returned, so
   * anything pushed from inside $connect comes back 410 Gone.
   */
  | { type: 'hello' }

export type Outbound =
  | { type: 'message'; message: ChatMessage }
  | { type: 'history'; messages: ChatMessage[] }
  | { type: 'presence'; count: number }
  | { type: 'pong' }
  | { type: 'error'; error: string }

/**
 * Parse and validate a frame off the wire.
 *
 * Anything arriving over a socket is untrusted input, and `JSON.parse` returns
 * `any`, which means without this the type annotations above are a comment,
 * not a guarantee. A malformed frame returns null and is dropped rather than
 * throwing inside the message handler and killing the listener.
 */
export function parseOutbound(raw: unknown): Outbound | null {
  if (typeof raw !== 'string') return null

  let data: unknown
  try {
    data = JSON.parse(raw)
  } catch {
    return null
  }

  if (typeof data !== 'object' || data === null) return null
  const frame = data as Record<string, unknown>

  switch (frame.type) {
    case 'message':
      return isMessage(frame.message) ? { type: 'message', message: frame.message } : null
    case 'history': {
      // A history frame with one bad entry still delivers the good ones;
      // dropping the whole transcript over a single row would be worse.
      const messages = Array.isArray(frame.messages) ? frame.messages.filter(isMessage) : []
      return { type: 'history', messages }
    }
    case 'presence':
      return typeof frame.count === 'number' ? { type: 'presence', count: frame.count } : null
    case 'pong':
      return { type: 'pong' }
    case 'error':
      return typeof frame.error === 'string' ? { type: 'error', error: frame.error } : null
    default:
      return null
  }
}

function isMessage(value: unknown): value is ChatMessage {
  if (typeof value !== 'object' || value === null) return false
  const m = value as Record<string, unknown>
  return (
    typeof m.id === 'string' &&
    typeof m.author === 'string' &&
    typeof m.body === 'string' &&
    typeof m.sentAtMs === 'number'
  )
}
