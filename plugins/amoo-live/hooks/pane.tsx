import type { EngineInterface, RenderInput } from 'claude-code'

import {
  changeSession,
  clip,
  duration,
  fitImage,
  selectedSession,
  statusLine,
  readView,
  updateView,
} from './model'
import { closeMirror, scheduleMirror, synchronizeMirror } from './mirror'
import type { MirrorController } from './mirror'

/** Draws the selected session and exposes controls that never mutate the device under test. */
export async function renderPane(
  $: EngineInterface,
  e: RenderInput<'Pane'>,
  mirror: MirrorController,
  amooPath: string,
) {
  const { Box, Text, Button } = $.ui.resolve(e)
  const state = await readView($)
  const current = selectedSession(state)
  const columns = e.props.bodyColumns
  const bodyRows = e.props.scroll?.bodyRows ?? e.viewport?.rows ?? 24
  const listed = current?.actions.slice(-Math.min(8, Math.max(3, Math.floor(bodyRows / 5)))) ?? []
  const selectorRows = state.sessions.length > 1 ? state.sessions.length : 0
  const artifactRows =
    2 * Number(Boolean(current?.planPath)) +
    2 * Number(Boolean(current?.flowPath)) +
    Number(Boolean(current?.artifactError)) +
    Number(current?.actionCount !== undefined) +
    Number(Boolean(current?.warningCount))
  const imageRows = Math.max(
    1,
    bodyRows - listed.length - selectorRows - artifactRows - state.startups.length - 7,
  )
  const now = Date.now()
  if (current) scheduleMirror($, e.surface, mirror)

  async function select(sessionId: string) {
    const next = await updateView($, (previous) => ({ ...previous, selectedId: sessionId }))
    $.ui.status(statusLine(selectedSession(next)))
    await synchronizeMirror($, mirror)
  }

  async function capture(paused: boolean) {
    if (!current || current.phase !== 'running') return
    const next = await changeSession($, current.sessionId, (previous) =>
      previous.phase === 'running'
        ? { ...previous, paused, mirrorState: 'idle', mirrorError: null }
        : previous,
    )
    $.ui.status(statusLine(selectedSession(next)))
    await synchronizeMirror($, mirror)
  }

  let picture = null
  if (e.surface === 'terminal' && current?.frame) {
    const { Image } = $.ui.resolve(e)
    const latest = current.frame
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
      {state.sessions.length > 1 &&
        state.sessions.map((item) => (
          <Button
            key={`session-${item.sessionId}`}
            plain
            label={clip(
              `${item.sessionId === state.selectedId ? '●' : '○'} ${item.appId} · ${item.deviceId} · ${item.phase}`,
              columns,
            )}
            onPress={() => select(item.sessionId)}
          />
        ))}
      {state.startups.map((item) => (
        <Text key={`startup-${item.id}`} color={item.state === 'pending' ? undefined : 'red'}>
          {item.state === 'pending'
            ? 'Starting'
            : item.state === 'denied'
              ? 'Startup denied:'
              : 'Startup failed:'}{' '}
          {clip(item.appId, columns - 20)}
          {item.state === 'pending' ? ` · ${duration(now - item.startedAt)}` : ''}
        </Text>
      ))}
      {current ? (
        <Text bold>
          {current.platform} · {clip(current.appId, Math.max(8, columns - 20))}
        </Text>
      ) : (
        <Text dimColor>No amoo session yet. The pane follows the next start_session.</Text>
      )}
      {current && <Text dimColor>{clip(current.deviceId, columns)}</Text>}
      {current && (
        <Text key="session-status">
          {current.phase === 'ended'
            ? 'Ended'
            : current.paused
              ? 'Paused'
              : current.mirrorState === 'failed'
                ? 'Mirror failed'
                : 'Running'}
          {current.recordingHealth ? ` · rec ${current.recordingHealth}` : ''}
        </Text>
      )}
      {current?.phase === 'running' && e.surface === 'terminal' && (
        <Button
          key="capture"
          label={
            current.paused
              ? 'Resume mirror'
              : current.mirrorState === 'failed'
                ? 'Retry mirror'
                : 'Pause mirror'
          }
          onPress={() => capture(!current.paused && current.mirrorState !== 'failed')}
        />
      )}
      {picture}
      {current?.frame && e.surface === 'terminal' && (
        <Text dimColor>
          Frame {current.frame.frame + 1} · {duration(now - current.frame.receivedAt)} ago
          {current.frame.elapsedMs && current.frame.frame > 0
            ? ` · ${((current.frame.frame * 1000) / current.frame.elapsedMs).toFixed(1)} fps`
            : ''}
        </Text>
      )}
      {current?.phase === 'running' && e.surface !== 'terminal' && (
        <Text dimColor>
          Live pictures need Ghostty or kitty; session actions and artifacts are available here.
        </Text>
      )}
      {current?.phase === 'running' &&
        !current.paused &&
        !current.frame &&
        !current.mirrorError &&
        e.surface === 'terminal' && (
          <Text dimColor>Mirror: running `{amooPath} device stream`, waiting for the first frame…</Text>
        )}
      {current?.mirrorError && <Text color="red">mirror: {clip(current.mirrorError, 200)}</Text>}
      {listed.map((action) => (
        <Text
          key={action.id}
          dimColor={action.state === 'succeeded'}
          color={action.state === 'failed' || action.state === 'denied' ? 'red' : undefined}
        >
          {action.state === 'pending' ? '…' : action.state === 'succeeded' ? '✓' : '✗'}{' '}
          {clip(action.summary, Math.max(8, columns - 14))}
          {action.state === 'pending'
            ? ` · ${duration(now - action.startedAt)}`
            : action.durationMs !== undefined
              ? ` · ${duration(action.durationMs)}`
              : ''}
        </Text>
      ))}
      {current?.actionCount !== undefined && (
        <Text>
          {current.actionCount} recorded action(s)
          {current.warningCount !== undefined ? ` · ${current.warningCount} generation warning(s)` : ''}
        </Text>
      )}
      {current?.planPath && (
        <Button
          key="copy-plan"
          label="Copy plan path"
          onPress={() => $.ui.copy({ text: current.planPath!, surface: e.surface })}
        />
      )}
      {current?.planPath && <Text dimColor>{current.planPath}</Text>}
      {current?.flowPath && (
        <Button
          key="copy-flow"
          label="Copy flow path"
          onPress={() => $.ui.copy({ text: current.flowPath!, surface: e.surface })}
        />
      )}
      {current?.flowPath && <Text dimColor>{current.flowPath}</Text>}
      {current?.warningCount !== undefined && current.warningCount > 0 && (
        <Text color="yellow">Inspect plan warnings before generating a test.</Text>
      )}
      {current?.artifactError && <Text color="red">Artifacts: {clip(current.artifactError, 200)}</Text>}
      <Button
        key="close-pane"
        label="Close pane"
        onPress={async () => {
          await closeMirror($, mirror)
          await $.ui.close({ id: 'amoo-live' })
        }}
      />
    </Box>
  )
}
