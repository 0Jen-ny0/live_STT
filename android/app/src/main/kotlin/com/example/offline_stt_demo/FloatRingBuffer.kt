package com.example.offline_stt_demo

import java.util.Arrays

class FloatRingBuffer(private val capacity: Int) {
    private val data = FloatArray(capacity)
    private var writePos = 0
    private var size = 0

    @Synchronized
    fun append(chunk: FloatArray) {
        for (sample in chunk) {
            data[writePos] = sample
            writePos = (writePos + 1) % capacity
            if (size < capacity) {
                size++
            }
        }
    }

    @Synchronized
    fun lastSamples(n: Int): FloatArray {
        val outSize = minOf(n, size)
        val out = FloatArray(outSize)

        val start = (writePos - outSize + capacity) % capacity
        for (i in 0 until outSize) {
            out[i] = data[(start + i) % capacity]
        }

        return out
    }

    @Synchronized
    fun clear() {
        Arrays.fill(data, 0f)
        writePos = 0
        size = 0
    }
}