import { describe, expect, it } from 'vitest'
import { parseOutbound } from './protocol'

const validMessage = { id: '1', author: 'A', body: 'hi', sentAtMs: 1 }

describe('parseOutbound', () => {
  it('rejects non-string input', () => {
    expect(parseOutbound(undefined)).toBeNull()
    expect(parseOutbound(null)).toBeNull()
    expect(parseOutbound(42)).toBeNull()
    expect(parseOutbound({ type: 'pong' })).toBeNull()
  })

  it('rejects malformed JSON', () => {
    expect(parseOutbound('not json')).toBeNull()
    expect(parseOutbound('{oops')).toBeNull()
  })

  it('rejects JSON that parses to a non-object', () => {
    // `typeof null === 'object'` is why `data === null` is checked separately
    // from `typeof data !== 'object'` in the implementation.
    expect(parseOutbound('null')).toBeNull()
    expect(parseOutbound('3')).toBeNull()
    expect(parseOutbound('"hello"')).toBeNull()
    // An array is `typeof 'object'` too, but has no `.type`, so it falls
    // through the switch's default case.
    expect(parseOutbound('[]')).toBeNull()
  })

  it('rejects an unknown frame type', () => {
    expect(parseOutbound(JSON.stringify({ type: 'nonsense' }))).toBeNull()
    expect(parseOutbound(JSON.stringify({}))).toBeNull()
  })

  describe('message frames', () => {
    it('accepts a well-formed message', () => {
      expect(parseOutbound(JSON.stringify({ type: 'message', message: validMessage }))).toEqual({
        type: 'message',
        message: validMessage,
      })
    })

    it('rejects a missing or malformed message payload', () => {
      expect(parseOutbound(JSON.stringify({ type: 'message' }))).toBeNull()
      expect(
        parseOutbound(JSON.stringify({ type: 'message', message: { ...validMessage, id: 1 } })),
      ).toBeNull()
    })
  })

  describe('history frames', () => {
    it('keeps good rows while dropping bad ones rather than rejecting the whole frame', () => {
      const bad = { id: '2', author: 'B' } // missing body/sentAtMs
      const result = parseOutbound(
        JSON.stringify({ type: 'history', messages: [validMessage, bad] }),
      )
      expect(result).toEqual({ type: 'history', messages: [validMessage] })
    })

    it('treats a non-array messages field as empty rather than throwing', () => {
      expect(parseOutbound(JSON.stringify({ type: 'history', messages: 'nope' }))).toEqual({
        type: 'history',
        messages: [],
      })
      expect(parseOutbound(JSON.stringify({ type: 'history' }))).toEqual({
        type: 'history',
        messages: [],
      })
    })
  })

  describe('presence frames', () => {
    it('accepts a numeric count', () => {
      expect(parseOutbound(JSON.stringify({ type: 'presence', count: 3 }))).toEqual({
        type: 'presence',
        count: 3,
      })
    })

    it('rejects a missing or non-numeric count', () => {
      expect(parseOutbound(JSON.stringify({ type: 'presence' }))).toBeNull()
      expect(parseOutbound(JSON.stringify({ type: 'presence', count: '3' }))).toBeNull()
    })
  })

  describe('pong frames', () => {
    it('accepts a bare pong with no payload', () => {
      expect(parseOutbound(JSON.stringify({ type: 'pong' }))).toEqual({ type: 'pong' })
    })
  })

  describe('error frames', () => {
    it('accepts a string error', () => {
      expect(parseOutbound(JSON.stringify({ type: 'error', error: 'boom' }))).toEqual({
        type: 'error',
        error: 'boom',
      })
    })

    it('rejects a missing or non-string error', () => {
      expect(parseOutbound(JSON.stringify({ type: 'error' }))).toBeNull()
      expect(parseOutbound(JSON.stringify({ type: 'error', error: 42 }))).toBeNull()
    })
  })

  describe('isMessage guard (exercised via message frames)', () => {
    const cases: Array<[string, unknown]> = [
      ['id missing', { author: 'A', body: 'hi', sentAtMs: 1 }],
      ['id wrong type', { ...validMessage, id: 1 }],
      ['author missing', { id: '1', body: 'hi', sentAtMs: 1 }],
      ['author wrong type', { ...validMessage, author: 1 }],
      ['body missing', { id: '1', author: 'A', sentAtMs: 1 }],
      ['body wrong type', { ...validMessage, body: 1 }],
      ['sentAtMs missing', { id: '1', author: 'A', body: 'hi' }],
      ['sentAtMs wrong type', { ...validMessage, sentAtMs: '1' }],
      ['not an object', 'nope'],
      ['null', null],
    ]

    it.each(cases)('rejects when %s', (_label, message) => {
      expect(parseOutbound(JSON.stringify({ type: 'message', message }))).toBeNull()
    })

    it('accepts an optional clientId, and accepts its absence', () => {
      expect(
        parseOutbound(JSON.stringify({ type: 'message', message: validMessage })),
      ).toEqual({ type: 'message', message: validMessage })
      const withClientId = { ...validMessage, clientId: 'c1' }
      expect(
        parseOutbound(JSON.stringify({ type: 'message', message: withClientId })),
      ).toEqual({ type: 'message', message: withClientId })
    })
  })
})
