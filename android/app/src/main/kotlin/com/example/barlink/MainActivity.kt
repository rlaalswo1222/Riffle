package com.example.barlink

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * 원곡 음원: yt-dlp로 내려받고, 안드로이드 디코더로 22050Hz 모노 PCM으로 푼다.
 * 둘 다 몇 초~수십 초 걸리므로 별도 스레드에서 돌리고 결과만 Flutter로 돌려준다.
 */
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var ytdlReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "barlink/original")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "download" -> thread {
                    try {
                        val path = download(
                            call.argument<String>("url")!!,
                            call.argument<String>("dir")!!,
                        ) { pct -> main.post { channel.invokeMethod("progress", pct) } }
                        main.post { result.success(path) }
                    } catch (e: Throwable) {
                        main.post { result.error("download", e.message ?: e.toString(), null) }
                    }
                }
                "decode" -> thread {
                    try {
                        val n = decode(
                            call.argument<String>("path")!!,
                            call.argument<String>("out")!!,
                            call.argument<Int>("rate")!!,
                        )
                        main.post { result.success(n) }
                    } catch (e: Throwable) {
                        main.post { result.error("decode", e.message ?: e.toString(), null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------ yt-dlp
    private fun download(url: String, dir: String, progress: (Double) -> Unit): String {
        val ytdl = YoutubeDL.getInstance()
        if (!ytdlReady) {
            ytdl.init(applicationContext)
            ytdlReady = true
        }
        File(dir).mkdirs()
        fun run(): String {
            val request = YoutubeDLRequest(url)
                .addOption("-f", "bestaudio[ext=m4a]/bestaudio")
                .addOption("-o", "$dir/%(id)s.%(ext)s")
                .addOption("--no-playlist")
                .addOption("--no-mtime")
                .addOption("--print", "after_move:filepath")
            val response = ytdl.execute(request, null) { pct, _, _ -> progress(pct.toDouble()) }
            val printed = response.out.lines().map { it.trim() }.lastOrNull { it.isNotEmpty() && File(it).exists() }
            return printed ?: File(dir).listFiles()?.maxByOrNull { it.lastModified() }?.absolutePath
                ?: throw IllegalStateException("내려받은 파일을 찾지 못했습니다")
        }
        return try {
            run()
        } catch (first: Throwable) {
            // 유튜브가 바뀌어서 막혔을 수 있다. yt-dlp를 최신판으로 바꾸고 한 번 더.
            ytdl.updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
            run()
        }
    }

    // ------------------------------------------------------------ 해독
    /** 음원 파일을 [rate]Hz 모노 16비트 리틀엔디언 PCM으로 [out]에 쓴다. 샘플 수를 돌려준다. */
    private fun decode(path: String, out: String, rate: Int): Int {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        var track = -1
        for (i in 0 until extractor.trackCount) {
            if (extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                track = i
                break
            }
        }
        require(track >= 0) { "오디오 트랙이 없습니다" }
        extractor.selectTrack(track)
        val format = extractor.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()

        var srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var step = srcRate.toDouble() / rate // 출력 한 샘플마다 입력에서 나아갈 양
        // 낮은 샘플레이트로 줄이기 전에 짧은 이동평균으로 고음을 깎아 접힘(aliasing)을 줄인다
        var boxLen = maxOf(1, step.toInt())
        val box = DoubleArray(8)
        var boxSum = 0.0
        var boxAt = 0
        var phase = 0.0 // 다음 출력 샘플의 입력 위치(마지막으로 받은 입력 기준)
        var prev = 0.0
        var written = 0
        val sink = BufferedOutputStream(FileOutputStream(out), 1 shl 16)
        val two = ByteArray(2)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, 10_000)
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    srcRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    step = srcRate.toDouble() / rate
                    boxLen = maxOf(1, minOf(8, step.toInt()))
                } else if (outIndex >= 0) {
                    val pcm = codec.getOutputBuffer(outIndex)!!.order(ByteOrder.LITTLE_ENDIAN)
                    pcm.position(info.offset)
                    pcm.limit(info.offset + info.size)
                    val shorts = pcm.asShortBuffer()
                    val frames = shorts.remaining() / channels
                    for (k in 0 until frames) {
                        // 채널 평균 = 모노
                        var sum = 0.0
                        for (c in 0 until channels) sum += shorts.get(k * channels + c)
                        val mono = sum / channels
                        boxSum += mono - box[boxAt]
                        box[boxAt] = mono
                        boxAt = (boxAt + 1) % boxLen
                        val cur = boxSum / boxLen
                        // prev(위치 -1)와 cur(위치 0) 사이에 놓이는 출력 샘플을 선형 보간
                        while (phase <= 0.0) {
                            val v = prev + (cur - prev) * (phase + 1.0)
                            val s = v.toInt().coerceIn(-32768, 32767)
                            two[0] = (s and 0xff).toByte()
                            two[1] = ((s shr 8) and 0xff).toByte()
                            sink.write(two)
                            written++
                            phase += step
                        }
                        phase -= 1.0
                        prev = cur
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
        } finally {
            sink.close()
            codec.stop()
            codec.release()
            extractor.release()
        }
        return written
    }
}
