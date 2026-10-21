import { expect, test } from 'claude-code/testing'

import { amooToolName, describeAction, fitImage, startedSession } from '../hooks/register'

const PANE = {
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

const STARTED_TEXT = 'Started session s-1 for com.example.app on ios device SIM-1.'

test('recognises amoo tools from a configured server and from the amoo plugin', () => {
  expect(amooToolName('mcp__amoo__tap_element')).toBe('tap_element')
  expect(amooToolName('mcp__plugin_amoo_amoo__start_session')).toBe('start_session')
  expect(amooToolName('mcp__other__tap_element')).toBeUndefined()
  expect(amooToolName('Bash')).toBeUndefined()
})

test('never shows typed text, only its length', () => {
  expect(describeAction('type_text', { text: 'hunter2' })).toBe('type_text (7 chars)')
  expect(describeAction('set_text', { label: 'Password', value: 'secret' })).toBe("set_text 'Password' (6 chars)")
  expect(describeAction('tap_element', { label: 'Sign in' })).toBe("tap_element 'Sign in'")
  expect(describeAction('tap', { x: 10, y: 20 })).toBe('tap 10,20')
  expect(describeAction('open_url', { url: 'https://example.com/?token=abc' })).toBe('open_url')
})

test('reads the started session from structured content, else from the text', () => {
  const structured = startedSession(
    {
      structuredContent: {
        session_id: 's-2',
        app_id: 'com.example',
        device_id: 'emulator-5554',
        platform: 'android',
        recording_health: 'pending',
      },
    },
    undefined,
  )
  expect(structured).toEqual({
    sessionId: 's-2',
    appId: 'com.example',
    deviceId: 'emulator-5554',
    platform: 'android',
    recordingHealth: 'pending',
  })
  expect(startedSession(undefined, STARTED_TEXT)).toEqual({
    sessionId: 's-1',
    appId: 'com.example.app',
    platform: 'ios',
    deviceId: 'SIM-1',
  })
  expect(startedSession(undefined, 'start_session failed: no device')).toBeUndefined()
})

test('fits a portrait frame into the pane without stretching it', () => {
  expect(fitImage(368, 800, 40, 30)).toEqual({ columns: 28, rows: 30 })
  expect(fitImage(368, 800, 20, 30)).toEqual({ columns: 20, rows: 22 })
})

test('the pane waits for a session, on every surface', async $ => {
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /No amoo session yet/ })).toBeDefined()
    await ui.unmount()
  }
})

test('the pane follows a session and lists its actions, on every surface', async ($, on) => {
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', (_, e) => {
    if (e.tool === 'mcp__amoo__start_session') return { result: {}, text: STARTED_TEXT }
    if (e.tool === 'mcp__amoo__assert_visible') return { isError: true, result: undefined, text: 'Assertion failed after 2000ms.' }
    return { result: {}, text: 'ok' }
  })

  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  await $.tool.call({ tool: 'mcp__amoo__type_text', session_id: 's-1', text: 'hunter2' })
  await $.tool.call({ tool: 'mcp__amoo__assert_visible', session_id: 's-1', label: 'Welcome' })

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /com\.example\.app/ }))?.text).toBe('ios · com.example.app')
    expect((await ui.find({ type: 'Text', text: /type_text/ }))?.text).toBe('✓ type_text (7 chars)')
    expect((await ui.find({ type: 'Text', text: /assert_visible/ }))?.text).toBe("✗ assert_visible 'Welcome'")
    expect(await ui.find({ type: 'Text', text: /hunter2/ })).toBeUndefined()
    await ui.unmount()
  }
})

test('a pane hidden by a narrow terminal says so and starts the mirror once it is drawn', async ($, on) => {
  const spawned: string[][] = []
  const toasts: string[] = []
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow: 100 < 144 columns' } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', (_, e) => {
    toasts.push(String((e as { text?: unknown }).text ?? ''))
    return { value: undefined }
  })
  on('process.spawn', async function* (_, e) {
    spawned.push((e as unknown as { argv: string[] }).argv)
    return { value: { code: 0, signal: null } }
  })

  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  expect(spawned).toHaveLength(0)
  expect(toasts.some(text => text.includes('/amoo-live'))).toBe(true)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(spawned).toHaveLength(1)
  expect(spawned[0]).toContain('stream')
  await ui.unmount()
})

test('the pane says why the mirror stopped when the stream exits on its own', async ($, on) => {
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('ui.status', () => ({ value: undefined }))
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: "Unknown tool 'stream'.\n" }
    return { value: { code: 64, signal: null } }
  })

  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /^mirror:/ }))?.text).toBe(
      "mirror: amoo device stream exited with 64: Unknown tool 'stream'.",
    )
    expect(await ui.find({ type: 'Text', text: /Waiting for the first frame/ })).toBeUndefined()
    await ui.unmount()
  }
})
