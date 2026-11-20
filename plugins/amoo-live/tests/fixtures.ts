import { mock } from 'claude-code/testing'
import type { On } from 'claude-code'

export const PANE = {
  plugin: 'amoo-live',
  component: 'Pane',
  requestId: 'amoo-live',
  props: {
    title: 'amoo live',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

/** A Bash call, as the agent makes it. */
export function bash(command: string) {
  return { tool: 'Bash', command } as const
}

/** What a Bash call returns: its output, which `--json` amoo commands end with a JSON object. */
export function ran(stdout: string, isError = false) {
  return { result: { stdout, stderr: '', interrupted: false }, text: stdout, ...(isError ? { isError: true } : {}) }
}

export function upOutput(runtimeId: string, appId: string, deviceId: string): string {
  return JSON.stringify({ ok: true, runtime_id: runtimeId, platform: 'ios', device: { id: deviceId }, app: { id: appId } })
}

export const UP = 'amoo env up --platform ios --app-id com.example.app --json'
export const STARTED = ran(upOutput('s-1', 'com.example.app', 'SIM-1'))

export function mockUI(on: On, shown: () => boolean = () => true) {
  on('ui.panes', () => ({
    value: [{ id: 'amoo-live', title: 'amoo live', isShown: shown(), isFocused: false, isPlaced: shown() }],
  }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  return mock.clock(on)
}

export const COMMAND = {
  command: 'amoo-live',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 160 },
} as const
