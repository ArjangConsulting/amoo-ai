import { atom, read, update } from 'claude-code'
import type { EngineInterface } from 'claude-code'

import type { AmooLiveSession, AmooLiveSessionView, AmooLiveView } from '../types'

export type Input = Record<string, unknown>

export const PANE = 'amoo-live'
export const view = atom({ plugin: 'amoo-live', key: 'view' } as const, {
  sessions: [],
  selectedId: null,
  startups: [],
})

export function readView($: EngineInterface): Promise<AmooLiveView> {
  return read($, view)
}

export function updateView($: EngineInterface, change: (state: AmooLiveView) => AmooLiveView) {
  return update($, view, change)
}

const AMOO_TOOL = /^mcp__(?:plugin_amoo_)?amoo__([a-z_]+)$/
const STARTED = /Started session (\S+) for (\S+) on (ios|android) device (\S+?)\.(?:\s|$)/

export function amooToolName(tool: string): string | undefined {
  return AMOO_TOOL.exec(tool)?.[1]
}

export function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

export function structured(result: unknown): Input | undefined {
  if (result === null || typeof result !== 'object') return undefined
  const content = (result as { structuredContent?: unknown }).structuredContent
  return content !== null && typeof content === 'object' ? (content as Input) : undefined
}

export function clip(value: string, length = 32): string {
  return value.length > length ? `${value.slice(0, Math.max(0, length - 1))}…` : value
}

/** The session start_session reports, with a text fallback for clients that drop structured content. */
export function startedSession(result: unknown, resultText: string | undefined): AmooLiveSession | undefined {
  const fields = structured(result)
  const platform = text(fields?.platform)
  if (
    fields &&
    text(fields.session_id) &&
    text(fields.device_id) &&
    (platform === 'ios' || platform === 'android')
  ) {
    return {
      sessionId: String(fields.session_id),
      appId: text(fields.app_id) ?? '',
      deviceId: String(fields.device_id),
      platform,
      recordingHealth: text(fields.recording_health),
    }
  }
  const [, sessionId, appId, matchedPlatform, deviceId] = (resultText && STARTED.exec(resultText)) || []
  if (!sessionId || !appId || !deviceId || (matchedPlatform !== 'ios' && matchedPlatform !== 'android'))
    return undefined
  return { sessionId, appId, platform: matchedPlatform, deviceId }
}

/** One line for the pane; typed values are represented only by their length. */
export function describeAction(tool: string, input: Input): string {
  const target = text(input.id) ?? text(input.label) ?? text(input.contains_text) ?? text(input.description)
  const named = target ? ` '${clip(target)}'` : ''
  switch (tool) {
    case 'tap':
    case 'double_tap':
    case 'long_press':
      return `${tool} ${input.x},${input.y}`
    case 'type_text':
      return `type_text (${String(input.text ?? '').length} chars)`
    case 'set_text':
    case 'fill_field':
      return `${tool}${named} (${String(input.value ?? '').length} chars)`
    case 'swipe_in_direction':
    case 'scroll':
      return `${tool} ${text(input.direction) ?? ''}${named}`.trimEnd()
    case 'device_launch_app':
    case 'device_terminate_app':
      return `${tool} ${text(input.app_id) ?? ''}`.trimEnd()
    case 'open_url':
      return 'open_url'
    default:
      return `${tool}${named}`
  }
}

export function selectedSession(state: AmooLiveView): AmooLiveSessionView | undefined {
  return state.sessions.find((item) => item.sessionId === state.selectedId)
}

export function changeSession(
  $: EngineInterface,
  id: string,
  change: (current: AmooLiveSessionView) => AmooLiveSessionView,
) {
  return update($, view, (state) => ({
    ...state,
    sessions: state.sessions.map((current) => (current.sessionId === id ? change(current) : current)),
  }))
}

export function addSession(state: AmooLiveView, current: AmooLiveSession): AmooLiveView {
  const retained = state.sessions.filter((item) => item.sessionId !== current.sessionId)
  const oldEnded = retained.filter((item) => item.phase === 'ended').slice(0, -19)
  return {
    ...state,
    selectedId: current.sessionId,
    sessions: [
      ...retained.filter((item) => !oldEnded.includes(item)),
      {
        ...current,
        phase: 'running',
        paused: false,
        mirrorState: 'idle',
        mirrorError: null,
        frame: null,
        actions: [],
      },
    ],
  }
}

export function statusLine(current: AmooLiveSessionView | undefined): string | undefined {
  if (!current) return undefined
  const phase =
    current.phase === 'ended'
      ? 'ended'
      : current.paused
        ? 'paused'
        : current.mirrorState === 'failed'
          ? 'mirror failed'
          : 'running'
  const health = current.recordingHealth ? ` · rec ${current.recordingHealth}` : ''
  return `amoo · ${current.platform} · ${clip(current.appId, 40)} · ${phase}${health}`
}

export function duration(milliseconds: number): string {
  const seconds = Math.max(0, milliseconds) / 1000
  return seconds < 10 ? `${seconds.toFixed(1)}s` : `${Math.floor(seconds)}s`
}

/** Fits a picture in terminal cells, approximating a cell as twice as tall as it is wide. */
export function fitImage(width: number, height: number, columns: number, rows: number) {
  const fittedColumns = Math.max(1, Math.min(255, columns, Math.round((rows * 2 * width) / height)))
  const fittedRows = Math.max(1, Math.min(255, rows, Math.round((fittedColumns * height) / width / 2)))
  return { columns: fittedColumns, rows: fittedRows }
}
