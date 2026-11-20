/** A device the agent leased with `amoo env up`; `sessionId` is its runtime id. */
export type AmooLiveSession = {
  sessionId: string
  appId: string
  deviceId: string
  platform: 'ios' | 'android'
}

/** One `amoo device` tool call or `amoo flow` run, as the pane lists it. Typed text is never kept. */
export type AmooLiveAction = {
  id: string
  tool: string
  summary: string
  state: 'pending' | 'succeeded' | 'failed' | 'denied'
  startedAt: number
  durationMs?: number
}

/** The newest frame `amoo device stream` wrote. */
export type AmooLiveFrame = {
  path: string
  frame: number
  width?: number
  height?: number
  receivedAt: number
  elapsedMs?: number
}

/** A session's presentation state, including the last flow's files, retained after it ends. */
export type AmooLiveSessionView = AmooLiveSession & {
  phase: 'running' | 'ended'
  paused: boolean
  mirrorState: 'idle' | 'running' | 'failed'
  mirrorError: string | null
  frame: AmooLiveFrame | null
  actions: AmooLiveAction[]
  flowPath?: string
  reportPath?: string
}

/** An `amoo env up` shown before it has resolved to a runtime id. */
export type AmooLiveStartup = {
  id: string
  appId: string
  startedAt: number
  state: 'pending' | 'failed' | 'denied'
}

/** The complete pane state; actions and frames always belong to a session. */
export type AmooLiveView = {
  sessions: AmooLiveSessionView[]
  selectedId: string | null
  startups: AmooLiveStartup[]
}

declare module 'claude-code' {
  interface PluginState {
    'amoo-live': {
      view: AmooLiveView
    }
  }
}
