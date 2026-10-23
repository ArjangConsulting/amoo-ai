/** The amoo session the agent drives, from its `start_session` result. */
export type AmooLiveSession = {
  sessionId: string
  appId: string
  deviceId: string
  platform: 'ios' | 'android'
  recordingHealth?: string
}

/** One amoo tool call, as the pane lists it. Typed text is never kept. */
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

/** A session's presentation state, including artifacts retained after it ends. */
export type AmooLiveSessionView = AmooLiveSession & {
  phase: 'running' | 'ended'
  paused: boolean
  mirrorState: 'idle' | 'running' | 'failed'
  mirrorError: string | null
  frame: AmooLiveFrame | null
  actions: AmooLiveAction[]
  actionCount?: number
  planPath?: string
  flowPath?: string
  warningCount?: number
  artifactError?: string
}

/** A startup shown before start_session has resolved to a session identifier. */
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
