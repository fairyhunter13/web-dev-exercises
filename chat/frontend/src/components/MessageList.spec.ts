import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { describe, expect, it, vi } from 'vitest'
import MessageList from './MessageList.vue'
import type { ChatMessage } from '@/protocol'

/**
 * jsdom performs no layout, so every element reports scrollHeight/clientHeight
 * of 0 and has no scrollTo at all (that's a window/Element.prototype method
 * jsdom doesn't implement for scroll containers). The stickiness watcher lives
 * or dies on those three properties, so each test defines them directly on the
 * mounted `<ul>` to fake "scrolled to the bottom" vs "scrolled up".
 */
function stubScrollGeometry(el: HTMLElement, { scrollHeight, clientHeight, scrollTop }: { scrollHeight: number; clientHeight: number; scrollTop: number }) {
  Object.defineProperty(el, 'scrollHeight', { value: scrollHeight, configurable: true })
  Object.defineProperty(el, 'clientHeight', { value: clientHeight, configurable: true })
  Object.defineProperty(el, 'scrollTop', { value: scrollTop, configurable: true, writable: true })
  el.scrollTo = vi.fn()
}

function msg(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return { id: '1', author: 'A', body: 'hi', sentAtMs: 1, ...overrides }
}

describe('MessageList', () => {
  it('auto-scrolls to the bottom when a new message arrives and the user was already there', async () => {
    const wrapper = mount(MessageList, { props: { messages: [msg()], me: 'A' } })
    const el = wrapper.find('ul').element as HTMLElement
    stubScrollGeometry(el, { scrollHeight: 200, clientHeight: 200, scrollTop: 190 }) // within STICK_THRESHOLD_PX

    await wrapper.setProps({ messages: [msg(), msg({ id: '2' })] })
    // The watcher itself awaits nextTick before scrolling (see the component's
    // comment on why), so the effect lands one tick after setProps resolves.
    await nextTick()

    expect(el.scrollTo).toHaveBeenCalledWith({ top: 200, behavior: 'smooth' })
    expect(wrapper.find('.pill').exists()).toBe(false)
  })

  it('shows an unread counter instead of scrolling when the user had scrolled up', async () => {
    const wrapper = mount(MessageList, { props: { messages: [msg()], me: 'A' } })
    const el = wrapper.find('ul').element as HTMLElement
    stubScrollGeometry(el, { scrollHeight: 1000, clientHeight: 200, scrollTop: 0 }) // far from the bottom

    await wrapper.setProps({ messages: [msg(), msg({ id: '2' }), msg({ id: '3' })] })
    // Two ticks: one for the watcher's own `await nextTick()`, a second for
    // Vue to re-render after the callback's `unread.value +=` runs.
    await nextTick()
    await nextTick()

    expect(el.scrollTo).not.toHaveBeenCalled()
    const pill = wrapper.find('.pill')
    expect(pill.exists()).toBe(true)
    expect(pill.text()).toContain('2 new messages')
  })

  it('clicking the unread pill scrolls to the bottom and clears the counter', async () => {
    const wrapper = mount(MessageList, { props: { messages: [msg()], me: 'A' } })
    const el = wrapper.find('ul').element as HTMLElement
    stubScrollGeometry(el, { scrollHeight: 1000, clientHeight: 200, scrollTop: 0 })

    await wrapper.setProps({ messages: [msg(), msg({ id: '2' })] })
    await nextTick()
    await nextTick()
    expect(wrapper.find('.pill').exists()).toBe(true)

    await wrapper.find('.pill').trigger('click')

    expect(el.scrollTo).toHaveBeenCalled()
    expect(wrapper.find('.pill').exists()).toBe(false)
  })

  it('does not auto-scroll or count unread when messages shrink or stay the same length', async () => {
    const wrapper = mount(MessageList, { props: { messages: [msg(), msg({ id: '2' })], me: 'A' } })
    const el = wrapper.find('ul').element as HTMLElement
    stubScrollGeometry(el, { scrollHeight: 1000, clientHeight: 200, scrollTop: 0 })

    await wrapper.setProps({ messages: [msg()] }) // shrank

    expect(el.scrollTo).not.toHaveBeenCalled()
    expect(wrapper.find('.pill').exists()).toBe(false)
  })

  it('marks a message as mine only when its author matches the viewer', () => {
    const wrapper = mount(MessageList, {
      props: { messages: [msg({ author: 'A' }), msg({ id: '2', author: 'B' })], me: 'A' },
    })
    const items = wrapper.findAll('li')
    expect(items[0].classes()).toContain('mine')
    expect(items[1].classes()).not.toContain('mine')
  })

  it('marks an unconfirmed optimistic message as pending by its id prefix', () => {
    const wrapper = mount(MessageList, {
      props: {
        messages: [msg({ id: 'pending-1', clientId: 'c1' }), msg({ id: 'server-2' })],
        me: 'A',
      },
    })
    const items = wrapper.findAll('li')
    expect(items[0].classes()).toContain('pending')
    expect(items[1].classes()).not.toContain('pending')
  })

  it('keys a message on clientId when present, so the optimistic echo reuses the same DOM node', async () => {
    const wrapper = mount(MessageList, {
      props: { messages: [msg({ id: 'pending-1', clientId: 'c1' })], me: 'A' },
    })
    const before = wrapper.find('li').element

    // The server echo carries a different id but the same clientId, exactly
    // the reconciliation useChatSocket performs on a `message` frame.
    await wrapper.setProps({ messages: [msg({ id: 'server-1', clientId: 'c1' })] })

    expect(wrapper.find('li').element).toBe(before)
  })

  it('falls back to id as the key when there is no clientId, so distinct history rows stay distinct nodes', async () => {
    const wrapper = mount(MessageList, {
      props: { messages: [msg({ id: '1' })], me: 'A' },
    })
    const first = wrapper.find('li').element

    await wrapper.setProps({ messages: [msg({ id: '2' })] })

    expect(wrapper.find('li').element).not.toBe(first)
  })
})
