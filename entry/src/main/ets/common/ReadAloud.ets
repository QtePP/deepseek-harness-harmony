import { textToSpeech } from '@kit.CoreSpeechKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Read a reply out loud with the system voice.
 *
 * Same kit as speech recognition (`hms/ets/kits/@kit.CoreSpeechKit`), same
 * rules: check the capability with `canIUse` instead of assuming it, and keep
 * no engine alive between uses — it owns the audio focus, so a leftover engine
 * would mute other apps or keep speaking after the user moved on.
 */

/** Whether this device can synthesise speech. */
export function speechOutputSupported(): boolean {
  try {
    return canIUse('SystemCapability.AI.TextToSpeech')
  } catch (error) {
    return false
  }
}

/**
 * Strip what a voice should not read.
 *
 * A reply is Markdown plus tool chatter: reading `**`, fence markers and
 * backticks aloud is worse than silence. This is a reading filter, not a
 * parser — it only removes characters that have no spoken form.
 */
export function spokenForm(text: string): string {
  return text
    .replace(/```[\s\S]*?```/g, '（代码略）')
    .replace(/`([^`\n]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/^[-*]\s+/gm, '')
    .replace(/\s+/g, ' ')
    .trim()
}

export class ReadAloud {
  private engine: textToSpeech.TextToSpeechEngine | null = null
  private speaking: boolean = false

  /** True while a reply is being read; callers use it to toggle the label. */
  isSpeaking(): boolean {
    return this.speaking
  }

  /**
   * Speak `text`, replacing anything already playing.
   *
   * `onDone` fires on completion and on failure alike, so the caller can drop
   * its "speaking" state without a second error path.
   */
  speak(text: string, onDone: (error: string) => void): void {
    if (!speechOutputSupported()) {
      onDone('本机不支持语音朗读')
      return
    }
    const body = spokenForm(text)
    if (body.length === 0) {
      onDone('')
      return
    }
    this.stop()
    const params: textToSpeech.CreateEngineParams = {
      language: 'zh-CN',
      person: 0,
      online: 0,
      extraParams: {}
    }
    try {
      textToSpeech.createEngine(params, (error: BusinessError, engine: textToSpeech.TextToSpeechEngine) => {
        if (error !== null && error !== undefined) {
          // Same shape as speech input: the syscap is advertised, the engine
          // still cannot construct (device log: "Create Engine Error!
          // engineNo 0") because the voice package is a separate download.
          onDone(`朗读引擎启动失败（${error.code}）：可能缺少系统语音包`)
          return
        }
        this.engine = engine
        this.speaking = true
        engine.setListener({
          onStart: (requestId: string, response: textToSpeech.StartResponse) => {},
          onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
            this.speaking = false
            this.release()
            onDone('')
          },
          onStop: (requestId: string, response: textToSpeech.StopResponse) => {
            this.speaking = false
          },
          onError: (requestId: string, errorCode: number, errorMessage: string) => {
            this.speaking = false
            this.release()
            onDone(`朗读失败（${errorCode}）`)
          }
        })
        try {
          // `speak` takes the request id plus an optional extra bag; the
          // callbacks live on the listener registered once per engine.
          engine.speak(body, { requestId: `read-${Date.now()}` })
        } catch (speakError) {
          this.speaking = false
          this.release()
          onDone('无法开始朗读')
        }
      })
    } catch (error) {
      this.speaking = false
      onDone('朗读引擎不可用')
    }
  }

  /** Stop immediately; safe to call when nothing is playing. */
  stop(): void {
    if (this.engine === null) {
      return
    }
    try {
      this.engine.stop()
    } catch (error) {
      // Already stopped.
    }
    this.speaking = false
    this.release()
  }

  private release(): void {
    if (this.engine === null) {
      return
    }
    try {
      this.engine.shutdown()
    } catch (error) {
      // Already shut down.
    }
    this.engine = null
  }
}
