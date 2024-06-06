//
//  AudioEncoderViewController.swift
//  OYAVDemo
//
//  Created by 欧阳芳斌 on 2024/6/3.
//

import UIKit
import AVFoundation

class AudioEncoderViewController: UIViewController {
    private lazy var audioCapture: OYAudioCapture = {
        let audioCapture = OYAudioCapture(config: .init())
        audioCapture.errorCallBack = { error in
            print("OYAudioCapture error:\(error.code) \(error.localizedDescription)")
        }
        audioCapture.sampleBufferOutputCallBack = { [weak self] sampleBuffer in
            guard let sampleBuffer = sampleBuffer else { return }
            self?.audioEncoder.encodeSampleBuffer(sampleBuffer)
        }
        return audioCapture
    }()
    
    private lazy var audioEncoder: OYAudioAACEncode = {
        let audioEncoder = OYAudioAACEncode(audioBitrate: 112000)
        audioEncoder.errorCallBack = { error in
            print("OYAudioAACEncode error:\(error.code) \(error.localizedDescription)")
        }
        audioEncoder.encodeSampleBufferOutputCallBack =  { [weak self] sampleBuffer in
            guard let sampleBuffer = sampleBuffer else { return }
            // 获取音频参数
            guard
                let accFormat = CMSampleBufferGetFormatDescription(sampleBuffer),
                let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(accFormat)?.pointee,
                let dataBuffer = sampleBuffer.dataBuffer,
                let data = try? dataBuffer.dataBytes()
            else { return }
            
            // 在每个 AAC packet 前先写入 ADTS 头数据。
            self?.fileHandle?.write(audioEncoder.createAdtsHeader(channels: Int(audioFormat.mChannelsPerFrame), sampleRate: Int(audioFormat.mSampleRate), rawDataLength: dataBuffer.dataLength))
            // 写入AAC packet 数据
            self?.fileHandle?.write(data)
        }
        return audioEncoder
    }()
    
    private lazy var fileHandle = {
        let filePath = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last ?? "") + "/test.aac"
        print(filePath)
        // 使用ffmpeg7.0播放
        // ffplay test.aac
        try? FileManager.default.removeItem(atPath: filePath)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        return FileHandle(forWritingAtPath: filePath)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setPreferredIOBufferDuration(1)
        try? session.setMode(.videoRecording)
        try? session.setActive(true)
    }


    @IBAction func startAction(_ sender: Any) {
        audioCapture.startRunning()
    }
    
    @IBAction func stopAction(_ sender: Any) {
        audioCapture.stopRunning()
    }
}
