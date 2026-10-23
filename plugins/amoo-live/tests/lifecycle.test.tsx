import { expect, test } from 'claude-code/testing'

import { COMMAND, mockUI, PANE, STARTED_TEXT } from './fixtures'

test('rendering or reopening an ended session never starts capture and retains copyable artifacts', async ($, on) => {
  const clock = mockUI(on)
  const spawned: string[][] = []
  const copied: string[] = []
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('ui.copy', (_, e) => {
    copied.push(e.text)
    return { value: { isCopied: true } }
  })
  on('tool.call', (_, e) =>
    e.tool === 'mcp__amoo__start_session'
      ? { result: {}, text: STARTED_TEXT }
      : {
          result: {
            structuredContent: {
              session_id: 's-1',
              recording_health: 'saved',
              action_count: 3,
              warning_count: 2,
              plan_path: '/session/plan.json',
              flow_path: '/session/flow.json',
            },
          },
          text: 'Ended session s-1.',
        },
  )
  on('process.spawn', async function* (_, e) {
    spawned.push(e.argv as string[])
    return { value: { code: 0, signal: null } }
  })

  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  await $.tool.call({ tool: 'mcp__amoo__end_session', session_id: 's-1' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  await $.command.run(COMMAND)
  await clock.advance(0)

  expect(spawned).toHaveLength(0)
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)( · rec .*)?$/ }))?.text,
  ).toBe('Ended · rec saved')
  expect(await ui.find({ text: /3 recorded action\(s\) · 2 generation warning\(s\)/ })).toBeDefined()
  expect(await ui.find({ key: 'capture' })).toBeUndefined()
  await ui.press({ key: 'copy-plan' })
  await ui.press({ key: 'copy-flow' })
  expect(copied).toEqual(['/session/plan.json', '/session/flow.json'])
  await ui.unmount()
})

test('parallel sessions keep actions and closure scoped to the correct device', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', (_, e) => {
    if (e.tool === 'mcp__amoo__start_session') {
      const first = e.app_id === 'com.first'
      return {
        result: {},
        text: `Started session ${first ? 's-1' : 's-2'} for ${e.app_id} on ios device ${first ? 'SIM-1' : 'SIM-2'}.`,
      }
    }
    return { result: {}, text: 'ok' }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.first' })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.second' })
  await $.tool.call({ tool: 'mcp__amoo__tap_element', session_id: 's-1', label: 'First' })
  await $.tool.call({ tool: 'mcp__amoo__end_session', session_id: 's-1' })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect(await ui.find({ type: 'Text', text: /com.second/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeUndefined()
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)( · rec .*)?$/ }))?.text,
  ).toBe('Running')
  await ui.press({ key: 'session-s-1' })
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeDefined()
  expect(
    (await ui.find({ type: 'Text', text: /^(Running|Ended|Paused|Mirror failed)( · rec .*)?$/ }))?.text,
  ).toBe('Ended')
  await ui.press({ key: 'session-s-2' })
  expect(await ui.find({ type: 'Text', text: /First/ })).toBeUndefined()
  await ui.unmount()
})

test('the manual command is registered for immediate execution during a turn', async ($, on) => {
  mockUI(on)
  const registered: unknown[] = []
  on('command.register', (_, e) => {
    registered.push(e)
    return { value: { command: e.name } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  expect(registered).toContainEqual(expect.objectContaining({ name: 'amoo-live', immediate: true }))
})

test('a failed stream stays stopped across redraws and can be retried without a new session', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    yield { stream: 'stderr' as const, text: 'capture unavailable' }
    return { value: { code: null, signal: 'SIGTERM' } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toBe(1)
  expect((await ui.find({ key: 'capture' }))?.text).toBe('Retry mirror')
  expect((await ui.find({ type: 'Text', text: /^mirror:/ }))?.text).toContain(
    'signal SIGTERM: capture unavailable',
  )
  await $.command.run(COMMAND)
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.press({ key: 'capture' })
  await clock.advance(0)
  expect(spawned).toBe(2)
  await ui.unmount()
})

test('desktop and vscode panes never start a capture they cannot display', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 0, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  for (const surface of ['desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    await clock.advance(0)
    expect(await ui.find({ text: /Live pictures need Ghostty or kitty/ })).toBeDefined()
    expect(await ui.find({ key: 'capture' })).toBeUndefined()
    await ui.unmount()
  }
  expect(spawned).toBe(0)
})

test('a failed startup remains visible and cannot leave a pending row behind', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', async () => {
    const pending = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect(await pending.find({ type: 'Text', text: /^Starting com.example.app/ })).toBeDefined()
    await pending.unmount()
    return { result: undefined, isError: true, text: 'start_session failed' }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /^Starting / })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^Startup failed: com.example.app/ })).toBeDefined()
  await ui.unmount()
})

test('pending and denied actions retain no typed secret or error body', async ($, on) => {
  mockUI(on)
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'narrow' } }))
  on('tool.call', async (_, e) => {
    if (e.tool === 'mcp__amoo__start_session') return { result: {}, text: STARTED_TEXT }
    const pending = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect((await pending.find({ type: 'Text', text: /type_text/ }))?.text).toStartWith(
      '… type_text (7 chars) · ',
    )
    expect(await pending.find({ text: /hunter2/ })).toBeUndefined()
    await pending.unmount()
    return { deny: 'hunter2 is secret' }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const denied = await $.tool.call({ tool: 'mcp__amoo__type_text', session_id: 's-1', text: 'hunter2' })
  expect(denied.deny).toBe('hunter2 is secret')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /type_text/ }))?.text).toStartWith('✗ type_text (7 chars) · ')
  expect(await ui.find({ text: /hunter2/ })).toBeUndefined()
  await ui.unmount()
})

test('pane failures do not prevent session tracking or run the device tool twice', async ($, on) => {
  mockUI(on)
  let calls = 0
  on('ui.open', () => {
    throw new Error('surface unavailable')
  })
  on('tool.call', () => {
    calls += 1
    return { result: {}, text: STARTED_TEXT }
  })
  const result = await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  expect(result.text).toBe(STARTED_TEXT)
  expect(calls).toBe(1)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /com.example.app/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^Starting / })).toBeUndefined()
  await ui.unmount()
})

test('a new conversation after clear can start capture after the previous shutdown', async ($, on) => {
  const clock = mockUI(on)
  let spawned = 0
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('classic.SessionStart', () => ({}))
  on('tool.call', () => ({ result: {}, text: STARTED_TEXT }))
  on('process.spawn', async function* () {
    spawned += 1
    return { value: { code: 64, signal: null } }
  })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  await $.session.end({ reason: 'clear', sessionId: 'conversation-1', resume: { id: 'conversation-1' } })
  await $.classic.SessionStart({ source: 'clear', model: 'test' })
  await $.tool.call({ tool: 'mcp__amoo__start_session', app_id: 'com.example.app' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await clock.advance(0)
  expect(spawned).toBe(1)
  await ui.unmount()
})
