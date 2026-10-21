import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { AmooLiveAction, AmooLiveFrame, AmooLiveSession } from '../types'

const PANE = 'amoo-live'
const COMMAND = 'amoo-live'

const session = atom({ plugin: 'amoo-live', key: 'session' } as const, null)
const actions = atom({ plugin: 'amoo-live', key: 'actions' } as const, [])
const frame = atom({ plugin: 'amoo-live', key: 'frame' } as const, null)
const mirrorError = atom({ plugin: 'amoo-live', key: 'mirrorError' } as const, null)

/** `mcp__amoo__tap` (a configured server) or `mcp__plugin_amoo_amoo__tap` (the amoo plugin's). */
const AMOO_TOOL = /^mcp__(?:plugin_amoo_)?amoo__([a-z_]+)$/

/** `start_session`'s text when the client drops its structured result. */
const STARTED = /Started session (\S+) for (\S+) on (ios|android) device (\S+?)\.(?:\s|$)/

/** Polling and bookkeeping calls the pane does not list. */
const UNLISTED = new Set(['session_startup_status', 'companion_status', 'list_sessions', 'get_session_report'])

const MAX_ACTIONS = 50

type Input = Record<string, unknown>
type Mirror = { sessionId: string; stop: () => Promise<void> }

export function amooToolName(tool: string): string | undefined {
  return AMOO_TOOL.exec(tool)?.[1]
}

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function structured(result: unknown): Input | undefined {
  if (result === null || typeof result !== 'object') return undefined
  const content = (result as { structuredContent?: unknown }).structuredContent
  return content !== null && typeof content === 'object' ? (content as Input) : undefined
}

function clip(value: string, length = 32): string {
  return value.length > length ? `${value.slice(0, length - 1)}…` : value
}

/** The session `start_session` reports, from its structured result or its text. */
export function startedSession(result: unknown, resultText: string | undefined): AmooLiveSession | undefined {
  const fields = structured(result)
  const platform = text(fields?.platform)
  if (fields && text(fields.session_id) && text(fields.device_id) && (platform === 'ios' || platform === 'android')) {
    return {
      sessionId: String(fields.session_id),
      appId: text(fields.app_id) ?? '',
      deviceId: String(fields.device_id),
      platform,
      recordingHealth: text(fields.recording_health),
    }
  }
  const [, sessionId, appId, matchedPlatform, deviceId] = (resultText && STARTED.exec(resultText)) || []
  if (!sessionId || !appId || !deviceId || (matchedPlatform !== 'ios' && matchedPlatform !== 'android')) return undefined
  return { sessionId, appId, platform: matchedPlatform, deviceId }
}

/** One line for the pane. Typed values never appear: only their length. */
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

function statusLine(current: AmooLiveSession | null, ended = false): string | undefined {
  if (!current) return undefined
  const health = current.recordingHealth ? ` · rec ${current.recordingHealth}` : ''
  return `amoo · ${current.platform} · ${clip(current.appId, 40)}${ended ? ' · ended' : ''}${health}`
}

/** Columns and rows for a `width`×`height` picture in a box of cells about twice as tall as wide. */
export function fitImage(width: number, height: number, columns: number, rows: number) {
  const fittedColumns = Math.max(1, Math.min(255, columns, Math.round((rows * 2 * width) / height)))
  const fittedRows = Math.max(1, Math.min(255, rows, Math.round((fittedColumns * height) / width / 2)))
  return { columns: fittedColumns, rows: fittedRows }
}

let mirror: Mirror | undefined
/** The session whose stream exited on its own, so a re-render does not respawn it in a loop. */
let failedSessionId: string | undefined
/** The session the not-placed hint was shown for, so it appears once. */
let hintedSessionId: string | undefined
let amooPath = 'amoo'
let fps = '6'

async function stopMirror() {
  const running = mirror
  mirror = undefined
  await running?.stop()
}

/** Runs `amoo device stream` for `current`'s device and feeds its frames into state, until stopped. */
function startMirror($: EngineInterface, current: AmooLiveSession) {
  if (mirror?.sessionId === current.sessionId || failedSessionId === current.sessionId) return
  void stopMirror()
  const child = $.process.spawn({
    argv: [amooPath, 'device', 'stream', '--platform', current.platform, '--device', current.deviceId, '--fps', fps],
  })
  const own: Mirror = {
    sessionId: current.sessionId,
    stop: async () => {
      await child.return(undefined as never)
    },
  }
  mirror = own
  void followMirror($, child, own)
}

async function followMirror(
  $: EngineInterface,
  child: AsyncGenerator<{ stream: string; text: string }, { code: number | null; signal: string | null }>,
  own: Mirror,
) {
  const pending = { stdout: '', stderr: '' }
  let lastOutput = ''
  try {
    for (;;) {
      const step = await child.next()
      if (step.done) {
        if (mirror === own && step.value.code !== 0 && step.value.signal === null) {
          failedSessionId = own.sessionId
          const said = lastOutput ? `: ${lastOutput}` : ''
          await update($, mirrorError, () => `${amooPath} device stream exited with ${step.value.code}${said}`)
        }
        return
      }
      const stream = step.value.stream === 'stderr' ? 'stderr' : 'stdout'
      pending[stream] += step.value.text
      let newline = pending[stream].indexOf('\n')
      while (newline >= 0) {
        const line = pending[stream].slice(0, newline).trim()
        pending[stream] = pending[stream].slice(newline + 1)
        if (line && !(stream === 'stdout' && (await applyMirrorLine($, line)))) lastOutput = line
        newline = pending[stream].indexOf('\n')
      }
    }
  } catch (error) {
    failedSessionId = own.sessionId
    $.ui.log(`amoo-live: mirror stopped: ${String(error)}`, { to: 'debug' })
    await update($, mirrorError, () => `could not run ${amooPath} device stream`)
  } finally {
    if (mirror === own) mirror = undefined
  }
}

/** Applies one JSON line of `amoo device stream`; false when the line is not one. */
async function applyMirrorLine($: EngineInterface, line: string): Promise<boolean> {
  let event: Input
  try {
    event = JSON.parse(line) as Input
  } catch {
    return false
  }
  if (event === null || typeof event !== 'object' || typeof event.event !== 'string') return false
  if (event.event === 'frame' && typeof event.path === 'string' && typeof event.frame === 'number') {
    const next: AmooLiveFrame = {
      path: event.path,
      frame: event.frame,
      width: typeof event.width === 'number' ? event.width : undefined,
      height: typeof event.height === 'number' ? event.height : undefined,
    }
    await update($, frame, () => next)
    await update($, mirrorError, () => null)
  } else if (event.event === 'error' || (event.event === 'stopped' && text(event.message))) {
    await update($, mirrorError, () => text(event.message) ?? 'capture failed')
  }
  return true
}

export const register: Register = (on, options) => {
  amooPath = typeof options.amooPath === 'string' && options.amooPath.length > 0 ? options.amooPath : 'amoo'
  const requestedFps = typeof options.fps === 'number' ? options.fps : 6
  fps = String(Math.min(30, Math.max(0.1, requestedFps)))

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: COMMAND, description: 'Show the device amoo drives in a live pane' })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await stopMirror()
    return next(e)
  })

  on('command.run', { command: COMMAND }, async $ => {
    const opened = await $.ui.open({ id: PANE, title: 'amoo live' })
    const current = await read($, session)
    if (opened.isPlaced && current) startMirror($, current)
    return { text: current ? 'amoo live pane opened.' : 'amoo live pane opened; it fills in once start_session runs.' }
  }).catch(() => ({ text: 'amoo live pane could not open.' }))

  on('ui.close', async ($, e, next) => {
    if (e.id === PANE) await stopMirror()
    return next(e)
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    const tool = amooToolName(String(e.tool))
    if (!tool) return next(e)
    const input = e as unknown as Input
    const ran = await next(e)
    if (ran.deny !== undefined) return ran

    const isOk = ran.isError !== true
    if (!UNLISTED.has(tool)) {
      const action: AmooLiveAction = { id: e.tool_use_id, tool, summary: describeAction(tool, input), isOk }
      await update($, actions, list => [...list, action].slice(-MAX_ACTIONS))
    }

    if (tool === 'start_session' && isOk) {
      const started = startedSession(ran.result, ran.text)
      if (started) {
        await update($, session, () => started)
        await update($, actions, () => [])
        await update($, frame, () => null)
        await update($, mirrorError, () => null)
        failedSessionId = undefined
        $.ui.status(statusLine(started))
        const opened = await $.ui.open({ id: PANE, title: 'amoo live' })
        if (opened.isPlaced) {
          startMirror($, started)
        } else {
          $.ui.log(`amoo-live: pane not placed: ${opened.reason}`, { to: 'debug' })
          if (hintedSessionId !== started.sessionId) {
            hintedSessionId = started.sessionId
            $.ui.toast('amoo live: pane hidden (terminal under 144 columns). Run /amoo-live to show it.')
          }
        }
      }
    } else if (tool === 'end_session' && isOk) {
      const health = text(structured(ran.result)?.recording_health)
      const ended = await update($, session, current => (current ? { ...current, recordingHealth: health ?? current.recordingHealth } : current))
      await stopMirror()
      $.ui.status(statusLine(ended, true))
      if (health === 'failed') $.ui.toast('amoo: recording failed; the session artifacts may be incomplete')
    } else if (tool.startsWith('assert_') && !isOk) {
      const reason = (ran.text ?? '').split('\n')[0]
      $.ui.toast(`amoo: ${describeAction(tool, input)} failed${reason ? `: ${clip(reason, 80)}` : ''}`)
    }
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const current = await read($, session)
    const list = await read($, actions)
    const latest = await read($, frame)
    const failure = await read($, mirrorError)
    if (current && e.surface === 'terminal') startMirror($, current)
    const columns = e.props.bodyColumns
    const bodyRows = e.props.scroll?.bodyRows ?? e.viewport?.rows ?? 24
    const listed = list.slice(-Math.min(8, Math.max(3, Math.floor(bodyRows / 5))))
    const imageRows = Math.max(4, bodyRows - listed.length - 4)

    let picture = null
    if (e.surface === 'terminal' && latest) {
      const { Image } = $.ui.resolve(e)
      const size = fitImage(latest.width ?? 9, latest.height ?? 19.5, columns, imageRows)
      picture = (
        <Image
          key="mirror"
          source={{ file: latest.path, format: 'png', generation: latest.frame }}
          columns={size.columns}
          rows={size.rows}
          alt="Device mirror: needs a terminal with the kitty graphics protocol (Ghostty, kitty)"
        />
      )
    }

    return (
      <Box flexDirection="column">
        {current ? (
          <Text bold>
            {current.platform} · {clip(current.appId, Math.max(8, columns - 20))}
          </Text>
        ) : (
          <Text dimColor>No amoo session yet. The pane follows the next start_session.</Text>
        )}
        {current && <Text dimColor>{clip(current.deviceId, columns)}</Text>}
        {picture}
        {current && !latest && !failure && <Text dimColor>Waiting for the first frame…</Text>}
        {failure && <Text color="red">mirror: {clip(failure, 200)}</Text>}
        {listed.map(action => (
          <Text dimColor={action.isOk} color={action.isOk ? undefined : 'red'}>
            {action.isOk ? '✓' : '✗'} {clip(action.summary, Math.max(8, columns - 2))}
          </Text>
        ))}
      </Box>
    )
  })
}
