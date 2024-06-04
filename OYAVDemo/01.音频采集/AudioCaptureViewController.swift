//
//  AudioCaptureViewController.swift
//  OYAVDemo
//
//  Created by 欧阳芳斌 on 2024/5/20.
//

import UIKit
import AVFAudio

class AudioCaptureViewController: UIViewController {
    
    private let audioCapture: OYAudioCapture = .init(config: .init())
    private lazy var fileHandle = {
        let filePath = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last ?? "") + "/test.pcm"
        print(filePath)
        // 使用ffmpeg7.0播放
        // ffplay -ar 44100 -ch_layout stereo -f s16le test.pcm
        try? FileManager.default.removeItem(atPath: filePath)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        return FileHandle(forWritingAtPath: filePath)
    }()

    @IBOutlet weak var startButton: UIButton!
    @IBOutlet weak var stopButton: UIButton!
    
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
        audioCapture.sampleBufferOutputCallBack = { [weak self] sampleBuffer in
            guard let sampleBuffer = sampleBuffer else { return }
            // iOS13.0新增方法，直接获取data
//            if let data = try? sampleBuffer.dataBuffer?.dataBytes() {
//                self?.fileHandle?.write(data)
//            }
            
            // 原始方法
            var lengthAtOffsetOut: Int = 0
            var totalLengthOut: Int = 0
            var dataPointerOut: UnsafeMutablePointer<CChar>?
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffsetOut, totalLengthOut: &totalLengthOut, dataPointerOut: &dataPointerOut)
                guard
                    let dataPointerOut = dataPointerOut
                else { return }
                self?.fileHandle?.write(Data(bytes: dataPointerOut, count: totalLengthOut))
            }
        }
    }
    
    @IBAction func stopAction(_ sender: Any) {
        audioCapture.stopRunning()
    }
}

