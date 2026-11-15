import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { speechRecognizer } from '@kit.CoreSpeechKit'
import { BusinessError } from '@kit.BasicServicesKit'

/**
 * Offline speech-to-text for the composer.
 *
 * HarmonyOS ships CoreSpeechKit in the HMS SDK (`hms/ets/kits`), which is a
 * different directory from the OpenHarmony kits — that is why an earlier note
 * in this repo wrongly recorded voice input as impossible.
 *
 * Two rules shape this file:
 *
 *   1. Capability is checked at runtime with `canIUse`, never assumed. A device
 *      without `SystemCapability.AI.SpeechRecognizer` must hide the microphone
 *      rather than offer a button that throws.
 *   2. The engine is created lazily and released after each utterance. It holds
 *      the microphone; leaving it alive keeps the input device busy and drains
 *      the battery between the rare moments someone actually speaks.
 */

/** What the caller sees while dictating. */
export interface SpeechCallbacks {
  /** Interim text, replacing whatever was shown last. */
  onPartial: (text: string) => void
  /** Final text for this utterance. */
  onFinal: (text: string) => void
  /** Non-recoverable failure; the caller shows the message and hides the button. */
  onError: (message: string) => void
}

/** Whether this device can do offline Chinese speech recognition. */
export function speechSupported(): boolean {
  try {
    return canIUse('SystemCapability.AI.SpeechRecognizer')
  } catch (error) {
    return false
  }
}

/**
 * Ask for the microphone, once.
 *
 * `requestPermissionsFromUser` shows nothing when the user already answered, so
 * a denied permission surfaces as `false` rather than as a dialog on every tap.
 */
export async function requestMicPermission(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const manager = abilityAccessCtrl.createAtManager()
    const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE'])
    return result.authResults.length > 0 && result.authResults[0] === 0
  } catch (error) {
    return false
  }
}

export class SpeechInput {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null
  private listening: boolean = false
  /** The id of the utterance in flight; `finish()` requires it back. */
  private sessionId: string = ''

  /**
   * Start one utterance.
   *
   * `sessionId` only has to be unique per utterance; the engine uses it to tie
   * callbacks back to this request.
   */
  start(callbacks: SpeechCallbacks): void {
    if (!speechSupported()) {
      callbacks.onError('本机不支持离线语音识别')
      return
    }
    if (this.listening) {
      return
    }
    const params: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      online: 0,
      extraParams: {}
    }
    try {
      speechRecognizer.createEngine(params, (error: BusinessError, engine: speechRecognizer.SpeechRecognitionEngine) => {
        if (error !== null && error !== undefined) {
          // The syscap can be present while the offline Chinese model is not:
          // the engine then fails to construct (device log: "Failed to create
          // engine [callback]"). Say what is missing instead of a bare code —
          // the fix is on the system side, not in this app.
          callbacks.onError(`语音引擎启动失败（${error.code}）：可能缺少离线中文语音包`)
          return
        }
        this.engine = engine
        this.bind(engine, callbacks)
        try {
          this.sessionId = `dsh-${Date.now()}`
          // PCM 16 kHz mono is the only shape the offline engine accepts; the
          // channel is 1 (mono) and the type names the encoding, not a file.
          engine.startListening({
            sessionId: this.sessionId,
            audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 }
          })
          this.listening = true
        } catch (startError) {
          this.release()
          callbacks.onError('无法开始录音')
        }
      })
    } catch (error) {
      callbacks.onError('语音引擎不可用')
    }
  }

  /** Stop early and keep whatever was recognised so far. */
  stop(): void {
    if (this.engine === null || !this.listening) {
      return
    }
    try {
      this.engine.finish(this.sessionId)
    } catch (error) {
      // A finish on a finished engine is not worth reporting.
    }
    this.listening = false
  }

  /** Drop the engine and free the microphone. */
  release(): void {
    if (this.engine === null) {
      return
    }
    try {
      this.engine.shutdown()
    } catch (error) {
      // Already shut down.
    }
    this.engine = null
    this.listening = false
  }

  private bind(engine: speechRecognizer.SpeechRecognitionEngine, callbacks: SpeechCallbacks): void {
    engine.setListener({
      onStart: (sessionId: string, eventMessage: string) => {},
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {},
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        const text = result.result
        if (result.isFinal) {
          callbacks.onFinal(text)
          this.release()
        } else {
          callbacks.onPartial(text)
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
        this.release()
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        this.release()
        callbacks.onError(`识别失败（${errorCode}）`)
      }
    })
  }
}
