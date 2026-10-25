package com.amoo.companion.accessibility

import android.media.AudioFormat
import android.speech.tts.SynthesisCallback
import android.speech.tts.SynthesisRequest
import android.speech.tts.TextToSpeech
import android.speech.tts.TextToSpeechService
import android.speech.tts.Voice
import org.json.JSONObject
import java.io.File
import java.util.Locale

/** Test-only TTS engine recording actual synthesis requests from the qualified TalkBack UID. */
class SpeechCaptureEngine : TextToSpeechService() {
    override fun onIsLanguageAvailable(lang: String?, country: String?, variant: String?): Int =
        TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE

    override fun onGetLanguage(): Array<String> = arrayOf("eng", "USA", "")

    override fun onLoadLanguage(lang: String?, country: String?, variant: String?): Int =
        TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE

    override fun onStop() = Unit

    override fun onGetVoices(): List<Voice> = listOf(Voice(
        "amoo-capture", Locale.US, Voice.QUALITY_NORMAL, Voice.LATENCY_VERY_LOW, false, emptySet()
    ))

    override fun onGetDefaultVoiceNameFor(lang: String?, country: String?, variant: String?): String = "amoo-capture"

    override fun onIsValidVoiceName(voiceName: String?): Int =
        if (voiceName == "amoo-capture") TextToSpeech.SUCCESS else TextToSpeech.ERROR

    override fun onLoadVoice(voiceName: String?): Int = onIsValidVoiceName(voiceName)

    override fun onSynthesizeText(request: SynthesisRequest, callback: SynthesisCallback) {
        try {
            val markerFile = File(filesDir, "amoo-speech-capture.json")
            if (!markerFile.exists()) {
                callback.error()
                return
            }
            val marker = JSONObject(markerFile.readText())
            android.util.Log.i("AmooSpeechCapture", "synthesis_received uid=${request.callerUid} qualified=${request.callerUid == marker.getInt("uid")}")
            if (request.callerUid != marker.getInt("uid")) {
                callback.error()
                return
            }
            val token = marker.getString("token")
            require(token.matches(Regex("[a-zA-Z0-9-]+")))
            val output = File(filesDir, "amoo-speech-$token.jsonl")
            if (output.length() > 262144) {
                callback.error()
                return
            }
            val event = JSONObject().put("uid", request.callerUid)
                .put("text", request.charSequenceText.toString().take(8192))
                .put("elapsed_ms", android.os.SystemClock.elapsedRealtime())
            output.appendText(event.toString() + "\n")
            callback.start(16000, AudioFormat.ENCODING_PCM_16BIT, 1)
            callback.audioAvailable(byteArrayOf(0, 0), 0, 2)
            callback.done()
        } catch (error: Exception) {
            android.util.Log.e("AmooSpeechCapture", "Synthesis capture failed: ${error.javaClass.simpleName}")
            callback.error()
        }
    }
}
