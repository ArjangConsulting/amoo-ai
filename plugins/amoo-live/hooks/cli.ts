import type { Input } from './model'

/** One amoo CLI invocation found in a Bash command. */
export type AmooCall =
  | { kind: 'up'; platform?: string; appId?: string; device?: string; json: boolean; piped: boolean }
  | { kind: 'down'; runtimeId?: string; json: boolean; piped: boolean }
  | { kind: 'device'; runtimeId?: string; tool: string; input: Input; json: boolean; piped: boolean }
  | { kind: 'flow'; runtimeId?: string; file?: string; outputDir?: string; piped: boolean }

type Token = { word: string; unresolved: boolean }
type Segment = { tokens: Token[]; piped: boolean; runtimeId?: string }

const OPERATORS = ['&&', '||', ';;', ';', '|', '&', '\n']
const VALUE_FLAGS = new Set([
  '--platform',
  '--port',
  '--device',
  '--runtime-id',
  '--arguments-json',
  '--arg',
  '--env',
  '--app-id',
  '--app',
  '--avd',
  '--output-dir',
  '--timeout',
  '--owner',
])
const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s

/**
 * Splits a shell command into segments of words, honouring quotes, and expands `$NAME` from
 * assignments earlier in the same command. A word that names a variable it cannot resolve is
 * marked, so a runtime id held in an unknown variable is never mistaken for a literal one.
 */
function segments(command: string): Segment[] {
  const vars: Record<string, string> = {}
  const out: Segment[] = []
  let tokens: Token[] = []
  let word = ''
  let started = false
  let unresolved = false
  let quote: '"' | "'" | undefined

  const expand = (source: string, at: number): [string, number] => {
    const braced = source[at + 1] === '{'
    const match = /^[A-Za-z_][A-Za-z0-9_]*/.exec(source.slice(at + (braced ? 2 : 1)))
    if (!match) return ['$', at + 1]
    const end = at + (braced ? 2 : 1) + match[0].length + (braced ? 1 : 0)
    const value = vars[match[0]]
    if (value === undefined) unresolved = true
    return [value ?? '', end]
  }
  const endWord = () => {
    if (started) tokens.push({ word, unresolved })
    word = ''
    started = false
    unresolved = false
  }
  const endSegment = (piped: boolean) => {
    endWord()
    if (tokens.length) {
      const assignments = tokens.filter((token, index) => tokens.slice(0, index + 1).every((t) => ASSIGNMENT.test(t.word)))
      const rest = tokens.slice(assignments.length)
      const exported = rest[0]?.word === 'export' ? rest.slice(1) : []
      for (const token of [...assignments, ...exported]) {
        const [, name, value] = ASSIGNMENT.exec(token.word) ?? []
        if (name && !token.unresolved) vars[name] = value ?? ''
      }
      if (rest.length && rest[0]?.word !== 'export') {
        const prefixed = assignments.find((token) => token.word.startsWith('AMOO_RUNTIME_ID='))
        const runtimeId = prefixed
          ? prefixed.unresolved
            ? undefined
            : prefixed.word.slice('AMOO_RUNTIME_ID='.length)
          : vars.AMOO_RUNTIME_ID
        out.push({ tokens: rest, piped, runtimeId: runtimeId || undefined })
      }
    }
    tokens = []
  }

  for (let index = 0; index < command.length; ) {
    const char = command[index]!
    if (quote === "'") {
      if (char === "'") quote = undefined
      else word += char
      index += 1
      continue
    }
    if (quote === '"') {
      if (char === '"') {
        quote = undefined
        index += 1
      } else if (char === '\\' && index + 1 < command.length) {
        word += command[index + 1]
        index += 2
      } else if (char === '$') {
        const [value, end] = expand(command, index)
        word += value
        index = end
      } else {
        word += char
        index += 1
      }
      continue
    }
    if (char === "'" || char === '"') {
      quote = char
      started = true
      index += 1
      continue
    }
    if (char === '\\' && index + 1 < command.length) {
      if (command[index + 1] !== '\n') {
        word += command[index + 1]
        started = true
      }
      index += 2
      continue
    }
    const operator = OPERATORS.find((candidate) => command.startsWith(candidate, index))
    if (operator) {
      endSegment(operator === '|')
      index += operator.length
      continue
    }
    if (char === ' ' || char === '\t') {
      endWord()
      index += 1
      continue
    }
    if (char === '$') {
      const [value, end] = expand(command, index)
      word += value
      started = true
      index = end
      continue
    }
    word += char
    started = true
    index += 1
  }
  endSegment(false)
  return out
}

function isAmoo(token: Token | undefined): boolean {
  if (!token || token.unresolved) return false
  return token.word === 'amoo' || token.word.endsWith('/amoo')
}

/** The words after the amoo executable, or undefined when the segment runs something else. */
function amooArguments(tokens: Token[]): Token[] | undefined {
  if (isAmoo(tokens[0])) return tokens.slice(1)
  if (tokens[0]?.word === 'swift' && tokens[1]?.word === 'run' && tokens[2]?.word === 'amoo') return tokens.slice(3)
  return undefined
}

type Parsed = { flags: Map<string, Token>; switches: Set<string>; positionals: Token[]; pairs: Token[] }

function parse(words: Token[]): Parsed {
  const flags = new Map<string, Token>()
  const switches = new Set<string>()
  const positionals: Token[] = []
  const pairs: Token[] = []
  for (let index = 0; index < words.length; index += 1) {
    const token = words[index]!
    const inline = /^(--[a-z-]+)=(.*)$/s.exec(token.word)
    if (inline) {
      flags.set(inline[1]!, { word: inline[2] ?? '', unresolved: token.unresolved })
    } else if (VALUE_FLAGS.has(token.word) && index + 1 < words.length) {
      const value = words[index + 1]!
      if (token.word === '--arg') pairs.push(value)
      else flags.set(token.word, value)
      index += 1
    } else if (token.word.startsWith('--')) {
      switches.add(token.word)
    } else {
      positionals.push(token)
    }
  }
  return { flags, switches, positionals, pairs }
}

function value(token: Token | undefined): string | undefined {
  return token && !token.unresolved && token.word.length > 0 ? token.word : undefined
}

function toolInput(parsed: Parsed, rest: Token[]): Input {
  const input: Input = {}
  const inline = value(parsed.flags.get('--arguments-json'))
  if (inline?.startsWith('{')) {
    try {
      Object.assign(input, JSON.parse(inline))
    } catch {
      // A malformed inline argument object only loses the action's description.
    }
  }
  for (const pair of [...rest, ...parsed.pairs]) {
    const separator = pair.word.indexOf('=')
    if (separator > 0) input[pair.word.slice(0, separator)] = pair.word.slice(separator + 1)
  }
  return input
}

/** Every amoo invocation the pane follows in one Bash command, in order. */
export function amooCalls(command: string): AmooCall[] {
  const calls: AmooCall[] = []
  for (const segment of segments(command)) {
    const words = amooArguments(segment.tokens)
    if (!words?.length) continue
    const [verb, ...afterVerb] = words
    const parsed = parse(afterVerb)
    const json = parsed.switches.has('--json')
    const flagged = parsed.flags.get('--runtime-id')
    const runtimeId = flagged ? value(flagged) : segment.runtimeId
    if (verb?.word === 'env' && parsed.positionals[0]?.word === 'up') {
      calls.push({
        kind: 'up',
        platform: value(parsed.flags.get('--platform')),
        appId: value(parsed.flags.get('--app-id')),
        device: value(parsed.flags.get('--device')),
        json,
        piped: segment.piped,
      })
    } else if (verb?.word === 'env' && parsed.positionals[0]?.word === 'down') {
      calls.push({ kind: 'down', runtimeId, json, piped: segment.piped })
    } else if (verb?.word === 'device') {
      const [tool, ...rest] = parsed.positionals
      if (!tool || tool.unresolved || !/^[a-z_]+$/.test(tool.word) || tool.word === 'stream') continue
      calls.push({ kind: 'device', runtimeId, tool: tool.word, input: toolInput(parsed, rest), json, piped: segment.piped })
    } else if (verb?.word === 'flow' && !['list', 'validate'].includes(parsed.positionals[0]?.word ?? '')) {
      calls.push({
        kind: 'flow',
        runtimeId,
        file: value(parsed.positionals[0]),
        outputDir: value(parsed.flags.get('--output-dir')),
        piped: segment.piped,
      })
    }
  }
  return calls
}

/** The last JSON object a command printed, the shape every `--json` amoo command ends with. */
export function lastJSONObject(stdout: string): Input | undefined {
  const trimmed = stdout.trim()
  for (let start = trimmed.lastIndexOf('\n{'); ; start = trimmed.lastIndexOf('\n{', start - 1)) {
    const candidate = start < 0 ? trimmed : trimmed.slice(start + 1)
    try {
      const parsed: unknown = JSON.parse(candidate)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed as Input
    } catch {
      // Not the start of the final object; look further back.
    }
    if (start < 0) return undefined
  }
}
