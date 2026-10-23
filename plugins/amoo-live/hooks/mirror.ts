import type { EngineInterface, RenderSurface } from 'claude-code'

import { changeSession, selectedSession, text, readView } from './model'
import type { Input } from './model'

type Child = AsyncGenerator<{ stream: string; text: string }, { code: number | null; signal: string | null }>
type Mirror = { sessionId: string; child: Child }

export type MirrorController = {
  amooPath: string
  fps: string
  mirror?: Mirror
  terminalVisible: boolean
  paneOpen: boolean
  shuttingDown: boolean
  queued: Promise<void>
  renderScheduled: boolean
}

/** Owns a single capture process and rejects output from replaced or stopped streams. */
export function createMirrorController(amooPath: string, fps: string): MirrorController {
  return {
    amooPath,
    fps,
    terminalVisible: false,
    paneOpen: false,
    shuttingDown: false,
    queued: Promise.resolve(),
    renderScheduled: false,
  }
}

async function stop($: EngineInterface, controller: MirrorController) {
  const running = controller.mirror
  if (!running) return
  controller.mirror = undefined
  try {
    await running.child.return(undefined as never)
  } finally {
    await changeSession($, running.sessionId, (current) => ({ ...current, frame: null }))
  }
}

async function failed($: EngineInterface, controller: MirrorController, own: Mirror, message: string) {
  if (controller.mirror !== own) return
  controller.mirror = undefined
  await changeSession($, own.sessionId, (current) =>
    current.phase === 'running' && !current.paused
      ? { ...current, frame: null, mirrorState: 'failed', mirrorError: message }
      : current,
  )
}

async function applyLine(
  $: EngineInterface,
  controller: MirrorController,
  own: Mirror,
  line: string,
): Promise<boolean> {
  let event: Input
  try {
    event = JSON.parse(line) as Input
  } catch {
    return false
  }
  if (event === null || typeof event !== 'object' || typeof event.event !== 'string') return false
  if (controller.mirror !== own) return true
  if (event.event === 'frame' && typeof event.path === 'string' && typeof event.frame === 'number') {
    const next = {
      path: event.path,
      frame: event.frame,
      width: typeof event.width === 'number' ? event.width : undefined,
      height: typeof event.height === 'number' ? event.height : undefined,
      receivedAt: Date.now(),
      elapsedMs: typeof event.elapsed_ms === 'number' ? event.elapsed_ms : undefined,
    }
    await changeSession($, own.sessionId, (current) =>
      controller.mirror === own && current.phase === 'running' && !current.paused
        ? { ...current, frame: next, mirrorError: null }
        : current,
    )
  } else if (event.event === 'error' || (event.event === 'stopped' && text(event.message))) {
    await changeSession($, own.sessionId, (current) =>
      controller.mirror === own
        ? { ...current, mirrorError: text(event.message) ?? 'capture failed' }
        : current,
    )
  }
  return true
}

async function follow($: EngineInterface, controller: MirrorController, own: Mirror) {
  const pending = { stdout: '', stderr: '' }
  let lastOutput = ''
  try {
    while (controller.mirror === own) {
      const step = await own.child.next()
      if (controller.mirror !== own) return
      if (step.done) {
        const ending = step.value.signal ? `signal ${step.value.signal}` : String(step.value.code)
        const remaining = `${pending.stderr || pending.stdout}`.trim()
        const detail = remaining || lastOutput
        await failed(
          $,
          controller,
          own,
          `${controller.amooPath} device stream exited with ${ending}${detail ? `: ${detail}` : ''}`,
        )
        return
      }
      const stream = step.value.stream === 'stderr' ? 'stderr' : 'stdout'
      pending[stream] += step.value.text
      let newline = pending[stream].indexOf('\n')
      while (newline >= 0 && controller.mirror === own) {
        const line = pending[stream].slice(0, newline).trim()
        pending[stream] = pending[stream].slice(newline + 1)
        if (line && !(stream === 'stdout' && (await applyLine($, controller, own, line)))) lastOutput = line
        newline = pending[stream].indexOf('\n')
      }
      pending[stream] = pending[stream].slice(-65536)
    }
  } catch {
    await failed($, controller, own, `could not run ${controller.amooPath} device stream`)
  }
}

async function reconcile($: EngineInterface, controller: MirrorController) {
  let current = selectedSession(await readView($))
  const panes = controller.terminalVisible && !controller.shuttingDown ? await $.ui.panes() : []
  const paneVisible = panes.some((pane) => pane.id === 'amoo-live' && pane.isPlaced && pane.isShown)
  const wanted = () =>
    paneVisible &&
    controller.paneOpen &&
    controller.terminalVisible &&
    !controller.shuttingDown &&
    current?.phase === 'running' &&
    !current.paused &&
    current.mirrorState !== 'failed'
  if (wanted() && controller.mirror?.sessionId === current?.sessionId) return
  await stop($, controller)
  current = selectedSession(await readView($))
  if (!wanted() || !current) return
  const own: Mirror = {
    sessionId: current.sessionId,
    child: $.process.spawn({
      argv: [
        controller.amooPath,
        'device',
        'stream',
        '--platform',
        current.platform,
        '--device',
        current.deviceId,
        '--fps',
        controller.fps,
      ],
    }),
  }
  controller.mirror = own
  await changeSession($, current.sessionId, (item) => ({
    ...item,
    frame: null,
    mirrorState: 'running',
    mirrorError: null,
  }))
  void follow($, controller, own).catch(() =>
    $.ui.log('amoo-live: could not update mirror state', { to: 'debug' }),
  )
}

export function synchronizeMirror($: EngineInterface, controller: MirrorController) {
  const next = controller.queued.then(() => reconcile($, controller))
  controller.queued = next.catch(() => $.ui.log('amoo-live: could not synchronize mirror', { to: 'debug' }))
  return next
}

export function scheduleMirror($: EngineInterface, surface: RenderSurface, controller: MirrorController) {
  if (surface !== 'terminal' || !controller.paneOpen) return
  controller.terminalVisible = true
  if (controller.renderScheduled) return
  controller.renderScheduled = true
  $.clock.after(0, async () => {
    controller.renderScheduled = false
    await synchronizeMirror($, controller)
  })
}

export async function closeMirror($: EngineInterface, controller: MirrorController) {
  controller.paneOpen = false
  controller.terminalVisible = false
  await synchronizeMirror($, controller)
}

export async function shutdownMirror($: EngineInterface, controller: MirrorController) {
  controller.shuttingDown = true
  await closeMirror($, controller)
}
