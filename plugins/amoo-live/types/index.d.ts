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
  isOk: boolean
}

/** The newest frame `amoo device stream` wrote. */
export type AmooLiveFrame = {
  path: string
  frame: number
  width?: number
  height?: number
}

declare module 'claude-code' {
  interface PluginState {
    'amoo-live': {
      session: AmooLiveSession | null
      actions: AmooLiveAction[]
      frame: AmooLiveFrame | null
      mirrorError: string | null
    }
  }
}
