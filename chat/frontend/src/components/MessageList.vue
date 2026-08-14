<script setup lang="ts">
import { nextTick, ref, watch } from 'vue'
import type { ChatMessage } from '@/protocol'

const props = defineProps<{ messages: readonly ChatMessage[]; me: string }>()

const list = ref<HTMLElement | null>(null)
const unread = ref(0)

/** Within this many pixels of the bottom counts as "following the conversation". */
const STICK_THRESHOLD_PX = 80

function isAtBottom(el: HTMLElement) {
  return el.scrollHeight - el.scrollTop - el.clientHeight < STICK_THRESHOLD_PX
}

function scrollToBottom() {
  const el = list.value
  if (!el) return
  el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  unread.value = 0
}

/**
 * Auto-scroll, but only when the user was already at the bottom.
 *
 * The measurement has to happen *before* the DOM updates. Once the new
 * message is in the list, `scrollHeight` has already grown and every user
 * looks like they are scrolled up. `flush: 'pre'` runs the callback before the
 * re-render, so `isAtBottom` sees the old geometry; `nextTick` then waits for
 * the new node before scrolling to it.
 *
 * `flex-direction: column-reverse` is the usual suggestion here, and it
 * inverts DOM order against visual order, which breaks screen-reader reading
 * order and Tab order (WCAG 1.3.2 and 2.4.3).
 */
watch(
  () => props.messages.length,
  async (len, prevLen) => {
    const el = list.value
    if (!el || len <= prevLen) return

    const wasAtBottom = isAtBottom(el)
    await nextTick()

    if (wasAtBottom) scrollToBottom()
    else unread.value += len - prevLen
  },
  { flush: 'pre' },
)

function formatTime(ms: number) {
  return new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}
</script>

<template>
  <div class="wrap">
    <!--
      role="log" + aria-live="polite" announces incoming messages to a screen
      reader. Polite, because assertive interrupts whatever the user is doing,
      including their own typing.
    -->
    <ul
      ref="list"
      class="list"
      role="log"
      aria-live="polite"
      aria-relevant="additions"
      aria-label="Chat messages"
    >
      <!--
        TransitionGroup gives the slide-up: entering messages animate in and,
        crucially, existing ones are FLIP-animated to their new positions via
        .msg-move. Four rules make this work, all easy to get wrong:
          1. a stable non-index key, or FLIP silently does nothing;
          2. a .msg-move rule, which is what animates the existing messages to
             their new positions rather than snapping them;
          3. position: absolute on .msg-leave-active, or the remaining items
             jump instead of sliding;
          4. no display:inline children, because FLIP cannot transform them.
      -->
      <!-- No `tag`, so TransitionGroup renders a fragment and the <li>s are
           direct children of the <ul>. `tag="template"` looks like the way to
           avoid a wrapper and is not: it renders a real <template> element,
           whose children are inert and never displayed. -->
      <TransitionGroup name="msg">
        <li
          v-for="m in messages"
          :key="m.clientId ?? m.id"
          class="msg"
          :class="{ mine: m.author === me, pending: m.id.startsWith('pending-') }"
        >
          <span class="author">{{ m.author }}</span>
          <span class="body">{{ m.body }}</span>
          <time class="time" :datetime="new Date(m.sentAtMs).toISOString()">
            {{ formatTime(m.sentAtMs) }}
          </time>
        </li>
      </TransitionGroup>
    </ul>

    <button v-if="unread > 0" class="pill" type="button" @click="scrollToBottom">
      {{ unread }} new message{{ unread === 1 ? '' : 's' }} ↓
    </button>
  </div>
</template>

<!-- Styles live in a sibling file purely for readability; `scoped` still
     applies, so the data-v attribute rewriting is unchanged. -->
<style scoped src="./MessageList.css"></style>
