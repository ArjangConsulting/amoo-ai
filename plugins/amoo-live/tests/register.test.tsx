import { expect, mock, test } from 'claude-code/testing'

import { amooCalls, describeAction, fitImage, lastJSONObject, sessionFromReport } from '../hooks/register'

import { mockUI, PANE, STARTED, bash, ran, UP } from './fixtures'

test('follows amoo however the agent invokes it, and nothing else', () => {
  expect(amooCalls('amoo device --runtime-id r-1 --json tap_element label="Sign in"')).toEqual([
    { kind: 'device', runtimeId: 'r-1', tool: 'tap_element', input: { label: 'Sign in' }, json: true, piped: false },
  ])
  const debug = amooCalls("/repo/.build/debug/amoo device --json --runtime-id=r-2 find_elements id=row | python3 -c 'x'")
  expect(debug).toEqual([{ kind: 'device', runtimeId: 'r-2', tool: 'find_elements', input: { id: 'row' }, json: true, piped: true }])
  expect(amooCalls('AMOO_RUNTIME_ID=r-3 amoo device --json press_back')[0]).toMatchObject({ runtimeId: 'r-3' })
  expect(amooCalls('export AMOO_RUNTIME_ID=r-4; amoo device swipe_in_direction direction=up')[0]).toMatchObject({
    runtimeId: 'r-4',
    input: { direction: 'up' },
  })
  expect(amooCalls('R=r-5 && amoo device --runtime-id "$R" --arguments-json \'{"text":"x"}\' type_text')[0]).toMatchObject({
    runtimeId: 'r-5',
    input: { text: 'x' },
  })
  expect(amooCalls('amoo device --runtime-id "$UNSET" tap_element id=a')[0]).toMatchObject({ runtimeId: undefined })
  expect(amooCalls('amoo env up --platform android --app-id com.x --json && amoo env down --runtime-id r-6')).toEqual([
    { kind: 'up', platform: 'android', appId: 'com.x', device: undefined, json: true, piped: false },
    { kind: 'down', runtimeId: 'r-6', json: false, piped: false },
  ])
  expect(amooCalls('amoo flow flows/login.amoo.json --runtime-id r-7 --output-dir /tmp/out')).toEqual([
    { kind: 'flow', runtimeId: 'r-7', file: 'flows/login.amoo.json', outputDir: '/tmp/out', piped: false },
  ])
  expect(amooCalls('amoo device stream --platform ios')).toEqual([])
  expect(amooCalls('amoo env list --json; amoo capabilities --tool tap_element; echo amoo device x')).toEqual([])
  expect(amooCalls('git commit -m "amoo device tap"; grep amoo README.md')).toEqual([])
})

test('never shows typed text, only its length', () => {
  expect(describeAction('type_text', { text: 'hunter2' })).toBe('type_text (7 chars)')
  expect(describeAction('set_text', { label: 'Password', value: 'secret' })).toBe(
    "set_text 'Password' (6 chars)",
  )
  expect(describeAction('tap_element', { label: 'Sign in' })).toBe("tap_element 'Sign in'")
  expect(describeAction('tap', { x: 10, y: 20 })).toBe('tap 10,20')
  expect(describeAction('open_url', { url: 'https://example.com/?token=abc' })).toBe('open_url')
})

test('reads a runtime from env up and env list reports, and the JSON a command ends with', () => {
  expect(
    sessionFromReport({ ok: true, runtime_id: 'r-1', platform: 'android', device: { id: 'emulator-5554' }, app: { id: 'com.example' } }),
  ).toEqual({ sessionId: 'r-1', appId: 'com.example', deviceId: 'emulator-5554', platform: 'android' })
  expect(sessionFromReport({ runtime_id: 'r-2', platform: 'ios', device: 'SIM-2', name: 'iPhone 17' })).toEqual({
    sessionId: 'r-2',
    appId: 'iPhone 17',
    deviceId: 'SIM-2',
    platform: 'ios',
  })
  expect(sessionFromReport({ ok: false, error: 'no device' })).toBeUndefined()
  expect(lastJSONObject('Building…\n{"ok":true,"runtime_id":"r-1"}\n')).toEqual({ ok: true, runtime_id: 'r-1' })
  expect(lastJSONObject('no json here')).toBeUndefined()
})

test('fits a portrait frame into the pane without stretching it', () => {
  expect(fitImage(368, 800, 40, 30)).toEqual({ columns: 28, rows: 30 })
  expect(fitImage(368, 800, 20, 30)).toEqual({ columns: 20, rows: 22 })
})

test('the pane waits for a session, on every surface', async ($) => {
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /No amoo session yet/ })).toBeDefined()
    await ui.unmount()
  }
})

test('the pane follows a session and lists its actions, on every surface', async ($, on) => {
  const clock = mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', (_, e) => {
    if (String(e.command).includes('env up')) return STARTED
    if (String(e.command).includes('assert_visible')) return ran('{"ok":false,"content":"Assertion failed."}', true)
    return ran('{"ok":true}')
  })

  await $.tool.call(bash(UP))
  await $.tool.call(bash('amoo device --runtime-id s-1 --json type_text text=hunter2'))
  await $.tool.call(bash("amoo device --runtime-id s-1 --json assert_visible label='Welcome'"))

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /com\.example\.app/ }))?.text).toBe('ios · com.example.app')
    expect((await ui.find({ type: 'Text', text: /type_text/ }))?.text).toStartWith('✓ type_text (7 chars) · ')
    expect((await ui.find({ type: 'Text', text: /assert_visible/ }))?.text).toStartWith(
      "✗ assert_visible 'Welcome' · ",
    )
    expect(await ui.find({ type: 'Text', text: /hunter2/ })).toBeUndefined()
    await ui.unmount()
  }
  await clock.advance(0)
})

test('a pane hidden by a narrow terminal says so and starts the mirror once it is drawn', async ($, on) => {
  const clock = mock.clock(on)
  on('ui.panes', () => ({
    value: [{ id: 'amoo-live', title: 'amoo live', isShown: true, isFocused: false, isPlaced: true }],
  }))
  on('ui.log', () => ({ value: undefined }))
  const spawned: string[][] = []
  const toasts: string[] = []
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow: 100 < 144 columns' } }))
  on('tool.call', () => (STARTED))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', (_, e) => {
    toasts.push(String((e as { text?: unknown }).text ?? ''))
    return { value: undefined }
  })
  on('process.spawn', async function* (_, e) {
    spawned.push((e as unknown as { argv: string[] }).argv)
    return { value: { code: 0, signal: null } }
  })

  await $.tool.call(bash(UP))
  expect(spawned).toHaveLength(0)
  expect(toasts.some((text) => text.includes('/amoo-live'))).toBe(true)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toHaveLength(1)
  expect(spawned[0]).toContain('stream')
  await ui.unmount()
})

test('the pane says why the mirror stopped when the stream exits on its own', async ($, on) => {
  const clock = mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => (STARTED))
  on('process.spawn', async function* () {
    yield { stream: 'stdout' as const, text: "Unknown tool 'stream'.\n" }
    return { value: { code: 64, signal: null } }
  })

  await $.tool.call(bash(UP))

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    await clock.advance(0)
    expect((await ui.find({ type: 'Text', text: /^mirror:/ }))?.text).toBe(
      "mirror: amoo device stream exited with 64: Unknown tool 'stream'.",
    )
    expect(await ui.find({ type: 'Text', text: /Waiting for the first frame/ })).toBeUndefined()
    await ui.unmount()
  }
})
