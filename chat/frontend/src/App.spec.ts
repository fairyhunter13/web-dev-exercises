import { mount } from '@vue/test-utils'
import { ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App.vue'
import { useChatSocket, type Status } from '@/composables/useChatSocket'

// App reads `status`/`peerCount` straight off the composable's return value,
// so mocking it (rather than injecting a fake socket, as useChatSocket.spec.ts
// does) is what lets each test drive statusLabel and the composer's disabled
// state directly, without a WebSocket in the loop at all.
vi.mock('@/composables/useChatSocket', () => ({ useChatSocket: vi.fn() }))

function mockChat(overrides: { status?: Status; peerCount?: number; sendMessage?: () => string | null } = {}) {
  const status = ref<Status>(overrides.status ?? 'open')
  const peerCount = ref(overrides.peerCount ?? 0)
  const sendMessage = vi.fn(overrides.sendMessage ?? (() => 'client-1'))
  vi.mocked(useChatSocket).mockReturnValue({
    status,
    messages: ref([]),
    peerCount,
    lastError: ref(null),
    sendMessage,
    reconnectNow: vi.fn(),
  } as unknown as ReturnType<typeof useChatSocket>)
  return { status, peerCount, sendMessage }
}

beforeEach(() => {
  localStorage.clear()
  vi.mocked(useChatSocket).mockReset()
})

describe('App statusLabel', () => {
  it.each([
    ['connecting', 0, 'Connecting…'],
    ['open', 1, 'Connected'],
    ['open', 3, 'Connected · 3 windows'],
    ['reconnecting', 0, 'Reconnecting…'],
    ['closed', 0, 'Disconnected'],
    ['failed', 0, 'Could not reconnect'],
  ] as const)('renders %s (peerCount=%i) as %s', (status, peerCount, label) => {
    mockChat({ status, peerCount })
    const wrapper = mount(App)
    expect(wrapper.find('.status').text()).toContain(label)
  })
})

describe('App composer', () => {
  it('disables the input and send button unless status is open', () => {
    mockChat({ status: 'reconnecting' })
    const wrapper = mount(App)
    expect(wrapper.find('#draft').attributes('disabled')).toBeDefined()
    expect(wrapper.find('button[type="submit"]').attributes('disabled')).toBeDefined()
  })

  it('enables the composer once status is open', () => {
    mockChat({ status: 'open' })
    const wrapper = mount(App)
    expect(wrapper.find('#draft').attributes('disabled')).toBeUndefined()
  })

  it('keeps the draft in the input when sendMessage returns null (socket not open)', async () => {
    const { sendMessage } = mockChat({ status: 'open', sendMessage: () => null })
    const wrapper = mount(App)

    const input = wrapper.find('#draft')
    await input.setValue('hello there')
    await wrapper.find('form.composer').trigger('submit')

    expect(sendMessage).toHaveBeenCalledWith(expect.any(String), 'hello there')
    expect((input.element as HTMLInputElement).value).toBe('hello there')
  })

  it('clears the draft when sendMessage succeeds', async () => {
    mockChat({ status: 'open', sendMessage: () => 'client-1' })
    const wrapper = mount(App)

    const input = wrapper.find('#draft')
    await input.setValue('hello there')
    await wrapper.find('form.composer').trigger('submit')

    expect((input.element as HTMLInputElement).value).toBe('')
  })
})
