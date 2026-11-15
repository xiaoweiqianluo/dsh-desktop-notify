/**
 * DeepSeek Harness desktop popup alerts.
 *
 * Watches the durable Session log for a finished turn, and the two interaction
 * waterfalls for a pending approval or question. Whenever the Harness window is
 * not the foreground window, a small card slides into the bottom-right corner
 * of the primary screen (the "chat message" pattern), then closes itself.
 *
 * The card is drawn by a short-lived Windows PowerShell process (card.ps1)
 * instead of the Windows notification platform: that platform refuses toasts
 * from processes without package identity, while a plain WinForms window works
 * on every Windows 10/11 installation. The card never takes focus.
 */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { basename, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const CARD_SCRIPT = fileURLToPath(new URL('./card.ps1', import.meta.url))

/** Process name of the packaged Desktop app, used to detect "already looking". */
const DEFAULT_APP_PROCESS = 'DeepSeek Harness'

const DEFAULTS = {
  /** Master switch for every notification. */
  enabled: true,
  /** Notify when a turn finishes normally. */
  notifyOnTurnEnd: true,
  /** Notify when a turn ends with an error. */
  notifyOnError: true,
  /** Notify when a tool call waits for approval. */
  notifyOnApproval: true,
  /** Notify when the agent asks a structured question. */
  notifyOnQuestion: true,
  /**
   * Also notify while the Harness window is focused. Meant for checking the
   * appearance; leaving it on defeats the purpose of the plugin.
   */
  notifyWhenFocused: false,
  /** Skip the system sound. */
  silent: false,
  /** Slide the card in from the right edge instead of showing it in place. */
  animate: true,
  /** How long a completion card stays visible. */
  cardDurationMs: 12000,
  /** How long a "waiting for you" card stays visible. */
  waitingDurationMs: 24000,
  /** Maximum characters of the reply preview on the card. */
  summaryChars: 90,
  /** Process name that counts as "the Harness is in front". */
  appProcessName: DEFAULT_APP_PROCESS,
  /** Card copy language: 'zh' or 'en'. */
  language: 'zh',
  /** Append card diagnostics to this file; empty keeps them out of the way. */
  logFile: '',
}

const COPY = {
  zh: {
    doneTitle: '✓ 任务完成',
    doneFallback: '这一轮已经结束，点击回到 DeepSeek Harness 查看结果。',
    errorTitle: '！任务出错',
    errorFallback: '这一轮以错误结束，点击回来查看详情。',
    maxTokensTitle: '… 输出被截断',
    maxTokensFallback: '已达到输出上限，点击回来继续这一轮。',
    blockedTitle: '！任务被阻止',
    blockedFallback: '这一轮被阻止结束，点击回来查看原因。',
    interruptedTitle: '… 会话被中断',
    interruptedFallback: '这一轮在中断后结束，点击回来检查。',
    abortedTitle: '… 任务已中止',
    abortedFallback: '这一轮被中止，点击回来查看。',
    approvalTitle: '⚠ 需要你的确认',
    approvalBody: '工具 {tool} 正在等待授权。',
    approvalFallbackBody: '有操作正在等待你的授权。',
    approvalReason: '原因：{reason}',
    approvalFooter: '{session} · 点击回到 DSH 处理',
    questionTitle: '？需要你回答',
    questionBody: '{question}',
    questionFallbackBody: 'Agent 正在等待你的回答。',
    questionCount: '共 {count} 个问题。',
    questionFooter: '{session} · 点击回到 DSH 回答',
    footerTime: '{session} · 用时 {duration}',
    footerNoTime: '{session} · 点击回到 DeepSeek Harness',
    seconds: '{n} 秒',
    minutes: '{n} 分 {s} 秒',
    unknownSession: '当前会话',
  },
  en: {
    doneTitle: '✓ Task finished',
    doneFallback: 'This turn is done. Click to return to DeepSeek Harness.',
    errorTitle: '! Task failed',
    errorFallback: 'This turn ended with an error. Click to see the details.',
    maxTokensTitle: '… Output truncated',
    maxTokensFallback: 'The output limit was reached. Click to continue this turn.',
    blockedTitle: '! Task blocked',
    blockedFallback: 'This turn ended blocked. Click to see why.',
    interruptedTitle: '… Session interrupted',
    interruptedFallback: 'This turn ended after an interruption. Click to check it.',
    abortedTitle: '… Task stopped',
    abortedFallback: 'This turn was stopped. Click to return.',
    approvalTitle: '⚠ Your confirmation is needed',
    approvalBody: 'Tool {tool} is waiting for authorization.',
    approvalFallbackBody: 'An action is waiting for your authorization.',
    approvalReason: 'Reason: {reason}',
    approvalFooter: '{session} · Click to handle it in DSH',
    questionTitle: '? Your answer is needed',
    questionBody: '{question}',
    questionFallbackBody: 'The agent is waiting for your answer.',
    questionCount: '{count} questions waiting.',
    questionFooter: '{session} · Click to answer in DSH',
    footerTime: '{session} · {duration}',
    footerNoTime: '{session} · Click to return to DeepSeek Harness',
    seconds: '{n}s',
    minutes: '{n}m {s}s',
    unknownSession: 'Current session',
  },
}

/**
 * Format one placeholder template.
 * @param template - text containing `{name}` placeholders.
 * @param values - replacement values by placeholder name.
 * @returns the formatted text.
 */
function fill(template, values) {
  return template.replace(/\{(\w+)\}/g, (match, key) => (key in values ? String(values[key]) : match))
}

/**
 * Concatenate the text blocks of one message into a single line.
 * @param message - a model message with content blocks.
 * @returns flat preview text, or an empty string.
 */
function textOf(message) {
  const content = Array.isArray(message?.content) ? message.content : []
  return content
    .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('\n')
    .trim()
}

/**
 * Collapse whitespace and clamp to a preview length.
 * @param text - raw text.
 * @param limit - maximum character count.
 * @returns the single-line preview.
 */
function preview(text, limit) {
  const flat = String(text ?? '').replace(/\s+/g, ' ').trim()
  if (flat.length <= limit) return flat
  return `${flat.slice(0, Math.max(1, limit - 1))}…`
}

/**
 * Render an elapsed duration for the card footer.
 * @param ms - elapsed milliseconds, or undefined when unknown.
 * @param copy - active copy table.
 * @returns the localized duration, or an empty string.
 */
function durationText(ms, copy) {
  if (!Number.isFinite(ms) || ms <= 0) return ''
  const seconds = Math.round(ms / 1000)
  if (seconds < 60) return fill(copy.seconds, { n: Math.max(1, seconds) })
  const minutes = Math.floor(seconds / 60)
  return fill(copy.minutes, { n: minutes, s: seconds % 60 })
}

/**
 * Resolve the PowerShell executable to launch.
 * @returns an absolute path when the default installation exists.
 */
function powershellPath() {
  const root = process.env.SystemRoot ?? 'C:\\Windows'
  const candidate = join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  return existsSync(candidate) ? candidate : 'powershell.exe'
}

/**
 * Install the notification listeners.
 * @param ctx - Host plugin context.
 * @param config - the row's `config` object from `cordis.patch.yml`.
 */
export function apply(ctx, config = {}) {
  const options = { ...DEFAULTS, ...(config ?? {}) }
  const copy = COPY[options.language] ?? COPY.zh
  const logger = ctx.logger?.('desktop-notify')

  if (process.platform !== 'win32') {
    logger?.warn?.('desktop popup alerts are Windows-only; no cards will be shown')
    return
  }

  /** per-session turn start and reply preview */
  const turns = new Map()

  const sessionLabel = (session) => {
    try {
      const title = ctx.get('sessionTitle')?.get?.(session)?.title
      if (title) return title
    } catch { /* title service unavailable or session not live */ }
    const cwd = session?.header?.cwd
    if (cwd) {
      const name = basename(cwd)
      if (name) return name
    }
    return copy.unknownSession
  }

  const showCard = (card) => {
    if (!options.enabled) return

    const env = {
      ...process.env,
      DSH_CARD_TITLE: card.title,
      DSH_CARD_BODY: card.body ?? '',
      DSH_CARD_FOOTER: card.footer ?? '',
      DSH_CARD_KIND: card.kind ?? 'done',
      DSH_CARD_DURATION: String(card.durationMs),
      DSH_CARD_TARGET: options.appProcessName,
      DSH_CARD_HOST_PID: String(process.ppid ?? 0),
      DSH_CARD_SILENT: options.silent ? '1' : '0',
      DSH_CARD_ANIMATE: options.animate ? '1' : '0',
      DSH_CARD_ALWAYS: options.notifyWhenFocused ? '1' : '0',
    }
    if (options.logFile) env.DSH_CARD_LOG = options.logFile

    try {
      const child = spawn(powershellPath(), [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', CARD_SCRIPT,
      ], {
        env,
        windowsHide: true,
        // Deliberately NOT detached: on Windows that flag means
        // DETACHED_PROCESS, and a console program started without a console
        // (here: Windows PowerShell) exits immediately without running anything.
        stdio: 'ignore',
      })
      child.on('error', (error) => {
        logger?.warn?.(`could not start the card: ${error instanceof Error ? error.message : String(error)}`)
      })
      child.unref()
    } catch (error) {
      logger?.warn?.(`could not start the card: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const notifyTurnEnd = (session, event) => {
    if (!options.notifyOnTurnEnd && !options.notifyOnError) return

    const reason = event?.data?.reason ?? { kind: 'completed' }
    const kind = reason.kind ?? 'completed'
    if (kind === 'forked') return
    if (kind === 'aborted' && reason.reason?.kind === 'user') return

    const state = turns.get(session.id) ?? {}
    const elapsed = Number.isFinite(state.startedAt) ? Date.now() - state.startedAt : undefined
    const summary = preview(state.reply ?? '', options.summaryChars)
    const duration = durationText(elapsed, copy)
    const name = sessionLabel(session)
    const footer = duration
      ? fill(copy.footerTime, { session: name, duration })
      : fill(copy.footerNoTime, { session: name })

    let card
    if (kind === 'error') {
      if (!options.notifyOnError) return
      const message = reason.error?.message ?? reason.error?.code ?? ''
      card = {
        title: copy.errorTitle,
        body: message ? preview(message, options.summaryChars) : copy.errorFallback,
        kind: 'error',
      }
    } else if (kind === 'completed') {
      if (!options.notifyOnTurnEnd) return
      card = { title: copy.doneTitle, body: summary || copy.doneFallback, kind: 'done' }
    } else if (kind === 'max-tokens') {
      card = { title: copy.maxTokensTitle, body: copy.maxTokensFallback, kind: 'muted' }
    } else if (kind === 'blocked') {
      card = { title: copy.blockedTitle, body: copy.blockedFallback, kind: 'muted' }
    } else if (kind === 'interrupted') {
      card = { title: copy.interruptedTitle, body: copy.interruptedFallback, kind: 'muted' }
    } else if (kind === 'aborted') {
      card = { title: copy.abortedTitle, body: copy.abortedFallback, kind: 'muted' }
    } else {
      return
    }

    showCard({ ...card, footer, durationMs: options.cardDurationMs })
  }

  const onSessionEvent = (session, event) => {
    try {
      if (!session || !event) return
      if (session.header?.origin === 'subagent') return
      if (event.type === 'turn/start') {
        turns.set(session.id, { startedAt: Date.now(), reply: '' })
        return
      }
      if (event.type === 'assistant/message') {
        const state = turns.get(session.id)
        const text = textOf(event.data?.message)
        if (state) state.reply = text || state.reply
        return
      }
      if (event.type === 'turn/end') {
        notifyTurnEnd(session, event)
        turns.delete(session.id)
      }
    } catch (error) {
      logger?.warn?.(`turn notification failed: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  const onApproval = (request, next) => {
    try {
      if (options.enabled && options.notifyOnApproval) {
        const reason = request?.displayReason?.[options.language]
          ?? request?.displayReason?.en
          ?? request?.reason
          ?? ''
        const reasonLine = reason ? fill(copy.approvalReason, { reason: preview(reason, options.summaryChars) }) : ''
        const body = request?.toolName
          ? fill(copy.approvalBody, { tool: request.toolName })
          : copy.approvalFallbackBody
        const session = request?.agent ? ctx.get('sessions')?.get?.(request.agent.id) : undefined
        const name = session ? sessionLabel(session) : copy.unknownSession
        showCard({
          title: copy.approvalTitle,
          body: reasonLine ? `${body}\n${reasonLine}` : body,
          footer: fill(copy.approvalFooter, { session: name }),
          kind: 'wait',
          durationMs: options.waitingDurationMs,
        })
      }
    } catch (error) {
      logger?.warn?.(`approval card failed: ${error instanceof Error ? error.message : String(error)}`)
    }
    return next()
  }

  const onQuestion = (request, next) => {
    try {
      if (options.enabled && options.notifyOnQuestion) {
        const questions = Array.isArray(request?.questions) ? request.questions : []
        const first = questions[0]
        const text = typeof first?.question === 'string' ? first.question : ''
        const count = questions.length > 1 ? fill(copy.questionCount, { count: questions.length }) : ''
        const body = text
          ? (count ? `${preview(text, options.summaryChars)}\n${count}` : preview(text, options.summaryChars))
          : copy.questionFallbackBody
        const session = request?.agent ? ctx.get('sessions')?.get?.(request.agent.id) : undefined
        const name = session ? sessionLabel(session) : copy.unknownSession
        showCard({
          title: copy.questionTitle,
          body,
          footer: fill(copy.questionFooter, { session: name }),
          kind: 'wait',
          durationMs: options.waitingDurationMs,
        })
      }
    } catch (error) {
      logger?.warn?.(`question card failed: ${error instanceof Error ? error.message : String(error)}`)
    }
    return next()
  }

  // A finished turn reaches a plugin-level listener: `session/event` fans out to
  // every context. The two interaction waterfalls are claimed by the answerer
  // that returns the decision without calling `next()`, so an observer has to be
  // prepended: run first, notify, then delegate the request unchanged.
  ctx.effect(() => {
    const disposers = [
      ctx.on('session/event', onSessionEvent),
      ctx.on('approval/request', onApproval, { prepend: true, global: true }),
      ctx.on('user-questions/request', onQuestion, { prepend: true, global: true }),
    ]
    return () => {
      for (const dispose of disposers) {
        try { dispose?.() } catch { /* already disposed */ }
      }
      turns.clear()
    }
  }, 'desktop-notify: listeners')

  logger?.info?.('desktop popup alerts ready')
}
