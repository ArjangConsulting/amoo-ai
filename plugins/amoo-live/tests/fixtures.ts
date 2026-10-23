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

export const STARTED_TEXT = 'Started session s-1 for com.example.app on ios device SIM-1.'

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
