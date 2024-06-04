//
//  OYAudioAACEncode.swift
//  OYAVDemo
//
//  Created by 欧阳芳斌 on 2024/5/31.
//

import Foundation
import CoreMedia
import AudioToolbox

public final class OYAudioAACEncode {
    let audioBitrate: Int
    
    var errorCallBack: ((NSError) -> Void)?
    var encodeSampleBufferOutputCallBack: ((CMSampleBuffer?) -> Void)?
    
    fileprivate var audioEncoderInstance: AudioConverterRef?
    fileprivate var aacFormat: CMAudioFormatDescription?
    private let encodeQueue: DispatchQueue = DispatchQueue(label: "com.OYKit.audioAACEncode")
    private var isError = false
    
    private var leftBuffer: UnsafeMutableRawPointer?
    private var leftLength: Int = 0
    private var aacBuffer: UnsafeMutableRawPointer?
    private var bufferLength: Int = 0
    
    init(audioBitrate: Int) {
        self.audioBitrate = audioBitrate
    }
    
    deinit {
        guard let audioEncoderInstance = audioEncoderInstance else { return }
        AudioConverterDispose(audioEncoderInstance)
        guard let leftBuffer = leftBuffer else { return }
        free(leftBuffer)
        guard let aacBuffer = aacBuffer else { return }
        free(aacBuffer)
    }
}

public
extension OYAudioAACEncode {
    func encodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferGetDataBuffer(sampleBuffer) != nil && !isError else { return }
        encodeQueue.async { [weak self] in
            self?.encodeSampleBufferInternal(sampleBuffer)
        }
    }
    
    static func create_adts_header(channels: Int, sampleRate: Int, rawDataLength: Int) -> Data {
        /**
         // ADTS 格式参考：http://wiki.multimedia.cx/index.php?title=ADTS
         // 验证：https://p23.nl/projects/aac-header
         ADTS 头信息
         AAAAAAAA AAAABCCD EEFFFFGH HHIJKLMM MMMMMMMM MMMOOOOO OOOOOOPP (QQQQQQQQ QQQQQQQQ)

         Header consists of 7 or 9 bytes (without or with CRC).

         Letter    Length (bits)    Description
         A    12    Syncword, all bits must be set to 1.
         B    1    MPEG Version, set to 0 for MPEG-4 and 1 for MPEG-2.
         C    2    Layer, always set to 0.
         D    1    Protection absence, set to 1 if there is no CRC and 0 if there is CRC.
         E    2    Profile, the MPEG-4 Audio Object Type minus 1.
         F    4    MPEG-4 Sampling Frequency Index (15 is forbidden).
         G    1    Private bit, guaranteed never to be used by MPEG, set to 0 when encoding, ignore when decoding.
         H    3    MPEG-4 Channel Configuration (in the case of 0, the channel configuration is sent via an inband PCE (Program Config Element)).
         I    1    Originality, set to 1 to signal originality of the audio and 0 otherwise.
         J    1    Home, set to 1 to signal home usage of the audio and 0 otherwise.
         K    1    Copyright ID bit, the next bit of a centrally registered copyright identifier. This is transmitted by sliding over the bit-string in LSB-first order and putting the current bit value in this field and wrapping to start if reached end (circular buffer).
         L    1    Copyright ID start, signals that this frame's Copyright ID bit is the first one by setting 1 and 0 otherwise.
         M    13    Frame length, length of the ADTS frame including headers and CRC check.
         O    11    Buffer fullness, states the bit-reservoir per frame.
         max_bit_reservoir = minimum_decoder_input_size - mean_bits_per_RDB; // for CBR

         // bit reservoir state/available bits (≥0 and <max_bit_reservoir); for the i-th frame.
         bit_reservoir_state[i] = (int)(bit_reservoir_state[i - 1] + mean_framelength - framelength[i]);

         // NCC is the number of channels.
         adts_buffer_fullness = bit_reservoir_state[i] / (NCC * 32);
         However, a special value of 0x7FF denotes a variable bitrate, for which buffer fullness isn't applicable.

         P    2    Number of AAC frames (RDBs (Raw Data Blocks)) in ADTS frame minus 1. For maximum compatibility always use one AAC frame per ADTS frame.
         Q    16    CRC check (as of ISO/IEC 11172-3, subclause 2.4.3.1), if Protection absent is 0.
         */
        
        let adtsLength: Int = 7; // ADTS头没有CRC加密，7字节
        guard let packet = malloc(adtsLength) else { return Data() }

        
        // MARK - adts_fixed_header
        // 第一个字节：(AAAAAAAA)
        packet.storeBytes(of: 0b11111111, toByteOffset: 0, as: UInt8.self)
        
        // 第二个字节：(AAAA_B_CC_D) B(MPEG-2 -> 1) D(没有CRC校验 -> 1)
        packet.storeBytes(of: 0b1111_1_00_1, toByteOffset: 1, as: UInt8.self)
        
        // 第三个字节：(EE_FFFF_G_H)
        let E: UInt8 = AudioObjectTypes_AAC.AAC_LC.rawValue - 1 // Profile
        let F: UInt8 = sampleRateIndex(for: sampleRate) // SampleRateIndex
        let G: UInt8 = 0 // PrivateBit
        let H: UInt8 = channelIndex(for: channels) // ChannelConfiguration
        let byte3: UInt8 = (E << 6) + (F << 2) + (G << 1) + (H >> 2)
        packet.storeBytes(of: byte3, toByteOffset: 2, as: UInt8.self)
        
        // 第四个字节：(HHIJKLMM)
        let IJ: UInt8 = 0b00 // 编码设置为0，解码忽略
        // MARK - adts_fixed_header
        let KL: UInt8 = 0b00 // 编码设置为0，解码忽略
        let M: UInt16 = UInt16(adtsLength + rawDataLength) // 13位
        let byte4: UInt8 = ((H & 0b11) << 6) + (IJ << 4) + (KL << 2) + UInt8((M >> 11))
        packet.storeBytes(of: byte4, toByteOffset: 3, as: UInt8.self)
        
        // 第五个字节：(MMMMMMMM)
        let byte5: UInt8 = UInt8((M & 0b11111111111) >> 3)
        packet.storeBytes(of: byte5, toByteOffset: 4, as: UInt8.self)
        
        // 第六个字节：(MMMOOOOO)
        let O: UInt16 = 0b11111111111 // 11位都设为1。表示是码率可变的码流
        let byte6: UInt8 = UInt8(((M & 0b111) << 5)) + UInt8((O >> 6))
        packet.storeBytes(of: byte6, toByteOffset: 5, as: UInt8.self)
        
        // 第七个字节：(OOOOOOPP)
        let P: UInt8 = 0 // ADTS帧中的AAC帧数-1，0相当于ADTS帧使用一个AAC帧
        let byte7: UInt8 = UInt8((O & 0b111111) << 2) + P
        packet.storeBytes(of: byte7, toByteOffset: 6, as: UInt8.self)
        
        let adtsHeaderData = Data(bytesNoCopy: packet, count: adtsLength, deallocator: Data.Deallocator.free)
        printDataAsBinary(adtsHeaderData)
        return adtsHeaderData
    }
}

private
extension OYAudioAACEncode {
    func callBackError(error: NSError) {
        isError = true
        DispatchQueue.main.async {
            self.errorCallBack?(error)
        }
    }
    
    func encodeSampleBufferInternal(_ sampleBuffer: CMSampleBuffer) {
        // 1.从输入数据获取音频格式信息
        guard 
            let format = CMSampleBufferGetFormatDescription(sampleBuffer),
            // 获取音频参数信息，AudioStreamBasicDescription 包含了音频的数据格式、声道数、采样位深、采样率等参数。
            var audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }
        
        // 2.根据音频参数创建编码器实例
        if (audioEncoderInstance == nil) {
            do {
                try setupAudioEncoderInstance(inputAudioFormat: &audioFormat)
            } catch {
                callBackError(error: error as NSError)
            }
        }
        
        // 3.获取输入数据中的PCM数据
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var audioLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &audioLength, dataPointerOut: &dataPointer)
        guard
            let dataPointer = dataPointer
        else { return  }
        
        // 4.处理音频时间戳信息
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)), timescale: CMTimeScale(audioFormat.mSampleRate)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: CMTime.invalid
        )
        
        // 5.基于编码缓冲区对PCM数据进行编码
        if (leftLength + audioLength >= bufferLength) {
            // 当待编码缓冲区遗留数据加上新来的数据长度大于每次给编码器的数据长度时，则进行循环编码，每次送给编码器长度为 bufferLength 的数据量
            
            // 拷贝待编码的数据到缓冲区 totalBuffer
            let totalSize = leftLength + audioLength
            let encodeCount = totalSize / bufferLength
            guard let totalBuffer = malloc(totalSize) else { return }
            var p = totalBuffer
            memset(totalBuffer, 0, totalSize)
            memcpy(totalBuffer, leftBuffer, leftLength) // 拷贝上次遗留的数据。
            memcpy(totalBuffer + leftLength, dataPointer, audioLength) // 拷贝这次新来的数据。
            
            // 分 encodeCount 次给编码器送数据。
            for _ in 0..<encodeCount {
                do {
                    try encodeBuffer(p, timing: &timingInfo) // 调用编码方法
                } catch {
                    callBackError(error: error as NSError)
                }
                p += bufferLength
            }
            
            // 处理不够 bufferLength 长度的剩余数据，先存在 leftBuffer 中，等下次凑足一次编码需要的数据再编码。
            leftLength = totalSize % bufferLength
            memset(leftBuffer, 0, bufferLength)
            memcpy(leftBuffer, totalBuffer + (totalSize - leftLength), leftLength)
            
            // 清理
            free(totalBuffer)
        } else {
            // 否则，就先存到待编码缓冲区，等下一次数据够了再送给编码器。
            guard let leftBuffer = leftBuffer else { return }
            memcpy(leftBuffer + leftLength, dataPointer, audioLength)
            leftLength = leftLength + audioLength
        }
    }
    
    func setupAudioEncoderInstance(inputAudioFormat: inout AudioStreamBasicDescription) throws {
        // 1.设置音频编码器输出参数，其中一些参数与输入的音频参数数据一致
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: inputAudioFormat.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.aac_Main.rawValue),
            mBytesPerPacket: 0, // 每个包的大小。动态大小设置为 0。
            mFramesPerPacket: 1024, // 每个包的帧数。AAC固定是1024，这个是由AAC编码规范规定的。对于未压缩数据设置为1。
            mBytesPerFrame: 0, // 每帧的大小。压缩格式设置为0。
            mChannelsPerFrame: inputAudioFormat.mChannelsPerFrame, // 输出声道数与输入一致。
            mBitsPerChannel: 0, // 压缩格式设置为 0。
            mReserved: 0
        )
        // 2.基于音频输入和输出参数创建音频编码器
        var status = AudioConverterNew(&inputAudioFormat, &outputFormat, &audioEncoderInstance)
        guard status == noErr, let audioEncoderInstance = audioEncoderInstance else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        // 3.设置编码器参数：音频编码码率
        var outputBitrate = UInt32(self.audioBitrate)
        status = AudioConverterSetProperty(audioEncoderInstance, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &outputBitrate)
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        // 4.创建编码格式信息 aacFormat
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &outputFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &aacFormat)
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 4.设置每次发送给编码器的数据长度
        // 这里设置每次送给编码器的数据长度为：1024 * 2(16 bit 采样深度) * 声道数量，这个长度为什么要这么计算呢？
        // 因为我们每次调用 AudioConverterFillComplexBuffer 编码时，是送进去一个包（packet），而对于 AAC 来讲，mFramesPerPacket 需要是 1024，即 1 个 packet 有 1024 帧，而每个音频帧的大小是：2(16 bit 采样深度) * 声道数量。
        bufferLength = Int(1024 * 2 * inputAudioFormat.mChannelsPerFrame)
        // 5.初始化待编码缓冲区和编码缓冲区
        if (leftBuffer == nil) {
            // 待编码缓冲区长度达到 _bufferLength，就会送一波给编码器，所以大小 _bufferLength 够用了。
            leftBuffer = malloc(bufferLength)
        }
        if (aacBuffer == nil) {
            // AAC 编码缓冲区只要装得下 _bufferLength 长度的 PCM 数据编码后的数据就好了，编码是压缩，所以大小 _bufferLength 也够用了。
            aacBuffer = malloc(bufferLength)
        }
    }
    
    func encodeBuffer(_ buffer: UnsafeMutableRawPointer, timing: inout CMSampleTimingInfo) throws {
        // 1.创建编码器接口对应的待编码缓冲区 AudioBufferList，填充待编码数据。
        var inBuffer = AudioBuffer()
        guard
            let aacFormat = aacFormat,
            let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(aacFormat)?.pointee
        else { return }
        inBuffer.mNumberChannels = audioFormat.mChannelsPerFrame
        inBuffer.mData = buffer
        inBuffer.mDataByteSize = UInt32(bufferLength) // 设置待编码数据长度。
        var inBufferList = AudioBufferList()
        inBufferList.mNumberBuffers = 1
        inBufferList.mBuffers = inBuffer
        
        // 2.创建编码输出缓冲区 AudioBufferList 接收编码后的数据
        var outBufferList = AudioBufferList()
        outBufferList.mNumberBuffers = 1
        outBufferList.mBuffers.mNumberChannels = inBuffer.mNumberChannels
        outBufferList.mBuffers.mDataByteSize = inBuffer.mDataByteSize // 设置编码缓冲区大小。
        outBufferList.mBuffers.mData = aacBuffer // 绑定缓冲区空间
        
        // 3.编码
        var outputDataPacketSize: UInt32 = 1 // 每次编码1个包，1个包有1024帧，这个对应创建编码器实例时设置的 mFramesPerPacket。
        // 需要在回调方法 inputDataProcess 中将待编码的数据拷贝到编码器的缓冲区的对应位置。这里把我们自己创建的待编码缓冲区 AudioBufferList 作为 inInputDataProcUserData 传入，在回调方法中直接拷贝它。
        guard let audioEncoderInstance = audioEncoderInstance else { return }
        var status = AudioConverterFillComplexBuffer(audioEncoderInstance, inputDataProcess, &inBufferList, &outputDataPacketSize, &outBufferList, nil)
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 4.获取编码后的 AAC 数据进行封装
        let aacEncoderSize = Int(outBufferList.mBuffers.mDataByteSize)
        let blockBufferDataPoint = malloc(aacEncoderSize)
        memcpy(blockBufferDataPoint, aacBuffer, aacEncoderSize)
        // 编码数据封装到 CMBlockBuffer 中。
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: blockBufferDataPoint,
            blockLength: aacEncoderSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: aacEncoderSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        // 编码数据 CMBlockBuffer 再封装到 CMSampleBuffer 中。
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray: [Int] = [aacEncoderSize]
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: aacFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 5.回调编码数据
        encodeSampleBufferOutputCallBack?(sampleBuffer)
    }
}

private func inputDataProcess(
    inConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    // 将待编码的数据拷贝到编码器的缓冲区的对应位置进行编码。
    guard let bufferList = inUserData?.assumingMemoryBound(to: AudioBufferList.self).pointee else { return -1 }
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mData = bufferList.mBuffers.mData
    ioData.pointee.mBuffers.mDataByteSize = bufferList.mBuffers.mDataByteSize
    return noErr
}

// MARK: - ADTS
private
extension OYAudioAACEncode {
    enum AudioObjectTypes_AAC: UInt8 {
        case Null = 0
        case AAC_Main = 1
        case AAC_LC = 2
        case AAC_SSR = 3
        case AAC_LTP = 4
    }
    
    static func sampleRateIndex(for sampleRate: Int) -> UInt8 {
        switch sampleRate {
        case 96000: return 0
        case 88200: return 1
        case 64000: return 2
        case 48000: return 3
        case 44100: return 4
        case 32000: return 5
        case 24000: return 6
        case 22050: return 7
        case 16000: return 8
        case 12000: return 9
        case 11025: return 10
        case 8000: return 11
        case 7350: return 12
        default: return 15
        }
    }
    
    static func channelIndex(for channel: Int) -> UInt8 {
        switch channel {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 6
        case 8: return 7
        default: return 0
        }
    }
}

fileprivate func printDataAsBinary(_ data: Data) {
    data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
        if let pointer = pointer.baseAddress {
            for i in 0..<data.count {
                var number = pointer.load(fromByteOffset: i, as: UInt8.self)
                var byteString = ""
                for _ in 0..<8 {
                    byteString += "\(number % 2)"
                    number /= 2
                }
                print(String(byteString.reversed()), terminator: " ")
            }
            print("\n hex => ")
            print(data.map { String(format: "%02X", $0) }.joined())
        }
    }
}
