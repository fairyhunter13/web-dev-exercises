<script setup lang="ts">
import { computed, ref } from 'vue'
import MessageList from '@/components/MessageList.vue'
import { useChatSocket } from '@/composables/useChatSocket'

/**
 * The whole app is one page opened in two windows, which is what the question
 * asks for. Each window picks its own display name, so the two transcripts are
 * distinguishable; the name is persisted so a reload does not change identity.
 */
const me = ref(localStorage.getItem('chat.name') ?? randomName())
localStorage.setItem('chat.name', me.value)

const draft = ref('')
const inputEl = ref<HTMLInputElement | null>(null)

const wsUrl =
  import.meta.env.VITE_WS_URL ??
  `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.hostname}:8080/ws`

const { status, messages, peerCount, lastError, sendMessage, reconnectNow } = useChatSocket({
  url: wsUrl,
})

const statusLabel = computed(
  () =>
    ({
      connecting: 'Connecting…',
      open: peerCount.value > 1 ? `Connected · ${peerCount.value} windows` : 'Connected',
      reconnecting: 'Reconnecting…',
      closed: 'Disconnected',
      failed: 'Could not reconnect',
    })[status.value],
)

/** Templates cannot reach browser globals, so the write lives here. */
function rememberName() {
  localStorage.setItem('chat.name', me.value)
}

function submit() {
  const body = draft.value.trim()
  if (!body) return

  if (sendMessage(me.value, body) === null) return // socket not open; keep the draft
  draft.value = ''
  inputEl.value?.focus()
}

function randomName() {
  const animals = ['Otter', 'Heron', 'Tapir', 'Gecko', 'Marlin', 'Civet']
  return `${animals[Math.floor(Math.random() * animals.length)]}-${Math.floor(Math.random() * 90 + 10)}`
}
</script>

<template>
  <main class="app">
    <header class="bar">
      <h1>Realtime Chat</h1>
      <p class="status" :data-status="status" role="status">
        <span class="dot" aria-hidden="true"></span>{{ statusLabel }}
      </p>
      <label class="name">
        <span class="sr-only">Your display name</span>
        <input v-model="me" maxlength="40" @change="rememberName" />
      </label>
    </header>

    <MessageList :messages="messages" :me="me" />

    <p v-if="lastError" class="error" role="alert">{{ lastError }}</p>

    <button v-if="status === 'failed'" class="retry" type="button" @click="reconnectNow">
      Retry connection
    </button>

    <!-- A real <form>, so Enter submits without a keydown handler and the
         browser's own semantics do the work. -->
    <form class="composer" @submit.prevent="submit">
      <label class="sr-only" for="draft">Message</label>
      <input
        id="draft"
        ref="inputEl"
        v-model="draft"
        autocomplete="off"
        maxlength="2000"
        placeholder="Type a message…"
        :disabled="status !== 'open'"
      />
      <button type="submit" :disabled="status !== 'open' || !draft.trim()">Send</button>
    </form>
  </main>
</template>

<style scoped src="./App.css"></style>
