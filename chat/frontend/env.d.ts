/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** WebSocket endpoint. Set at build time; falls back to the dev server. */
  readonly VITE_WS_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
