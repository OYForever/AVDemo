//
//  OYAudioCapture.swift
//  OYAVDemo
//
//  Created by 欧阳芳斌 on 2024/5/20.
//

import AVFoundation
import Foundation

public final class OYAudioCapture {
    public struct Config {
        let sampleRate: UInt32
        let bitDepth: UInt32
        let channels: UInt32

        init(sampleRate: UInt32 = 44100, bitDepth: UInt32 = 16, channels: UInt32 = 2) {
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.channels = channels
        }
    }

    fileprivate var audioCaptureInstance: AudioComponentInstance?
    fileprivate var audioFormat: AudioStreamBasicDescription?
    let config: Config
    private let captureQueue: DispatchQueue = DispatchQueue(label: "com.OYKit.audioCapture")
    private var isError = false
    var errorCallBack: ((NSError) -> Void)?
    var sampleBufferOutputCallBack: ((CMSampleBuffer?) -> Void)?

    init(config: Config) {
        self.config = config
    }

    deinit {
        guard let audioCaptureInstance = audioCaptureInstance else { return }
        AudioOutputUnitStop(audioCaptureInstance)
        AudioComponentInstanceDispose(audioCaptureInstance)
        self.audioCaptureInstance = nil
    }
}

public
extension OYAudioCapture {
    func startRunning() {
        guard !isError else { return }
        captureQueue.async { [weak self] in
            if self?.audioCaptureInstance == nil {
                do {
                    self?.audioCaptureInstance = try self?.setupAudioCaptureInstance()
                } catch {
                    self?.callBackError(error: error as NSError)
                    return
                }
            }
            guard let audioCaptureInstance = self?.audioCaptureInstance else { return }
            
            // 开始采集
            let startStatus = AudioOutputUnitStart(audioCaptureInstance)
            if startStatus != noErr {
                self?.callBackError(error: NSError(domain: NSStringFromClass(Self.self), code: Int(startStatus)))
            }
        }
    }
    
    func stopRunning() {
        guard !isError else { return }
        captureQueue.async { [weak self] in
            guard let audioCaptureInstance = self?.audioCaptureInstance else { return }
            // 停止采集
            let startStatus = AudioOutputUnitStop(audioCaptureInstance)
            if startStatus != noErr {
                self?.callBackError(error: NSError(domain: NSStringFromClass(Self.self), code: Int(startStatus)))
            }
        }
    }
}

private
extension OYAudioCapture {
    func setupAudioCaptureInstance() throws -> AudioComponentInstance {
        // 1、设置音频组件描述。
        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        // 2、查找符合指定描述的音频组件。
        guard let component = AudioComponentFindNext(nil, &acd) else {
            throw NSError(domain: NSStringFromClass(Self.self), code: -1)
        }
        
        // 3、创建音频组件实例。
        var audioCaptureInstance: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &audioCaptureInstance)
        guard status == noErr, let audioCaptureInstance = audioCaptureInstance else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 4、设置实例的属性：硬件IO可读写。0 不可读写，1 可读写。
        var flagOne: Int32 = 1
        AudioUnitSetProperty(audioCaptureInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flagOne, UInt32(MemoryLayout.size(ofValue: flagOne)))
        
        // 5、设置实例的属性：音频参数，如：数据格式、声道数、采样位深、采样率等。AudioUnit只能采集原始PCM数据
        /*
         可以通过AVAudioFormat获取pcm的asbd
         guard let avAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(config.sampleRate), channels: config.channels, interleaved: true) else {
             throw NSError(domain: NSStringFromClass(Self.self), code: -1)
         }
         
         var asbd = avAudioFormat.streamDescription.pointee
         */
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = config.channels
        asbd.mFramesPerPacket = 1
        asbd.mBitsPerChannel = config.bitDepth
        asbd.mBytesPerFrame = (asbd.mBitsPerChannel / 8) * asbd.mChannelsPerFrame
        asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket
        asbd.mSampleRate = Float64(config.sampleRate)
        audioFormat = asbd
        status = AudioUnitSetProperty(audioCaptureInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout.size(ofValue: asbd)))
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 6、设置实例的属性：数据回调函数。
        var callBack = AURenderCallbackStruct(inputProc: recordingCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(audioCaptureInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &callBack, UInt32(MemoryLayout.size(ofValue: callBack)))
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        // 7、初始化实例。
        status = AudioUnitInitialize(audioCaptureInstance)
        guard status == noErr else {
            throw NSError(domain: NSStringFromClass(Self.self), code: Int(status))
        }
        
        return audioCaptureInstance
    }
    
    func callBackError(error: NSError) {
        isError = true
        DispatchQueue.main.async {
            self.errorCallBack?(error)
        }
    }
    
    static func sampleBufferFromAudioBufferList(
        _ buffers: UnsafeMutablePointer<AudioBufferList>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32,
        description: UnsafeMutablePointer<AudioStreamBasicDescription>
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        
        // 1、创建音频流的格式描述信息。
        var format: CMFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        
        // 2、处理音频帧的时间戳信息。
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        var inTime = inTimeStamp.pointee.mHostTime
        // 转换为纳秒
        inTime *= UInt64(info.numer)
        inTime /= UInt64(info.denom)
        let presentationTimeStamp = CMTimeMake(value: Int64(inTime), timescale: 1000000000)
        // 对于音频，PTS 和 DTS 是一样的。
        var timing = CMSampleTimingInfo(duration: CMTimeMake(value: 1, timescale: Int32(description.pointee.mSampleRate)), presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: presentationTimeStamp)
        
        // 3、创建 CMSampleBuffer 实例。
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(inNumberFrames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer = sampleBuffer else { return nil }
        
        // 4、创建 CMBlockBuffer 实例。其中数据拷贝自 AudioBufferList，并将 CMBlockBuffer 实例关联到 CMSampleBuffer 实例。
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffers)
        guard status == noErr else { return nil }
        
        return sampleBuffer
    }
}

private func recordingCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    autoreleasepool {
        guard 
            let capture = Unmanaged<AnyObject>.fromOpaque(inRefCon).takeUnretainedValue() as? OYAudioCapture,
            let audioCaptureInstance = capture.audioCaptureInstance,
            var audioFormat = capture.audioFormat
        else { return -1 }
        // 1、创建 AudioBufferList 空间，用来接收采集回来的数据。
        // 采集的时候设置了数据格式是 kAudioFormatLinearPCM，即声道交错格式，所以即使是双声道这里也设置 mNumberBuffers 为 1。
        var buffers = AudioBufferList()
        buffers.mNumberBuffers = 1
        
        // 2、获取音频 PCM 数据，存储到 AudioBufferList 中。
        // 这里有几个问题要说明清楚：
        // 1）每次回调会过来多少数据？
        // 按照上面采集音频参数的设置：PCM 为声道交错格式、每帧的声道数为 2、采样位深为 16 bit。这样每帧的字节数是 4 字节（左右声道各 2 字节）。
        // 返回数据的帧数是 inNumberFrames。这样一次回调回来的数据字节数是多少就是：mBytesPerFrame(4) * inNumberFrames。
        // 2）这个数据回调的频率跟音频采样率有关系吗？
        // 这个数据回调的频率与音频采样率（上面设置的 mSampleRate 44100）是没关系的。声道数、采样位深、采样率共同决定了设备单位时间里采样数据的大小，这些数据是会缓冲起来，然后一块一块的通过这个数据回调给我们，这个回调的频率是底层一块一块给我们数据的速度，跟采样率无关。
        // 3）这个数据回调的频率是多少？
        // 这个数据回调的间隔是 [AVAudioSession sharedInstance].preferredIOBufferDuration，频率即该值的倒数。我们可以通过 [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:1 error:nil] 设置这个值来控制回调频率。
        let status = AudioUnitRender(
            audioCaptureInstance,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            &buffers
        )
        
        // 3、数据封装及回调。
        if status == noErr {
            let sampleBuffer = OYAudioCapture.sampleBufferFromAudioBufferList(&buffers, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, description: &audioFormat)
            capture.sampleBufferOutputCallBack?(sampleBuffer)
        }
        return status
    }
}
