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

export function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

export function clip(value: string, length = 32): string {
  return value.length > length ? `${value.slice(0, Math.max(0, length - 1))}…` : value
}

/**
 * The session an `amoo env up --json` report or an `amoo env list --json` entry describes, keyed
 * by its runtime id: the `--runtime-id` every later `amoo device` and `amoo env down` call names.
 */
export function sessionFromReport(report: Input, appId?: string): AmooLiveSession | undefined {
  const runtimeId = text(report.runtime_id)
  const platform = text(report.platform)
  const device = report.device
  const deviceId =
    text(device) ?? (device !== null && typeof device === 'object' ? text((device as Input).id) : undefined)
  if (!runtimeId || !deviceId || (platform !== 'ios' && platform !== 'android')) return undefined
  const app = report.app
  const reportedApp = app !== null && typeof app === 'object' ? text((app as Input).id) : undefined
  return { sessionId: runtimeId, appId: reportedApp ?? appId ?? text(report.name) ?? deviceId, deviceId, platform }
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

/** Adds a session; one the agent just started is selected, one found mid-run only when none is. */
export function addSession(state: AmooLiveView, current: AmooLiveSession, select = true): AmooLiveView {
  const retained = state.sessions.filter((item) => item.sessionId !== current.sessionId)
  const oldEnded = retained.filter((item) => item.phase === 'ended').slice(0, -19)
  return {
    ...state,
    selectedId: select || !state.selectedId ? current.sessionId : state.selectedId,
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
  return `amoo · ${current.platform} · ${clip(current.appId, 40)} · ${phase}`
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
